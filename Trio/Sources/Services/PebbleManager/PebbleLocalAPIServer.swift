import Dispatch
import Foundation
import UIKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lightweight HTTP server on 127.0.0.1 that exposes Trio data
/// to the PebbleKit JS bridge running in the Rebble companion app.
///
/// **Canonical snapshot:** `GET /api/all` and `GET /api/pebble/v1/snapshot` return the same
/// versioned JSON (`pebbleProtocolVersion`, `stateRevision`, CGM/loop/pump, transport flags).
///
/// **Not the same as Garmin:** `GarminManager` uses Garmin Connect IQ to send messages to the
/// watch while Trio is active. This server answers HTTP **pull** requests on loopback. iOS will
/// **suspend** Trio when another app is frontmost; we (1) extend background time on each accept,
/// (2) hold a rolling keep-alive background task while the server is enabled, and (3) auto-restart
/// the accept loop if the socket dies. Full suspension can still drop loopback until Trio wakes.
final class PebbleLocalAPIServer {
    private static let headerSeparator = Data("\r\n\r\n".utf8)
    /// Cap total request size (headers + body) to avoid unbounded reads.
    private static let maxRequestBytes = 512 * 1024

    private var serverSocket: Int32 = -1
    /// Desired run state (set by start/stop). Accept loop may exit while this stays true → restart.
    private var shouldRun = false
    /// True while accept loop is active and listening.
    private(set) var isListening = false
    private let port: UInt16
    private let dataBridge: PebbleDataBridge
    private let commandManager: PebbleCommandManager
    /// Optional carb → bolus recommendation (same engine as Apple Watch); used by `GET /api/pebble/v1/bolus_recommendation`.
    private let recommendBolusForCarbsGrams: ((Double) async -> Decimal)?
    private let lifecycleQueue = DispatchQueue(label: "trio.pebble.http.lifecycle")
    private var restartWorkItem: DispatchWorkItem?
    private var keepAliveTaskID: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: DispatchSourceTimer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        dataBridge: PebbleDataBridge,
        commandManager: PebbleCommandManager,
        port: UInt16 = 8080,
        recommendBolusForCarbsGrams: ((Double) async -> Decimal)? = nil
    ) {
        self.dataBridge = dataBridge
        self.commandManager = commandManager
        self.port = port
        self.recommendBolusForCarbsGrams = recommendBolusForCarbsGrams
    }

    deinit { stop() }

    /// Briefly extends process lifetime so Rebble can finish HTTP while Trio is in the background.
    private static func beginShortBackgroundTask() {
        DispatchQueue.main.async {
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "PebbleLocalHTTP") {}
            guard taskID != .invalid else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25) {
                DispatchQueue.main.async {
                    UIApplication.shared.endBackgroundTask(taskID)
                }
            }
        }
    }

    func start() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            self.installLifecycleObserversIfNeeded()
            self.startKeepAliveIfNeeded()
            guard !self.isListening else { return }
            self.launchAcceptLoop()
        }
    }

    func stop() {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.teardownKeepAlive()
            self.removeLifecycleObservers()
            self.isListening = false
            if self.serverSocket >= 0 {
                close(self.serverSocket)
                self.serverSocket = -1
            }
        }
    }

    /// Call when Trio returns to foreground or after pump/CGM wake — restarts socket if it died.
    func ensureListening() {
        lifecycleQueue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            self.startKeepAliveIfNeeded()
            if !self.isListening {
                debug(.service, "Pebble: ensureListening — accept loop down, restarting on :\(self.port)")
                self.launchAcceptLoop()
            }
        }
    }

    private func launchAcceptLoop() {
        // Always off lifecycleQueue to avoid blocking start/stop.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runServer()
        }
    }

    private func scheduleRestart(after seconds: Double) {
        lifecycleQueue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            self.restartWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lifecycleQueue.async {
                    guard self.shouldRun, !self.isListening else { return }
                    debug(.service, "Pebble: retrying HTTP server bind on :\(self.port)")
                    self.launchAcceptLoop()
                }
            }
            self.restartWorkItem = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func installLifecycleObserversIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        let center = Foundation.NotificationCenter.default
        let names: [NSNotification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                if note.name == UIApplication.didEnterBackgroundNotification {
                    self.startKeepAliveIfNeeded()
                }
                self.ensureListening()
            }
            lifecycleObservers.append(token)
        }
    }

    private func removeLifecycleObservers() {
        let center = Foundation.NotificationCenter.default
        for token in lifecycleObservers {
            center.removeObserver(token)
        }
        lifecycleObservers.removeAll()
    }

    /// Best-effort rolling background task so the accept thread can stay scheduled longer while
    /// Trio is backgrounded (alongside existing bluetooth-central / loop work).
    private func startKeepAliveIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.shouldRun else {
                self.teardownKeepAliveOnMain()
                return
            }
            if self.keepAliveTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
                timer.schedule(deadline: .now(), repeating: 20.0, leeway: .seconds(2))
                timer.setEventHandler { [weak self] in
                    self?.renewKeepAliveTask()
                }
                self.keepAliveTimer = timer
                timer.resume()
            }
            self.renewKeepAliveTask()
        }
    }

    private func renewKeepAliveTask() {
        assert(Thread.isMainThread)
        guard shouldRun else {
            teardownKeepAliveOnMain()
            return
        }
        if keepAliveTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(keepAliveTaskID)
            keepAliveTaskID = .invalid
        }
        keepAliveTaskID = UIApplication.shared.beginBackgroundTask(withName: "PebbleHTTPKeepAlive") { [weak self] in
            guard let self else { return }
            // Expiration: end cleanly; timer may renew if iOS still allows budget.
            if self.keepAliveTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.keepAliveTaskID)
                self.keepAliveTaskID = .invalid
            }
            PebbleIntegrationFileLogger.log("http_keepalive", "background task expired — server may suspend until wake")
        }
        if keepAliveTaskID == .invalid {
            debug(.service, "Pebble: background keep-alive task unavailable (budget exhausted or denied)")
        }
    }

    private func teardownKeepAlive() {
        DispatchQueue.main.async { [weak self] in
            self?.teardownKeepAliveOnMain()
        }
    }

    private func teardownKeepAliveOnMain() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        if keepAliveTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(keepAliveTaskID)
            keepAliveTaskID = .invalid
        }
    }

    private func runServer() {
        // Serialize bind attempts so ensureListening cannot open two listeners.
        let started: Bool = lifecycleQueue.sync {
            guard shouldRun, !isListening else { return false }
            return true
        }
        guard started else { return }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            debug(.service, "Pebble: failed to create socket")
            scheduleRestart(after: 2.0)
            return
        }

        var enable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))
        #if os(iOS) || os(macOS)
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            debug(.service, "Pebble: failed to bind to port \(port) errno=\(errno)")
            close(sock)
            scheduleRestart(after: 3.0)
            return
        }

        guard listen(sock, 8) == 0 else {
            debug(.service, "Pebble: failed to listen errno=\(errno)")
            close(sock)
            scheduleRestart(after: 3.0)
            return
        }

        lifecycleQueue.sync {
            serverSocket = sock
            isListening = true
        }
        debug(.service, "Pebble: API server started on http://127.0.0.1:\(port)")
        PebbleIntegrationFileLogger.log("http_server", "listening http://127.0.0.1:\(port)")

        var consecutiveAcceptFailures = 0
        while true {
            let stillWanted: Bool = lifecycleQueue.sync { shouldRun && serverSocket == sock }
            guard stillWanted else { break }

            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(sock, sa, &clientAddrLen)
                }
            }

            if clientSocket < 0 {
                let err = errno
                // EINTR / EAGAIN — transient
                if err == EINTR || err == EAGAIN {
                    continue
                }
                consecutiveAcceptFailures += 1
                let wanted = lifecycleQueue.sync { shouldRun }
                if wanted {
                    debug(.service, "Pebble: accept failed errno=\(err) streak=\(consecutiveAcceptFailures)")
                }
                // Socket likely closed or process freezing — exit loop and restart if still wanted.
                if !wanted || consecutiveAcceptFailures >= 5 || err == EBADF || err == EINVAL {
                    break
                }
                continue
            }

            consecutiveAcceptFailures = 0
            // Give Trio a short background window so Rebble can complete HTTP while Trio is not foreground.
            Self.beginShortBackgroundTask()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleRequest(clientSocket)
            }
        }

        lifecycleQueue.sync {
            if serverSocket == sock {
                close(sock)
                serverSocket = -1
            } else {
                close(sock)
            }
            isListening = false
        }
        debug(.service, "Pebble: API accept loop exited (port \(port))")
        PebbleIntegrationFileLogger.log("http_server", "accept loop exited port=\(port)")
        scheduleRestart(after: 1.5)
    }

    /// Avoid blocking forever if the client stalls mid-request (loopback only, but keeps the accept loop healthy).
    private static func setReceiveTimeout(seconds: Int, socketFD: Int32) {
        // `timeval.tv_sec` is `__darwin_time_t` (Int) on Apple platforms, not Int32.
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads until `\r\n\r\n` plus full `Content-Length` body (many clients split headers and body across packets).
    private func readCompleteHTTPRequest(_ clientSocket: Int32) -> Data? {
        Self.setReceiveTimeout(seconds: 30, socketFD: clientSocket)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)

        while data.count < Self.maxRequestBytes {
            let n = read(clientSocket, &buffer, buffer.count)
            if n < 0 { break }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))

            guard let headerRange = data.range(of: Self.headerSeparator) else { continue }

            let headerBytes = data.subdata(in: 0 ..< headerRange.lowerBound)
            guard let headerText = String(data: headerBytes, encoding: .utf8) else { return nil }
            let contentLength = Self.parseContentLength(from: headerText)
            let bodyStart = headerRange.upperBound
            let needed = bodyStart + contentLength
            guard needed <= Self.maxRequestBytes else {
                debug(.service, "Pebble HTTP: rejecting oversized Content-Length (\(contentLength))")
                return nil
            }
            if data.count >= needed {
                return Data(data.prefix(needed))
            }
        }

        return data.isEmpty ? nil : data
    }

    private static func parseContentLength(from headerBlock: String) -> Int {
        for line in headerBlock.split(separator: "\r\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "content-length" else { continue }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value) ?? 0
        }
        return 0
    }

    private func handleRequest(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        guard let requestData = readCompleteHTTPRequest(clientSocket) else { return }
        guard let parsed = Self.parseHTTPRequest(requestData) else {
            debug(.service, "Pebble HTTP: could not parse request (\(requestData.count) bytes)")
            let response = buildHTTPResponse(statusCode: 400, contentType: "application/json", body: "{\"error\":\"bad request\"}")
            _ = write(clientSocket, [UInt8](response.utf8), response.utf8.count)
            return
        }

        let (statusCode, contentType, responseBody) = routeRequest(
            method: parsed.method,
            path: parsed.path,
            query: parsed.query,
            body: parsed.body
        )
        let response = buildHTTPResponse(statusCode: statusCode, contentType: contentType, body: responseBody)
        let responseData = [UInt8](response.utf8)
        _ = write(clientSocket, responseData, responseData.count)
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let query: String?
        let body: String?
    }

    /// Split headers and body using byte-accurate `Content-Length` (body is not guaranteed UTF-8–safe to split in a combined `String`).
    private static func parseHTTPRequest(_ data: Data) -> ParsedHTTPRequest? {
        guard let sep = data.range(of: Self.headerSeparator) else { return nil }
        let headerData = data.subdata(in: 0 ..< sep.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else { return nil }
        let contentLength = parseContentLength(from: headers)
        let bodyStart = sep.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }

        let bodySlice = data.subdata(in: bodyStart ..< (bodyStart + contentLength))
        let bodyString: String?
        if contentLength == 0 {
            bodyString = nil
        } else {
            bodyString = String(data: bodySlice, encoding: .utf8)
            if bodyString == nil { return nil }
        }

        let firstLine = headers.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let rawPath = parts[1]
        let pathParts = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathSegs = Array(pathParts)
        let path = pathSegs.isEmpty ? rawPath : String(pathSegs[0])
        let query: String? = pathSegs.count > 1 ? String(pathSegs[1]) : nil
        return ParsedHTTPRequest(method: method, path: path, query: query, body: bodyString)
    }

    private static func queryParam(_ query: String?, name: String) -> String? {
        guard let query else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard kv.count == 2, kv[0] == name else { continue }
            return kv[1].removingPercentEncoding ?? kv[1]
        }
        return nil
    }

    private func routeRequest(method: String, path: String, query: String?, body: String?) -> (Int, String, String) {
        if method == "GET" {
            switch path {
            case "/":
                return (200, "text/html; charset=utf-8", Self.browserLandingHTML())
            case "/api/cgm": return (200, "application/json", dataBridge.cgmJSON())
            case "/api/loop": return (200, "application/json", dataBridge.loopJSON())
            case "/api/pump": return (200, "application/json", dataBridge.pumpJSON())
            case "/api/all", "/api/pebble/v1/snapshot":
                return (200, "application/json", dataBridge.allDataJSON())
            case "/api/commands/pending": return (200, "application/json", commandManager.pendingCommandsJSON())
            case "/api/pebble/v1/bolus_recommendation":
                return handleBolusRecommendationGet(query: query)
            case "/health": return (200, "application/json", "{\"status\":\"ok\"}")
            case "/api/pebble/v1/ping":
                return (200, "application/json", dataBridge.pingJSON())
            default: return (404, "application/json", "{\"error\":\"not found\"}")
            }
        }

        if method == "POST" {
            switch path {
            case "/api/bolus": return handleBolusRequest(body)
            case "/api/carbs": return handleCarbRequest(body)
            case "/api/command/confirm": return handleConfirmCommand(body)
            case "/api/command/reject": return handleRejectCommand(body)
            default: return (404, "application/json", "{\"error\":\"not found\"}")
            }
        }

        return (405, "application/json", "{\"error\":\"method not allowed\"}")
    }

    /// Minimal HTML so Safari on the same iPhone can confirm the server and follow links to JSON endpoints.
    private static func browserLandingHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Trio Pebble API</title></head>
        <body style="font-family: system-ui; padding: 1rem; max-width: 36rem;">
        <h1>Trio Pebble API</h1>
        <p>Local server is running on this iPhone.</p>
        <ul>
        <li><a href="/health"><code>/health</code></a> — JSON status</li>
        <li><a href="/api/pebble/v1/ping"><code>/api/pebble/v1/ping</code></a> — minimal revision ping</li>
        <li><a href="/api/cgm"><code>/api/cgm</code></a> — CGM JSON</li>
        <li><a href="/api/loop"><code>/api/loop</code></a> — loop JSON</li>
        <li><a href="/api/pump"><code>/api/pump</code></a> — pump JSON</li>
        <li><a href="/api/all"><code>/api/all</code></a> — combined JSON (same as <code>/api/pebble/v1/snapshot</code>)</li>
        <li><a href="/api/pebble/v1/snapshot"><code>/api/pebble/v1/snapshot</code></a> — versioned Pebble snapshot</li>
        </ul>
        <p style="color:#666;font-size:0.9rem;">Use Safari <em>on this device</em>; another computer’s browser cannot reach <code>127.0.0.1</code> here.</p>
        </body></html>
        """
    }

    private func jsonDouble(_ json: [String: Any], key: String) -> Double? {
        if let d = json[key] as? Double { return d }
        if let i = json[key] as? Int { return Double(i) }
        if let n = json[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    private func handleBolusRecommendationGet(query: String?) -> (Int, String, String) {
        guard let handler = recommendBolusForCarbsGrams else {
            return (503, "application/json", "{\"error\":\"recommendation_unavailable\"}")
        }
        guard let gramsStr = Self.queryParam(query, name: "grams"),
              let grams = Double(gramsStr),
              grams > 0,
              Decimal(grams) <= commandManager.maxCarbs
        else {
            return (400, "application/json", "{\"error\":\"invalid or missing grams (use ?grams=n)\"}")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var recommended = Decimal.zero
        Task {
            recommended = await handler(grams)
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 8)
        if waitResult == .timedOut {
            return (504, "application/json", "{\"error\":\"calculation_timeout\"}")
        }

        let maxU = Double(truncating: NSDecimalNumber(decimal: commandManager.maxBolus))
        var unitsDouble = Double(truncating: NSDecimalNumber(decimal: Swift.max(Decimal(0), recommended)))
        unitsDouble = min(unitsDouble, maxU)
        let tenths = Int((unitsDouble * 10.0).rounded(.toNearestOrAwayFromZero))
        PebbleIntegrationFileLogger.log(
            "http_get",
            "GET /api/pebble/v1/bolus_recommendation grams=\(String(format: "%.0f", grams)) → \(String(format: "%.3f", unitsDouble))U tenths=\(tenths)"
        )
        let body =
            "{\"grams\":\(Int(grams)),\"recommendedUnits\":\(String(format: "%.3f", unitsDouble)),\"recommendedUnitsTenths\":\(tenths)}"
        return (200, "application/json", body)
    }

    private func handleBolusRequest(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let units = jsonDouble(json, key: "units")
        else {
            debug(.service, "Pebble HTTP: /api/bolus rejected — missing body or invalid JSON")
            return (400, "application/json", "{\"error\":\"invalid request, requires 'units'\"}")
        }

        guard let command = commandManager.queueBolus(units: units) else {
            return (400, "application/json", "{\"error\":\"bolus exceeds safety limits\"}")
        }

        PebbleIntegrationFileLogger.log("http_post", "POST /api/bolus → delivered id=\(command.id) units=\(String(format: "%.2f", units))U")
        return (
            200,
            "application/json",
            "{\"status\":\"delivered\",\"type\":\"bolus\",\"commandId\":\"\(command.id)\",\"units\":\(String(format: "%.2f", units))}"
        )
    }

    private func handleCarbRequest(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grams = jsonDouble(json, key: "grams")
        else {
            debug(.service, "Pebble HTTP: /api/carbs rejected — missing body or invalid JSON")
            return (400, "application/json", "{\"error\":\"invalid request, requires 'grams'\"}")
        }

        let absorptionHours = jsonDouble(json, key: "absorptionHours") ?? 3.0

        guard let command = commandManager.queueCarbEntry(grams: grams, absorptionHours: absorptionHours) else {
            return (400, "application/json", "{\"error\":\"carb amount exceeds safety limits\"}")
        }

        PebbleIntegrationFileLogger.log(
            "http_post",
            "POST /api/carbs → delivered id=\(command.id) grams=\(String(format: "%.0f", grams))g absorption=\(String(format: "%.1f", absorptionHours))h"
        )
        return (
            200,
            "application/json",
            "{\"status\":\"delivered\",\"type\":\"carbEntry\",\"commandId\":\"\(command.id)\",\"grams\":\(String(format: "%.0f", grams))}"
        )
    }

    private func handleConfirmCommand(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandId = json["commandId"] as? String
        else { return (400, "application/json", "{\"error\":\"requires 'commandId'\"}") }

        PebbleIntegrationFileLogger.log("http_post", "POST /api/command/confirm commandId=\(commandId)")
        commandManager.confirmCommand(commandId)
        return (200, "application/json", "{\"status\":\"confirmed\"}")
    }

    private func handleRejectCommand(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandId = json["commandId"] as? String
        else { return (400, "application/json", "{\"error\":\"requires 'commandId'\"}") }

        PebbleIntegrationFileLogger.log("http_post", "POST /api/command/reject commandId=\(commandId)")
        commandManager.rejectCommand(commandId)
        return (200, "application/json", "{\"status\":\"rejected\"}")
    }

    private func buildHTTPResponse(statusCode: Int, contentType: String, body: String) -> String {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }
        return "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n\(body)"
    }
}

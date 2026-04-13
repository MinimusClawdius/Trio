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
/// **suspend** Trio when another app is frontmost, so Safari/Rebble cannot rely on this URL staying
/// reachable indefinitely — only a ~25s background extension is started per accepted connection.
final class PebbleLocalAPIServer {
    private static let headerSeparator = Data("\r\n\r\n".utf8)
    /// Cap total request size (headers + body) to avoid unbounded reads.
    private static let maxRequestBytes = 512 * 1024

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let port: UInt16
    private let dataBridge: PebbleDataBridge
    private let commandManager: PebbleCommandManager

    init(dataBridge: PebbleDataBridge, commandManager: PebbleCommandManager, port: UInt16 = 8080) {
        self.dataBridge = dataBridge
        self.commandManager = commandManager
        self.port = port
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
        guard !isRunning else { return }
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.runServer()
        }
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func runServer() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            debug(.service, "Pebble: failed to create socket")
            return
        }

        var enable: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &enable, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverSocket, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            debug(.service, "Pebble: failed to bind to port \(port)")
            close(serverSocket)
            return
        }

        guard listen(serverSocket, 5) == 0 else {
            debug(.service, "Pebble: failed to listen")
            close(serverSocket)
            return
        }

        isRunning = true
        debug(.service, "Pebble: API server started on http://127.0.0.1:\(port)")

        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverSocket, sa, &clientAddrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning { debug(.service, "Pebble: accept failed") }
                continue
            }

            // Give Trio a short background window so Rebble can complete HTTP while Trio is not foreground.
            Self.beginShortBackgroundTask()

            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.handleRequest(clientSocket)
            }
        }
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

        let (statusCode, contentType, responseBody) = routeRequest(method: parsed.method, path: parsed.path, body: parsed.body)
        let response = buildHTTPResponse(statusCode: statusCode, contentType: contentType, body: responseBody)
        let responseData = [UInt8](response.utf8)
        _ = write(clientSocket, responseData, responseData.count)
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
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
        let path = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        return ParsedHTTPRequest(method: method, path: path, body: bodyString)
    }

    private func routeRequest(method: String, path: String, body: String?) -> (Int, String, String) {
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

        return (202, "application/json", "{\"status\":\"pending_confirmation\",\"commandId\":\"\(command.id)\",\"message\":\"Confirm \(String(format: "%.2f", units))U bolus on iPhone\",\"type\":\"bolus\"}")
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

        return (202, "application/json", "{\"status\":\"pending_confirmation\",\"commandId\":\"\(command.id)\",\"message\":\"Confirm \(String(format: "%.0f", grams))g carbs on iPhone\",\"type\":\"carbEntry\"}")
    }

    private func handleConfirmCommand(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandId = json["commandId"] as? String
        else { return (400, "application/json", "{\"error\":\"requires 'commandId'\"}") }

        commandManager.confirmCommand(commandId)
        return (200, "application/json", "{\"status\":\"confirmed\"}")
    }

    private func handleRejectCommand(_ body: String?) -> (Int, String, String) {
        guard let body = body,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandId = json["commandId"] as? String
        else { return (400, "application/json", "{\"error\":\"requires 'commandId'\"}") }

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

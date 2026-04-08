import Foundation

/// Maps the Pebble watchface AppMessage keys (C enum in `trio_types.h`)
/// to `NSNumber` keys for building `NSDictionary` payloads sent via PebbleKit iOS.
///
/// Values **must** stay synchronised with `trio_types.h : AppMessageKey` and
/// `src/pkjs/index.js : K`.
enum PebbleAppMessageKey: Int, CaseIterable {
    case glucose = 0
    case trend = 1
    case delta = 2
    case iob = 3
    case cob = 4
    case lastLoop = 5
    case glucoseStale = 6
    case cmdType = 7
    case cmdAmount = 8
    case cmdStatus = 9
    case graphData = 10
    case graphCount = 11
    case loopStatus = 12
    case units = 13
    case pumpStatus = 14
    case reservoir = 15

    case configFaceType = 16
    case configDataSource = 17
    case configHighThreshold = 18
    case configLowThreshold = 19
    case configAlertHighEnabled = 20
    case configAlertLowEnabled = 21
    case configAlertUrgentLow = 22
    case configAlertSnoozeMin = 23
    case configColorScheme = 24

    case batteryPhone = 25
    case weatherTemp = 26
    case weatherIcon = 27
    case steps = 28
    case heartRate = 29

    case predictionsData = 30
    case predictionsCount = 31
    case pumpBattery = 32
    case sensorAge = 33
    case configChanged = 34
    case tapAction = 35
    case configWeatherEnabled = 36
    case configCompSlot0 = 37
    case configCompSlot1 = 38
    case configCompSlot2 = 39
    case configCompSlot3 = 40
    case configClock24h = 41
    case configGraphScaleMode = 42
    case configGraphTimeRange = 43
    /// Short HTTP/Trio link hint from PebbleKit JS (e.g. `No phone`, `Old 3m`). Cleared when a full CGM update arrives.
    case trioLink = 44

    // Last key = 44. Must match `trio-pebble/package.json` messageKeys and `trio_types.h` / `index.js` `K`.

    /// `NSNumber` suitable for use as an `NSDictionary` key in PebbleKit iOS messages.
    var nsKey: NSNumber { NSNumber(value: rawValue) }
}

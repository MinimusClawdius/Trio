// ============================================================
// Trio Pebble v2.0 - PebbleKit JS Bridge
// Multi-source data fetching, configuration, weather, commands
// ============================================================

var POLL_INTERVAL_MS = 30000;
/// When Trio iOS pushes CGM/loop over PebbleKit BLE, JS polling is only a fallback (detect disconnect, non-BLE paths).
var POLL_INTERVAL_BLE_ACTIVE_MS = 120000;
var WEATHER_INTERVAL_MS = 1800000; // 30 min

var activePollIntervalMs = POLL_INTERVAL_MS;
var pollTimerId = null;

// AppMessage keys (must match C enums)
var K = {
    GLUCOSE: 0, TREND: 1, DELTA: 2, IOB: 3, COB: 4,
    LAST_LOOP: 5, GLUCOSE_STALE: 6, CMD_TYPE: 7, CMD_AMOUNT: 8,
    CMD_STATUS: 9, GRAPH_DATA: 10, GRAPH_COUNT: 11, LOOP_STATUS: 12,
    UNITS: 13, PUMP_STATUS: 14, RESERVOIR: 15,
    CONFIG_FACE_TYPE: 16, CONFIG_DATA_SOURCE: 17,
    CONFIG_HIGH_THRESHOLD: 18, CONFIG_LOW_THRESHOLD: 19,
    CONFIG_ALERT_HIGH_ENABLED: 20, CONFIG_ALERT_LOW_ENABLED: 21,
    CONFIG_ALERT_URGENT_LOW: 22, CONFIG_ALERT_SNOOZE_MIN: 23,
    CONFIG_COLOR_SCHEME: 24,
    BATTERY_PHONE: 25, WEATHER_TEMP: 26, WEATHER_ICON: 27,
    STEPS: 28, HEART_RATE: 29,
    PREDICTIONS_DATA: 30, PREDICTIONS_COUNT: 31,
    PUMP_BATTERY: 32, SENSOR_AGE: 33,
    CONFIG_CHANGED: 34, TAP_ACTION: 35
};

// ---------- Settings ----------
var settings = {
    dataSource: 0,        // 0=Trio, 1=Dexcom, 2=Nightscout
    trioHost: 'http://127.0.0.1:8080',
    nightscoutUrl: '',
    nightscoutToken: '',
    dexcomUsername: '',
    dexcomPassword: '',
    dexcomServer: 'us',   // 'us' or 'ous' (outside US)
    faceType: 0,
    colorScheme: 0,
    highThreshold: 180,
    lowThreshold: 70,
    urgentLow: 55,
    alertHighEnabled: true,
    alertLowEnabled: true,
    alertSnoozeMin: 15,
    weatherEnabled: true,
    weatherUnits: 'f',    // 'f' or 'c'
    /** Watch display only. Trio JSON may stay mmol/L; conversion uses API units, not this. */
    displayMmol: true
};

function watchDisplayUsesMmol() {
    return settings.displayMmol !== false;
}

function displayUnitsAppMessageKey() {
    return watchDisplayUsesMmol() ? 'mmol/L' : 'mg/dL';
}

function loadSettings() {
    try {
        var saved = localStorage.getItem('trio_settings');
        if (saved) {
            var parsed = JSON.parse(saved);
            for (var key in parsed) {
                if (parsed.hasOwnProperty(key)) settings[key] = parsed[key];
            }
        }
    } catch (e) {
        console.log('Trio: settings load error: ' + e);
    }
}

function saveSettings() {
    localStorage.setItem('trio_settings', JSON.stringify(settings));
}

// ---------- Data Source: Trio Local API ----------
function fetchTrio(callback) {
    httpGet(settings.trioHost + '/api/all', function (data) {
        if (!data) return callback(null);
        try {
            var parsed = JSON.parse(data);
            callback(normalizeTrio(parsed));
        } catch (e) {
            console.log('Trio: parse error: ' + e);
            callback(null);
        }
    });
}

/** True if Trio reported mmol/L (watch protocol uses mg/dL ints for glucose + graph). */
function trioCgmUsesMmol(units) {
    if (units == null) return false;
    return String(units).toLowerCase().indexOf('mmol') >= 0;
}

function trioParseGlucoseNumber(raw) {
    if (raw == null || raw === '') return NaN;
    if (typeof raw === 'number') return raw;
    return parseFloat(String(raw).replace(',', '.'));
}

/**
 * Trio /api/all may send mmol as "5.4" and history as [5.2, 5.4, ...].
 * parseInt("5.4") === 5 was wrongly treated as mg/dL → false urgent-low vibes + flat graph.
 * Always send KEY_GLUCOSE and graph points as mg/dL integers.
 * KEY_UNITS (watch display) is set from Pebble settings (displayMmol), not from Trio's API units.
 */
function normalizeTrio(data) {
    var cgm = data.cgm || {};
    var loop = data.loop || {};
    var blePush = data.blePushActive === true || data.blePushActive === 'true';
    var units = cgm.units || 'mgdL';
    var isMmol = trioCgmUsesMmol(units);

    var gNum = trioParseGlucoseNumber(cgm.glucose);
    var glucoseMgdl = 0;
    if (!isNaN(gNum) && gNum > 0) {
        glucoseMgdl = isMmol ? Math.round(gNum * 18.0) : Math.round(gNum);
    }

    var histIn = loop.glucoseHistory || [];
    var historyMgdl = [];
    for (var i = 0; i < histIn.length; i++) {
        var v = trioParseGlucoseNumber(histIn[i]);
        if (isNaN(v) || v <= 0) continue;
        var mg = isMmol ? Math.round(v * 18.0) : Math.round(v);
        if (mg > 0 && mg <= 65535) historyMgdl.push(mg);
    }

    return {
        glucose: glucoseMgdl,
        trend: cgm.trend || '--',
        delta: cgm.delta || '',
        isStale: cgm.isStale || false,
        iob: loop.iob || '',
        cob: loop.cob || '',
        lastLoop: loop.lastLoopTime || '',
        history: historyMgdl,
        pumpStatus: '',
        reservoir: 0,
        pumpBattery: 0,
        sensorAge: '',
        blePushActive: blePush
    };
}


// ---------- Data Source: Nightscout ----------
function fetchNightscout(callback) {
    var url = settings.nightscoutUrl.replace(/\/$/, '');
    var tokenParam = settings.nightscoutToken ? '?token=' + settings.nightscoutToken : '';

    httpGet(url + '/api/v1/entries/sgv.json?count=48' + (tokenParam ? '&token=' + settings.nightscoutToken : ''), function (sgvData) {
        if (!sgvData) return callback(null);
        try {
            var entries = JSON.parse(sgvData);
            httpGet(url + '/api/v1/properties/iob,cob,loop' + tokenParam, function (propData) {
                var props = {};
                try { props = JSON.parse(propData || '{}'); } catch (e) { /* ok */ }
                callback(normalizeNightscout(entries, props));
            });
        } catch (e) {
            console.log('Trio: Nightscout parse error: ' + e);
            callback(null);
        }
    });
}

function normalizeNightscout(entries, props) {
    if (!entries || entries.length === 0) return null;
    var latest = entries[0];

    var delta = '';
    if (entries.length >= 2) {
        var d = latest.sgv - entries[1].sgv;
        delta = (d >= 0 ? '+' : '') + d;
    }

    var iob = props.iob && props.iob.iob ? props.iob.iob.iob.toFixed(1) : '';
    var cob = props.cob && props.cob.cob ? Math.round(props.cob.cob.cob).toString() : '';
    var lastLoop = '';
    if (props.loop && props.loop.loop && props.loop.loop.lastLoop) {
        var loopAge = Math.round((Date.now() - new Date(props.loop.loop.lastLoop.timestamp).getTime()) / 60000);
        lastLoop = loopAge + ' min';
    }

    var history = entries.slice(0, 48).map(function (e) { return e.sgv; }).reverse();

    return {
        glucose: latest.sgv || 0,
        trend: directionToArrow(latest.direction),
        delta: delta,
        isStale: (Date.now() - latest.date) > 15 * 60 * 1000,
        units: 'mgdL',
        iob: iob,
        cob: cob,
        lastLoop: lastLoop,
        history: history,
        pumpStatus: '',
        reservoir: 0,
        pumpBattery: 0,
        sensorAge: ''
    };
}

// ---------- Data Source: Dexcom Share ----------
var dexcomSessionId = null;

function fetchDexcom(callback) {
    var server = settings.dexcomServer === 'ous'
        ? 'https://shareous1.dexcom.com'
        : 'https://share2.dexcom.com';

    var loginUrl = server + '/ShareWebServices/Services/General/LoginPublisherAccountByName';
    var readUrl = server + '/ShareWebServices/Services/Publisher/ReadPublisherLatestGlucoseValues';

    function doRead(sessionId) {
        httpPost(readUrl + '?sessionId=' + sessionId + '&minutes=180&maxCount=48', '', function (data) {
            if (!data) return callback(null);
            try {
                var entries = JSON.parse(data);
                callback(normalizeDexcom(entries));
            } catch (e) {
                console.log('Trio: Dexcom parse error: ' + e);
                callback(null);
            }
        });
    }

    if (dexcomSessionId) {
        doRead(dexcomSessionId);
        return;
    }

    var loginBody = JSON.stringify({
        accountName: settings.dexcomUsername,
        password: settings.dexcomPassword,
        applicationId: 'd89443d2-327c-4a6f-89e5-496bbb0317db'
    });

    httpPost(loginUrl, loginBody, function (data) {
        if (!data) return callback(null);
        try {
            dexcomSessionId = JSON.parse(data);
            doRead(dexcomSessionId);
        } catch (e) {
            console.log('Trio: Dexcom login error: ' + e);
            callback(null);
        }
    });
}

function normalizeDexcom(entries) {
    if (!entries || entries.length === 0) return null;
    var latest = entries[0];
    var glucose = latest.Value || 0;

    var delta = '';
    if (entries.length >= 2) {
        var d = glucose - (entries[1].Value || 0);
        delta = (d >= 0 ? '+' : '') + d;
    }

    var dateMatch = (latest.ST || latest.WT || '').match(/\d+/);
    var timestamp = dateMatch ? parseInt(dateMatch[0], 10) : Date.now();
    var isStale = (Date.now() - timestamp) > 15 * 60 * 1000;

    var history = entries.slice(0, 48).map(function (e) { return e.Value; }).reverse();

    return {
        glucose: glucose,
        trend: dexcomTrendToArrow(latest.Trend),
        delta: delta,
        isStale: isStale,
        units: 'mgdL',
        iob: '', cob: '', lastLoop: '',
        history: history,
        pumpStatus: '',
        reservoir: 0,
        pumpBattery: 0,
        sensorAge: ''
    };
}

function dexcomTrendToArrow(trend) {
    var map = {
        'DoubleUp': '↑↑', 'SingleUp': '↑', 'FortyFiveUp': '↗',
        'Flat': '→', 'FortyFiveDown': '↘', 'SingleDown': '↓',
        'DoubleDown': '↓↓', 'None': '--', 'NotComputable': '?',
        'RateOutOfRange': '⚠'
    };
    // Also handle numeric trends (1-9)
    if (typeof trend === 'number') {
        var numMap = ['--', '↑↑', '↑', '↗', '→', '↘', '↓', '↓↓', '?', '⚠'];
        return numMap[trend] || '--';
    }
    return map[trend] || '--';
}

function directionToArrow(direction) {
    var map = {
        'DoubleUp': '↑↑', 'SingleUp': '↑', 'FortyFiveUp': '↗',
        'Flat': '→', 'FortyFiveDown': '↘', 'SingleDown': '↓',
        'DoubleDown': '↓↓', 'NONE': '--', 'NOT COMPUTABLE': '?'
    };
    return map[direction] || direction || '--';
}

// ---------- Fetch Dispatcher ----------
function desiredPollIntervalMs(data) {
    if (settings.dataSource !== 0) return POLL_INTERVAL_MS;
    if (data && data.blePushActive) return POLL_INTERVAL_BLE_ACTIVE_MS;
    return POLL_INTERVAL_MS;
}

function applyAdaptivePollingAfterFetch(data) {
    var next = desiredPollIntervalMs(data);
    if (next === activePollIntervalMs && pollTimerId !== null) return;
    activePollIntervalMs = next;
    if (pollTimerId !== null) {
        clearInterval(pollTimerId);
        pollTimerId = null;
    }
    pollTimerId = setInterval(fetchData, activePollIntervalMs);
}

function fetchData() {
    var fetcher;
    switch (settings.dataSource) {
        case 1:  fetcher = fetchDexcom; break;
        case 2:  fetcher = fetchNightscout; break;
        default: fetcher = fetchTrio; break;
    }

    fetcher(function (data) {
        if (data) {
            // Trio + PebbleKit iOS BLE: phone pushes data; still send KEY_UNITS so display preference sticks.
            var skipSend = settings.dataSource === 0 && data.blePushActive === true;
            if (!skipSend) {
                sendToWatch(data);
            } else {
                var uonly = {};
                uonly[K.UNITS] = displayUnitsAppMessageKey();
                Pebble.sendAppMessage(uonly);
            }
        }
        applyAdaptivePollingAfterFetch(data);
    });
}

// ---------- Send to Watch ----------
function sendToWatch(data) {
    var msg = {};

    msg[K.UNITS] = displayUnitsAppMessageKey();

    if (data.glucose != null && data.glucose !== '' && !isNaN(data.glucose)) {
        msg[K.GLUCOSE] = data.glucose;
    }
    if (data.trend) msg[K.TREND] = data.trend.substring(0, 7);
    if (data.delta) msg[K.DELTA] = data.delta.substring(0, 15);
    if (data.iob) msg[K.IOB] = data.iob.substring(0, 15);
    if (data.cob) msg[K.COB] = data.cob.substring(0, 15);
    if (data.lastLoop) msg[K.LAST_LOOP] = data.lastLoop.substring(0, 15);
    if (data.pumpStatus) msg[K.PUMP_STATUS] = data.pumpStatus.substring(0, 15);
    if (data.sensorAge) msg[K.SENSOR_AGE] = data.sensorAge.substring(0, 15);

    msg[K.GLUCOSE_STALE] = data.isStale ? 1 : 0;
    if (data.reservoir) msg[K.RESERVOIR] = data.reservoir;
    if (data.pumpBattery) msg[K.PUMP_BATTERY] = data.pumpBattery;

    // Graph data as packed uint16 LE bytes (mg/dL integers after normalizeTrio)
    var history = data.history || [];
    if (history.length > 0) {
        var count = Math.min(history.length, 48);
        var bytes = [];
        for (var i = 0; i < count; i++) {
            var val = Math.round(Number(history[i]) || 0);
            if (val < 0) val = 0;
            if (val > 65535) val = 65535;
            bytes.push(val & 0xFF);
            bytes.push((val >> 8) & 0xFF);
        }
        msg[K.GRAPH_DATA] = bytes;
        msg[K.GRAPH_COUNT] = count;
    }

    Pebble.sendAppMessage(msg,
        function () { /* success */ },
        function (e) { console.log('Trio: send failed: ' + JSON.stringify(e)); }
    );
}

// ---------- Weather ----------
var lastWeatherFetch = 0;

function fetchWeather() {
    if (!settings.weatherEnabled) return;
    if (Date.now() - lastWeatherFetch < WEATHER_INTERVAL_MS) return;

    navigator.geolocation.getCurrentPosition(function (pos) {
        var url = 'https://api.open-meteo.com/v1/forecast?latitude=' +
            pos.coords.latitude + '&longitude=' + pos.coords.longitude +
            '&current_weather=true&temperature_unit=' +
            (settings.weatherUnits === 'c' ? 'celsius' : 'fahrenheit');

        httpGet(url, function (data) {
            if (!data) return;
            try {
                var w = JSON.parse(data);
                if (w.current_weather) {
                    lastWeatherFetch = Date.now();
                    var msg = {};
                    msg[K.WEATHER_TEMP] = Math.round(w.current_weather.temperature);
                    msg[K.WEATHER_ICON] = weatherCodeToIcon(w.current_weather.weathercode);
                    Pebble.sendAppMessage(msg);
                }
            } catch (e) {
                console.log('Trio: weather parse error: ' + e);
            }
        });
    }, function () {
        console.log('Trio: geolocation unavailable');
    }, { timeout: 15000, maximumAge: 600000 });
}

function weatherCodeToIcon(code) {
    if (code <= 1) return 'clear';
    if (code <= 3) return 'cloudy';
    if (code <= 48) return 'fog';
    if (code <= 67) return 'rain';
    if (code <= 77) return 'snow';
    if (code <= 82) return 'rain';
    if (code <= 86) return 'snow';
    return 'storm';
}

// ---------- Commands from Watch ----------
function sendCommand(type, amount) {
    if (settings.dataSource !== 0) {
        // Commands only work with Trio data source
        var msg = {};
        msg[K.CMD_STATUS] = 'Commands require Trio';
        Pebble.sendAppMessage(msg);
        return;
    }

    var endpoint = type === 1 ? '/api/bolus' : '/api/carbs';
    var body = type === 1
        ? JSON.stringify({ units: amount / 10.0 })
        : JSON.stringify({ grams: amount, absorptionHours: 3 });

    httpPost(settings.trioHost + endpoint, body, function (resp) {
        var statusMsg = 'Sent';
        try {
            var r = JSON.parse(resp || '{}');
            statusMsg = r.message || r.status || 'Sent';
        } catch (e) { /* ok */ }
        var msg = {};
        msg[K.CMD_STATUS] = statusMsg.substring(0, 63);
        Pebble.sendAppMessage(msg);
    });
}

// ---------- Configuration Page ----------
Pebble.addEventListener('showConfiguration', function () {
    var configUrl = 'https://minimusclawdius.github.io/trio-pebble/config/index.html';
    var params = encodeURIComponent(JSON.stringify(settings));
    Pebble.openURL(configUrl + '#' + params);
});

Pebble.addEventListener('webviewclosed', function (e) {
    if (e && e.response) {
        try {
            var newSettings = JSON.parse(decodeURIComponent(e.response));
            for (var key in newSettings) {
                if (newSettings.hasOwnProperty(key)) settings[key] = newSettings[key];
            }
            saveSettings();
            dexcomSessionId = null; // reset on credential change

            // Push config to watch
            var msg = {};
            msg[K.CONFIG_CHANGED] = 1;
            msg[K.CONFIG_FACE_TYPE] = settings.faceType;
            msg[K.CONFIG_DATA_SOURCE] = settings.dataSource;
            msg[K.CONFIG_HIGH_THRESHOLD] = settings.highThreshold;
            msg[K.CONFIG_LOW_THRESHOLD] = settings.lowThreshold;
            msg[K.CONFIG_ALERT_URGENT_LOW] = settings.urgentLow;
            msg[K.CONFIG_ALERT_HIGH_ENABLED] = settings.alertHighEnabled ? 1 : 0;
            msg[K.CONFIG_ALERT_LOW_ENABLED] = settings.alertLowEnabled ? 1 : 0;
            msg[K.CONFIG_ALERT_SNOOZE_MIN] = settings.alertSnoozeMin;
            msg[K.CONFIG_COLOR_SCHEME] = settings.colorScheme;
            msg[K.UNITS] = displayUnitsAppMessageKey();
            Pebble.sendAppMessage(msg);

            // Re-fetch with new source
            fetchData();
        } catch (ex) {
            console.log('Trio: config parse error: ' + ex);
        }
    }
});

// ---------- Watch Messages ----------
Pebble.addEventListener('appmessage', function (e) {
    var p = e.payload;
    if (p[K.CMD_TYPE] !== undefined && p[K.CMD_AMOUNT] !== undefined) {
        sendCommand(p[K.CMD_TYPE], p[K.CMD_AMOUNT]);
    } else if (p[K.TAP_ACTION] !== undefined) {
        if (p[K.TAP_ACTION] === 4) fetchData(); // TAP_ACTION_REFRESH
    } else {
        fetchData();
    }
});

// ---------- Ready ----------
Pebble.addEventListener('ready', function () {
    console.log('Trio Pebble v2.0 ready');
    loadSettings();

    // Push initial config
    var msg = {};
    msg[K.CONFIG_FACE_TYPE] = settings.faceType;
    msg[K.CONFIG_DATA_SOURCE] = settings.dataSource;
    msg[K.CONFIG_HIGH_THRESHOLD] = settings.highThreshold;
    msg[K.CONFIG_LOW_THRESHOLD] = settings.lowThreshold;
    msg[K.CONFIG_COLOR_SCHEME] = settings.colorScheme;
    msg[K.UNITS] = displayUnitsAppMessageKey();
    Pebble.sendAppMessage(msg);

    fetchData();
    fetchWeather();
    // First `fetchData` schedules `pollTimerId` via `applyAdaptivePollingAfterFetch`.
    setInterval(fetchWeather, WEATHER_INTERVAL_MS);
});

// ---------- HTTP Helpers ----------
function httpGet(url, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.timeout = 15000;
    xhr.onload = function () {
        callback(xhr.status === 200 ? xhr.responseText : null);
    };
    xhr.onerror = function () { callback(null); };
    xhr.ontimeout = function () { callback(null); };
    xhr.send();
}

function httpPost(url, body, callback) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.timeout = 15000;
    xhr.onload = function () {
        callback(xhr.responseText);
    };
    xhr.onerror = function () { callback(null); };
    xhr.ontimeout = function () { callback(null); };
    xhr.send(body);
}

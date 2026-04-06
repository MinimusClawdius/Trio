/*
 * Trio CGM Monitor - PebbleKit JS Bridge
 *
 * Runs inside the Rebble companion app on iPhone.
 * Fetches Trio data from localhost HTTP server and forwards
 * to the Pebble C watchapp via AppMessage.
 * Handles bolus/carb command requests in reverse direction.
 */

var API_BASE = 'http://127.0.0.1:8080';

// Match messageKeys in package.json
var Keys = {
    GLUCOSE:          'KEY_GLUCOSE',
    TREND:            'KEY_TREND',
    IOB:              'KEY_IOB',
    IS_CLOSED_LOOP:   'KEY_IS_CLOSED_LOOP',
    COB:              'KEY_COB',
    DELTA:            'KEY_DELTA',
    REQUEST_DATA:     'KEY_REQUEST_DATA',
    BOLUS_REQUEST:    'KEY_BOLUS_REQUEST',
    CARB_REQUEST:     'KEY_CARB_REQUEST',
    ABSORPTION_HOURS: 'KEY_ABSORPTION_HOURS',
    COMMAND_STATUS:   'KEY_COMMAND_STATUS',
    COMMAND_MSG:      'KEY_COMMAND_MSG',
    GRAPH_COUNT:      'KEY_GRAPH_COUNT',
    GRAPH_VALUES:     'KEY_GRAPH_VALUES',
    EVENTUAL_BG:      'KEY_EVENTUAL_BG',
    LAST_LOOP_MINS:   'KEY_LAST_LOOP_MINS'
};

function fetchAllData() {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', API_BASE + '/api/all', true);
    xhr.timeout = 10000;

    xhr.onload = function () {
        if (xhr.status === 200) {
            try {
                var data = JSON.parse(xhr.responseText);
                sendDataToWatch(data);
            } catch (e) {
                console.log('Trio Pebble: JSON parse error: ' + e);
            }
        } else {
            console.log('Trio Pebble: HTTP error: ' + xhr.status);
        }
    };

    xhr.ontimeout = function () {
        console.log('Trio Pebble: request timeout');
    };

    xhr.onerror = function () {
        console.log('Trio Pebble: request error - is Trio running with Pebble enabled?');
    };

    xhr.send();
}

function sendDataToWatch(data) {
    var message = {};

    // CGM data
    if (data.cgm) {
        if (data.cgm.glucose !== null && data.cgm.glucose !== undefined) {
            var glucoseStr = data.cgm.glucose.toString();
            var glucoseNum = parseFloat(glucoseStr);
            if (!isNaN(glucoseNum)) {
                message[Keys.GLUCOSE] = Math.round(glucoseNum);
            }
        }
        if (data.cgm.trend) {
            message[Keys.TREND] = data.cgm.trend;
        }
        if (data.cgm.delta !== null && data.cgm.delta !== undefined) {
            var deltaStr = data.cgm.delta.toString().replace('+', '');
            var deltaNum = parseFloat(deltaStr);
            if (!isNaN(deltaNum)) {
                message[Keys.DELTA] = Math.round(deltaNum * 10);
            }
        }
    }

    // Loop data
    if (data.loop) {
        if (data.loop.iob !== null && data.loop.iob !== undefined) {
            message[Keys.IOB] = Math.round(parseFloat(data.loop.iob) * 10);
        }
        message[Keys.IS_CLOSED_LOOP] = (data.loop.isClosedLoop === true) ? 1 : 0;

        if (data.loop.cob !== null && data.loop.cob !== undefined) {
            message[Keys.COB] = Math.round(parseFloat(data.loop.cob));
        }
        if (data.loop.lastLoopMins !== null && data.loop.lastLoopMins !== undefined) {
            message[Keys.LAST_LOOP_MINS] = data.loop.lastLoopMins;
        }
        if (data.loop.eventualBG !== null && data.loop.eventualBG !== undefined) {
            var ebg = parseFloat(data.loop.eventualBG);
            if (!isNaN(ebg)) {
                message[Keys.EVENTUAL_BG] = Math.round(ebg);
            }
        }

        // Glucose history for the graph
        if (data.loop.glucoseHistory && data.loop.glucoseHistory.length > 0) {
            var values = data.loop.glucoseHistory;
            var count = Math.min(values.length, 36);
            message[Keys.GRAPH_COUNT] = count;

            // Pack as uint16 little-endian byte array
            var bytes = [];
            for (var i = 0; i < count; i++) {
                var v = values[i];
                if (v < 0) v = 0;
                if (v > 65535) v = 65535;
                bytes.push(v & 0xFF);
                bytes.push((v >> 8) & 0xFF);
            }
            message[Keys.GRAPH_VALUES] = bytes;
        }
    }

    Pebble.sendAppMessage(message,
        function () { console.log('Trio Pebble: data sent to watch'); },
        function (e) { console.log('Trio Pebble: error sending to watch: ' + JSON.stringify(e)); }
    );
}

// Bolus request from watch
function requestBolus(units) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', API_BASE + '/api/bolus', true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.timeout = 10000;

    xhr.onload = function () {
        if (xhr.status === 202) {
            try {
                var response = JSON.parse(xhr.responseText);
                Pebble.sendAppMessage({
                    'KEY_COMMAND_STATUS': 1,
                    'KEY_COMMAND_MSG': response.message || 'Confirm on iPhone'
                });
            } catch (e) {
                console.log('Trio Pebble: bolus response parse error');
            }
        } else {
            Pebble.sendAppMessage({
                'KEY_COMMAND_STATUS': -1,
                'KEY_COMMAND_MSG': 'Bolus request failed'
            });
        }
    };

    xhr.onerror = function () {
        Pebble.sendAppMessage({
            'KEY_COMMAND_STATUS': -1,
            'KEY_COMMAND_MSG': 'Connection error'
        });
    };

    xhr.send(JSON.stringify({ units: units }));
}

// Carb entry request from watch
function requestCarbEntry(grams, absorptionHours) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', API_BASE + '/api/carbs', true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.timeout = 10000;

    xhr.onload = function () {
        if (xhr.status === 202) {
            try {
                var response = JSON.parse(xhr.responseText);
                Pebble.sendAppMessage({
                    'KEY_COMMAND_STATUS': 1,
                    'KEY_COMMAND_MSG': response.message || 'Confirm on iPhone'
                });
            } catch (e) {
                console.log('Trio Pebble: carbs response parse error');
            }
        } else {
            Pebble.sendAppMessage({
                'KEY_COMMAND_STATUS': -1,
                'KEY_COMMAND_MSG': 'Carb request failed'
            });
        }
    };

    xhr.onerror = function () {
        Pebble.sendAppMessage({
            'KEY_COMMAND_STATUS': -1,
            'KEY_COMMAND_MSG': 'Connection error'
        });
    };

    xhr.send(JSON.stringify({
        grams: grams,
        absorptionHours: absorptionHours || 3
    }));
}

// Handle messages from the Pebble watch
Pebble.addEventListener('appmessage', function (e) {
    var payload = e.payload;

    if (payload[Keys.REQUEST_DATA] || payload.KEY_REQUEST_DATA) {
        fetchAllData();
    } else if (payload[Keys.BOLUS_REQUEST] || payload.KEY_BOLUS_REQUEST) {
        var rawUnits = payload[Keys.BOLUS_REQUEST] || payload.KEY_BOLUS_REQUEST;
        var units = rawUnits / 20.0;
        requestBolus(units);
    } else if (payload[Keys.CARB_REQUEST] || payload.KEY_CARB_REQUEST) {
        var grams = payload[Keys.CARB_REQUEST] || payload.KEY_CARB_REQUEST;
        var absorption = payload[Keys.ABSORPTION_HOURS] || payload.KEY_ABSORPTION_HOURS || 3;
        requestCarbEntry(grams, absorption);
    }
});

Pebble.addEventListener('ready', function () {
    console.log('Trio Pebble: PebbleKit JS ready');
    fetchAllData();
});

// Auto-refresh every 5 minutes
setInterval(function () {
    console.log('Trio Pebble: auto-refresh');
    fetchAllData();
}, 5 * 60 * 1000);

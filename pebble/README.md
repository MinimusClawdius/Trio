# Trio CGM Monitor - Pebble Watch App

Displays real-time glucose data from the Trio iOS app on any Pebble smartwatch, with a glucose trend graph, IOB/COB readouts, loop status, and the ability to request bolus or log carbs (with iPhone confirmation).

## Features

- Large glucose reading with trend arrow, color-coded by range
- Glucose trend graph (up to 3 hours of history)
- IOB and COB display
- Delta (rate of change)
- Loop status with time since last loop
- Bolus request (requires iPhone confirmation)
- Carb entry (requires iPhone confirmation)
- Low/high glucose vibration alerts
- Works on all Pebble models (aplite, basalt, chalk, diorite, emery)

## Architecture

```
Trio iOS App                    Rebble App (iPhone)         Pebble Watch
+-----------------+             +------------------+        +----------------+
| PebbleManager   |             | PebbleKit JS     |        | main.c         |
| LocalAPIServer  |-- HTTP ---->| pebble-js-app.js |--BT--->| glucose_graph.c|
| (127.0.0.1:8080)|<-- HTTP ---|                  |<--BT---|                |
| CommandManager  |             +------------------+        +----------------+
+-----------------+
```

The Trio app runs a localhost-only HTTP server. The PebbleKit JS component (running inside the Rebble companion app) fetches data via XHR and forwards it to the watch over Bluetooth using AppMessage. Commands flow in reverse.

## Prerequisites

1. **Pebble smartwatch** (any model)
2. **Rebble app** installed on iPhone ([rebble.io/howto](https://rebble.io/howto))
3. **Trio app** built with Pebble integration enabled
4. **Pebble SDK** (for building from source)

## Building

### Option 1: Pebble SDK CLI

```bash
# Install SDK (macOS)
brew install pebble-sdk

# Build
cd pebble/
./build.sh

# Install to watch
./build.sh --install <phone-ip>
```

### Option 2: Docker

```bash
cd pebble/
docker run -v $PWD:/app rebble/pebble-sdk pebble build
```

The build produces `trio-cgm.pbw` which can be side-loaded onto your Pebble.

## Trio iOS App Configuration

1. Open Trio on your iPhone
2. Go to **Settings > Watch Configuration**
3. In the **Pebble Watch** section, enable **Pebble Integration**
4. The API server starts on port 8080 (shown in settings)
5. Install the `trio-cgm.pbw` on your Pebble via the Rebble app

## Watch App Usage

### Main Screen

- **Top**: Current time
- **Center**: Glucose value (large), trend arrow, delta
- **Middle**: IOB (left), COB (right)
- **Status**: Loop ON/OFF with minutes since last loop
- **Graph**: 3-hour glucose trend with target range band
- **Bottom**: "SELECT for actions"

### Actions Menu

Press the **SELECT** button (middle right) to open the actions menu:

- **Request Bolus**: Use UP/DOWN to adjust amount (0.05U steps), SELECT to send
- **Log Carbs**: Use UP/DOWN to adjust grams (5g steps), SELECT to send

All commands require **explicit confirmation on your iPhone** before execution. Commands expire after 5 minutes if not confirmed.

### Alerts

The watch vibrates for:
- **Low glucose** (< 70 mg/dL): double pulse
- **High glucose** (> 180 mg/dL): short pulse

Alerts are rate-limited to once every 15 minutes.

## API Endpoints

The local server exposes these endpoints (localhost only):

| Method | Path | Description |
|--------|------|-------------|
| GET | /api/cgm | Glucose, trend, delta, stale flag |
| GET | /api/loop | IOB, COB, loop status, predictions, history |
| GET | /api/pump | Reservoir, battery (reserved) |
| GET | /api/all | Combined response |
| GET | /health | Server health check |
| POST | /api/bolus | Queue bolus (body: `{"units": 1.5}`) |
| POST | /api/carbs | Queue carbs (body: `{"grams": 30}`) |

## Safety

- Server binds to 127.0.0.1 only (no external network access)
- All bolus/carb commands require iPhone confirmation
- Configurable safety limits (max bolus, max carbs)
- Commands expire after 5 minutes
- No insulin is delivered without explicit user action on iPhone

## Troubleshooting

### Watch shows "---" for glucose
- Ensure Trio is running with Pebble integration enabled
- Check that the Rebble app is connected to your Pebble
- Wait up to 5 minutes for the first data refresh

### Commands not appearing on iPhone
- Verify Pebble integration is enabled in Trio settings
- Check the Pending Commands screen in Watch Configuration

### Build errors
- Ensure Pebble SDK is installed and `pebble` is in your PATH
- Check that all resource images exist in `resources/images/`

## License

MIT (same as Trio)

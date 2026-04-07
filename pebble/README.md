# Trio Pebble v2.0.2

A premium, configurable CGM watchface for Pebble smartwatches. Supports **Trio**, **Dexcom Share**, and **Nightscout** data sources.

## Trio + mmol/L (HTTP data source)

Trio’s `/api/cgm` reports glucose as a **string** in the user’s units (`"5.4"` for mmol/L, `"97"` for mg/dL). The watch **always** uses **mg/dL integers** internally for AppMessage keys, the **graph** (40–400 scale), and **alert thresholds** (defaults 180 / 70 / 55 mg/dL). PebbleKit JS converts mmol → mg/dL before sending; the C side formats the main glucose text back to mmol when `KEY_UNITS` indicates mmol.

## Technology (not Alloy)

This project uses the **classic Pebble SDK 3** watch code in **C** plus **PebbleKit JavaScript** (`pkjs/index.js`). It is **not** built with [Alloy](https://developer.repebble.com/guides/alloy/) (JavaScript on-watch via Moddable). Alloy today targets **Emery** and **Gabbro**; this watchface is built for **aplite, basalt, chalk, diorite, emery** including **Pebble 2 (Diorite)**.

## Features

### Multiple Watchface Layouts
Switch between 5 distinct face designs via buttons or the config page:

| Face | Description |
|------|-------------|
| **Classic** | Glucose + graph + IOB/COB/loop + complications bar |
| **Graph Focus** | Large graph + overlaid glucose; bottom complications (battery, steps, HR, **weather**) |
| **Compact** | T1000-inspired layout + bottom complications bar (**weather** on Diorite) |
| **Dashboard** | Information-dense quadrant layout with date, pump, sensor data |
| **Minimal** | Time-forward design, sparkline, and a **weather** line when data is available |

### Data Sources (Configurable)
- **Trio** - Polls local HTTP API on `127.0.0.1:8080` (requires Trio iOS app with Pebble integration enabled)
- **Dexcom Share** - Direct connection to Dexcom Share servers (US and international)
- **Nightscout** - Connects to any Nightscout instance with optional API token auth

### Dynamic Color-Coded Graph
- Green line segments when glucose is in range
- Orange when above high threshold
- Red when below low threshold or above high+60
- Target range band with dashed threshold lines
- Urgent low line in red
- Prediction line overlay (when available from Trio/Nightscout)
- Configurable thresholds via settings page

### Configurable Alerts
- **High glucose alert** - vibration when above threshold
- **Low glucose alert** - distinct vibration pattern when below threshold
- **Urgent low alert** - aggressive vibration, always active regardless of settings
- **Snooze** - press SELECT to snooze all alerts (configurable duration: 5-60 min)
- Minimum 60-second re-alert interval to prevent vibration spam

### Complications
- Watch battery percentage (with charging indicator)
- Steps (from Pebble Health)
- Heart rate (from Pebble Health, when available)
- Weather temperature (via Open-Meteo API, no API key needed). On **monochrome** watches (e.g. **Diorite / Pebble 2**), the complications bar uses **black text on a light background** and **white on dark** so weather stays visible; **0°C** still shows when the phone sends a weather **icon** key.

### Color Schemes
- **Dark** - Black background, green/red/orange glucose colors
- **Light** - White background, adapted colors for readability
- **High Contrast** - Maximum visibility for outdoor use

### Touch/Tap Framework
Built-in framework for future touch screen support. When Pebble touch capabilities become available:
- Tap graph area to open carbs entry
- Tap data area to request bolus
- Tap and hold for temp basal adjustment
- Currently uses accelerometer tap for data refresh

## Quick Start

### Option A: CloudPebble (Recommended)
1. Go to [CloudPebble](https://cloudpebble.net/)
2. Import from GitHub: `https://github.com/MinimusClawdius/trio-pebble`
3. Build and install to your Pebble

### Option B: Local Build
```bash
pebble build
pebble install --phone <your-phone-ip>
```

### Configuration
1. Open the Pebble/Rebble app on your phone
2. Find "Trio Pebble" in your watchfaces
3. Tap "Settings" to open the configuration page
4. Select your data source, thresholds, alerts, and face type

## Architecture

```
Pebble Watch (C)
├── main.c              - App lifecycle, face management, message routing
├── trio_types.h        - Shared types, enums, state structures
├── modules/
│   ├── config.c/.h     - Persistent configuration (persist API)
│   ├── graph.c/.h      - Color-coded graph with thresholds & predictions
│   ├── alerts.c/.h     - BG alerts with vibration patterns & snooze
│   ├── complications.c/.h - Battery, weather, steps, heart rate
│   └── tap_framework.c/.h - Future touch action zone system
├── faces/
│   ├── face_classic.c/.h
│   ├── face_graph_focus.c/.h
│   ├── face_compact.c/.h
│   ├── face_dashboard.c/.h
│   └── face_minimal.c/.h
└── pkjs/
    └── index.js        - Multi-source data fetching, weather, config bridge

Phone (HTML)
└── config/
    └── index.html      - Settings page (dark theme, mobile-optimized)
```

### Data Flow
```
[CGM Sensor] → [Trio App / Dexcom / Nightscout]
                           ↓
                  PebbleKit JS (index.js)
                  - Fetches from selected source
                  - Normalizes to common format
                  - Fetches weather from Open-Meteo
                           ↓
                     AppMessage
                           ↓
                  Pebble Watch (main.c)
                  - Routes to active face
                  - Updates graph, text, complications
                  - Checks alert thresholds
```

## Button Controls

| Button | Watchface Mode | Alert Active |
|--------|---------------|--------------|
| **UP** | Previous face layout | Previous face layout |
| **DOWN** | Next face layout | Next face layout |
| **SELECT** | (reserved) | Snooze alerts |
| **BACK** | Exit watchface | Exit watchface |

## Safety

- All bolus/carb commands (Trio source only) require iPhone confirmation
- Commands are not available when using Dexcom Share or Nightscout sources
- Urgent low alerts cannot be disabled
- This watchface is not FDA approved and should not be used for medical decisions

## Requirements

- Pebble / Pebble 2 (Aplite)
- Pebble Time / Time Steel (Basalt) - color support
- Pebble Time Round (Chalk)
- Pebble 2 HR (Diorite)
- Pebble Time 2 (Emery)
- Rebble app on iOS or Android

## License

MIT

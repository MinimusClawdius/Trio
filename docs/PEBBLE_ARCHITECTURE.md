# Trio Pebble Integration Architecture (0.8.1.3+)

## Overview

Trio supports two transport mechanisms for communicating with Pebble/Rebble watches:

1. **Native iOS BLE (PebbleKit)** — Preferred for data delivery
2. **Local HTTP API (loopback)** — Primary for commands, fallback for data

## Transport Comparison

| Aspect                    | Native BLE (PebbleKit)          | Local HTTP API (`127.0.0.1`)          | Winner     |
|---------------------------|----------------------------------|---------------------------------------|------------|
| Data push (glucose, IOB)  | Reliable (background capable)   | Fragile (iOS suspends Trio)           | BLE        |
| Command delivery (bolus)  | Possible but complex            | Simple + reliable queue               | HTTP       |
| Background survival       | Good (with UIBackgroundModes)   | ~25s per request only                 | BLE        |
| Setup complexity          | Requires PebbleKit framework    | No extra frameworks                   | HTTP       |
| Debugging                 | Harder (BLE logs)               | Easy (browser + file log)             | HTTP       |
| App Store size            | Adds ~2-3 MB thinned framework  | Zero overhead                         | HTTP       |

## Recommended Hybrid Model (Current)

- **Data path (glucose, trends, pump, IOB/COB)**: Native BLE when `useNativeBLEPush = true`
- **Command path (bolus, carbs from watch)**: Always via HTTP local API + `PebbleCommandManager`
- **Status feedback**: BLE `KEY_CMD_STATUS` messages sent back to watch on command completion

This gives the best of both worlds:
- Reliable background data updates via BLE
- Simple, auditable command execution via HTTP

## Key Components

### 1. PebbleService (LoopKit plugin)
- Stores user preference (`useNativeBLEPush`)
- Persists `httpPort`
- Onboarding flow

### 2. BasePebbleManager
- Owns both `PebbleLocalAPIServer` and `PebbleBLEBridge`
- Wires command execution handlers (`executeBolus`, `executeCarbs`)
- Listens for configuration changes via `NotificationCenter`

### 3. PebbleLocalAPIServer
- Lightweight BSD socket HTTP server on `127.0.0.1`
- Endpoints:
  - `GET /api/all` (and `/api/pebble/v1/snapshot`)
  - `POST /api/bolus`, `/api/carbs`
  - `POST /api/command/confirm`, `/api/command/reject`
- Uses short background tasks to stay alive briefly

### 4. PebbleBLEBridge
- Wraps `PBPebbleCentral` + `PBWatch`
- Pushes `WatchState` via AppMessage when connected
- Receives commands from watch and forwards via delegate
- Sends `KEY_CMD_STATUS` back to watch on command completion

### 5. PebbleCommandManager
- Thread-safe queue of pending bolus/carb requests
- Expiry (5 minutes)
- File logging for all state changes

## Logging

All important events are written to:
`~/Library/Caches/Trio-Pebble-Integration.log`

Tags:
- `http_server` — server lifecycle (start, bind, listen, accept, stop)
- `ble_bridge` — BLE connection events
- `pending_queued`, `confirm_execute`, `confirm_failed` — command flow
- `http_post`, `http_get` — API traffic

Export via: **Settings → Services → Pebble → Export Pebble log**

## Background Behavior

- **HTTP**: Trio gets ~25 seconds of execution time per accepted connection via `beginBackgroundTask`
- **BLE**: With `bluetooth-central` + `bluetooth-peripheral` background modes, PebbleKit can wake Trio when the watch sends an AppMessage

## Future Improvements

- Automatic fallback: if BLE disconnects for >30s, force HTTP polling
- Reconnection timer in `PebbleBLEBridge`
- Expose live BLE + HTTP status in the main dashboard
- Consider migrating from raw sockets to `NWListener` for better iOS integration

## References

- `Trio/Sources/Services/PebbleManager/`
- `Trio/Sources/Services/PebbleService/`
- `pebble/src/pkjs/index.js` (Rebble side)
- Recent commits: `498a07cce`, `6d50cb404`, `e6f0cdee1`
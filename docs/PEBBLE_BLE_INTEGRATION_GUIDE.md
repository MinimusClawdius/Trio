# Pebble BLE Push Integration Guide

> **Update (2026):** Trio’s **default** Pebble path is **PebbleKit JS + loopback HTTP** (`/api/all`). Native iOS BLE push is **optional**, **off by default**, and **not linked** in standard CI builds. See **[PEBBLE_JS_PRIMARY_ARCHITECTURE.md](./PEBBLE_JS_PRIMARY_ARCHITECTURE.md)** for the current contract and versioning.

## Overview

Trio can use **two channels**; only one should be thought of as “primary”:

| Channel | Transport | Default? | Notes |
|---------|-----------|----------|-------|
| **HTTP + JS** | `127.0.0.1` — pkjs polls Trio | **Yes** | Supported, versioned snapshot (`pebbleProtocolVersion`, `stateRevision`). |
| **Native iOS BLE** | PebbleKit iOS → Rebble → BLE | **No (opt-in)** | Requires a **linkable** modern SDK. Official PebbleKit iOS 4.0 does **not** compile on current Xcode. |

Both channels target the **same AppMessage key layout** on the watch when native push is enabled and the SDK is present.

## Architecture

```
┌────────────────────────────────────────────────────┐
│  Trio iOS App                                      │
│                                                    │
│  ┌──────────────────┐  ┌────────────────────────┐  │
│  │ PebbleDataBridge  │  │ PebbleBLEBridge        │  │
│  │ (HTTP JSON cache) │  │ (#if canImport SDK)    │  │
│  └────────┬─────────┘  └──────────┬─────────────┘  │
│           │                       │                 │
│  ┌────────▼─────────┐             │                 │
│  │ PebbleLocalAPI    │             │                 │
│  │ Server (:8080)    │             │                 │
│  └────────┬─────────┘             │                 │
└───────────┼───────────────────────┼─────────────────┘
            │                       │
     HTTP (127.0.0.1)        PebbleKit iOS IPC (if linked)
            │                       │
   ┌────────▼─────────┐   ┌────────▼─────────┐
   │  Rebble App       │   │  Rebble App       │
   │  (PebbleKit JS)   │   │  (BLE relay)      │
   └────────┬─────────┘   └────────┬──────────┘
            │                       │
            └───────────┬───────────┘
                        │ BLE
               ┌────────▼─────────┐
               │   Pebble Watch    │
               │  inbox_received() │
               └──────────────────┘
```

## Setup instructions (native BLE)

### Why there is no Podfile

The repo **does not** ship a CocoaPods `Podfile` for Pebble. **PebbleKit iOS 4.0** (last official release, 2016) fails to build on modern Xcode / GitHub Actions runners. Shipping CocoaPods would break CI for everyone for an experimental path.

`PebbleBLEBridge` uses `#if canImport(PebbleKit)`:

- **Without module:** stub — `sdkAvailable == false`, `start()` / `sendState()` no-op; Settings shows “Not linked (HTTP-only build)”.
- **With a future linkable SDK:** full `PBPebbleCentral` path compiles automatically.

### If you maintain a private fork with a modern SDK

1. Add the framework / SPM / CocoaPods module so Xcode can `import PebbleKit`.
2. Build Trio — confirm Settings → Services → Pebble → **Native BLE SDK** shows **Linked**.
3. Enable **Native iOS BLE data push (experimental)** only for testing.
4. Keep JS poll active as backup; do **not** slow pkjs polls based on `blePushActive` (that caused stale UI historically).

### Background modes (already configured)

In `Trio/Resources/Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
    ...
</array>
```

These help **pump/CGM** and would help native PebbleKit if linked. They do **not** by themselves keep the **loopback HTTP** server alive forever when Trio is suspended.

## How it works

### Data flow (HTTP + JS — primary)

1. Trio `WatchState` → `PebbleDataBridge` + `PebbleLocalAPIServer` on `127.0.0.1`.
2. Rebble runs trio-pebble **pkjs** → `GET /api/all` (or `/api/pebble/v1/snapshot`).
3. JS normalizes → `Pebble.sendAppMessage` → watch `inbox_received`.
4. Watch commands → pkjs → `POST /api/bolus` / `/api/carbs` → on-phone confirmation path.

### Adaptive HTTP keep-alive (battery)

While integration is enabled and Trio is **backgrounded**, the local server renews a short `beginBackgroundTask` about every **45s** so Rebble can still hit loopback. If there is **no HTTP traffic for ~3 minutes**, keep-alive **idle-suspends** so iOS can sleep Trio (saves battery). The next CGM/loop wake, foreground, or `ensureListening` resumes keep-alive. Foreground does not hold continuous BG tasks.

### Data flow (native BLE push — experimental)

1. `BasePebbleManager.sendState()` updates the HTTP cache and, if toggle + SDK, `PebbleBLEBridge.sendState()`.
2. Bridge builds AppMessage dict from `PebbleAppMessageKey` (must match C/JS).
3. `PBWatch.appMessagesPushUpdate` → Rebble → BLE → watch.

### Key matching

| Location | File | Purpose |
|----------|------|---------|
| C (watch) | `trio_types.h` → `AppMessageKey` | Watch-side keys |
| JS | `pkjs/index.js` → `K` | PebbleKit JS keys |
| Swift | `PebbleAppMessageKeys.swift` | Native push keys |

**Critical:** keep sequential integers in sync through **key 47** (`suggestedBolusTenths`). Last keys include `configGraphSmooth` (44), `configHeaderSize` (45), `trioLink` (46).

### Snapshot flags

- `nativeIosBlePushEnabled` — user toggle
- `blePushActive` — toggle **and** bridge reports connected watch  
PebbleKit JS must **not** slow its poll cadence when `blePushActive` is true.

## Conditional compilation

| Build | Behavior |
|-------|----------|
| Default CI / TestFlight without PebbleKit | HTTP only; BLE toggle explains SDK missing |
| Private build with PebbleKit module | Full BLE bridge; Settings shows SDK linked |

## Testing checklist

### HTTP (always)

- [ ] Enable Pebble integration → Status **HTTP server: Listening**
- [ ] **HTTP keep-alive** row: Foreground when app open; **Background keep-alive active** while Rebble polls in BG; **Idle-suspended** after ~3 min without polls
- [ ] Rebble + trio-pebble → watch glucose updates
- [ ] Export **Pebble log** after a failure
- [ ] Background Trio → confirm polls work while keep-alive active; after long idle, wake may be required

### Native BLE (only with SDK linked)

- [ ] Settings shows **Native BLE SDK: Linked**
- [ ] Enable experimental toggle → console: `PebbleBLE: started`
- [ ] Connected / pushed update logs on CGM ticks
- [ ] Without SDK: toggle explains no-op; HTTP still works

### Commands

- [ ] Bolus/carbs from watch over HTTP path
- [ ] With SDK: BLE inbound command path if exercised

## Files (Trio)

- `PebbleAppMessageKeys.swift` — keys 0…47 aligned with C/JS
- `PebbleBLEBridge.swift` — `#if canImport(PebbleKit)` + `sdkAvailable`
- `PebbleManager.swift` — dual-channel management
- `PebbleLocalAPIServer.swift` — loopback HTTP + adaptive keep-alive
- `PebbleServiceFormView.swift` — status + experimental BLE UI
- **No** root `Podfile` for PebbleKit (by design)

### trio-pebble

- `src/pkjs/index.js` — transport / normalization (primary)
- `src/trio_types.h` — AppMessage keys

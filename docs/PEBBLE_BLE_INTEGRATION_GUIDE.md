# Pebble BLE Push Integration Guide

> **Update:** Trio’s **default** Pebble path is **PebbleKit JS + loopback HTTP** (`/api/all`). Native iOS BLE push is **optional** and **off by default** (`PebbleService.useNativeBLEPush`). See **[PEBBLE_JS_PRIMARY_ARCHITECTURE.md](./PEBBLE_JS_PRIMARY_ARCHITECTURE.md)** for the current contract and versioning.

## Overview

Trio can use **two channels**; only one should be thought of as “primary”:

| Channel | Transport | Default? | Notes |
|---------|-----------|----------|-------|
| **HTTP + JS** | `127.0.0.1` — pkjs polls Trio | **Yes** | Supported, versioned snapshot (`pebbleProtocolVersion`, `stateRevision`). |
| **Native iOS BLE** | PebbleKit iOS → Rebble → BLE | **No (opt-in)** | Best-effort; enable only in Pebble service settings. |

Both channels target the **same AppMessage key layout** on the watch when native push is enabled.

## Architecture

```
┌────────────────────────────────────────────────────┐
│  Trio iOS App                                      │
│                                                    │
│  ┌──────────────────┐  ┌────────────────────────┐  │
│  │ PebbleDataBridge  │  │ PebbleBLEBridge        │  │
│  │ (HTTP JSON cache) │  │ (PebbleKit iOS SDK)    │  │
│  └────────┬─────────┘  └──────────┬─────────────┘  │
│           │                       │                 │
│  ┌────────▼─────────┐             │                 │
│  │ PebbleLocalAPI    │             │                 │
│  │ Server (:8080)    │             │                 │
│  └────────┬─────────┘             │                 │
└───────────┼───────────────────────┼─────────────────┘
            │                       │
     HTTP (127.0.0.1)        PebbleKit iOS IPC
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

## Setup Instructions

### 1. Install PebbleKit iOS SDK

**Option A: CocoaPods (recommended)**

```bash
cd /path/to/Trio
pod install
open Trio.xcworkspace  # use workspace, not .xcodeproj
```

This uses the `Podfile` already created in the repo root.

**Option B: Manual framework**

1. Download `PebbleKit.framework` from [github.com/pebble/pebble-ios-sdk](https://github.com/pebble/pebble-ios-sdk)
2. Drag into Xcode → Trio target → "Frameworks, Libraries, and Embedded Content"
3. Set "Embed & Sign"

### 2. Verify Background Modes (already configured)

In `Trio/Resources/Info.plist`, the following are already present:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
    ...
</array>
```

And:
```xml
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Bluetooth is used to communicate with insulin pump and continuous glucose monitor devices</string>
```

No additional Info.plist changes are needed.

### 3. Build and Test

After adding PebbleKit, the `#if canImport(PebbleKit)` guards in `PebbleBLEBridge.swift` automatically compile the full BLE implementation. Without the SDK, the bridge compiles as a no-op stub and the existing HTTP path continues to work.

## How It Works

### Data Flow (BLE Push)

1. Trio's `AppleWatchManager` calls `pebbleManager.sendState(watchState)`
2. `BasePebbleManager.sendState()` updates **both**:
   - `PebbleDataBridge` (HTTP cache for JS fallback)
   - `PebbleBLEBridge.sendState()` (BLE push)
3. `PebbleBLEBridge` converts `WatchState` → `NSDictionary` matching AppMessage keys
4. Calls `PBWatch.appMessagesPushUpdate(dict)` → message goes through Rebble → BLE → watch
5. Watch's `inbox_received()` processes it exactly like a JS-originated message

### JS Fallback Behavior

When BLE push is active, `/api/all` includes `"blePushActive": true`. PebbleKit JS detects this and:
- Slows polling from 30s to 5 min (backup only)
- Continues handling: weather, config page, commands from watch

When BLE disconnects, JS resumes 30s polling automatically.

### Key Matching

All keys are defined in three synchronized locations:

| Location | File | Purpose |
|----------|------|---------|
| C (watch) | `trio_types.h` → `AppMessageKey` enum | Watch-side key constants |
| JS | `index.js` → `K` object | PebbleKit JS key constants |
| Swift | `PebbleAppMessageKeys.swift` → `PebbleAppMessageKey` | PebbleKit iOS key constants |

**Critical**: these three must stay in sync. The values are sequential integers starting at 0.

## Conditional Compilation

`PebbleBLEBridge.swift` uses `#if canImport(PebbleKit)` to compile the full SDK integration only when the framework is available:

- **With PebbleKit**: Full BLE bridge active, data pushed on every `sendState`
- **Without PebbleKit**: `start()` logs a message and returns; `sendState()` is a no-op

This means the existing Trio build compiles and runs fine without any SDK changes — the BLE path activates only when PebbleKit is linked.

## Testing Checklist

### BLE Push
- [ ] Install PebbleKit SDK via CocoaPods
- [ ] Build Trio — verify no compilation errors
- [ ] Open Trio with Pebble watch paired to Rebble
- [ ] Verify Xcode console shows: `PebbleBLE: started — looking for Pebble watch`
- [ ] Verify: `PebbleBLE: connected to <watch name>`
- [ ] Verify: `PebbleBLE: pushed update to watch` on each CGM reading
- [ ] Background Trio → verify watch still receives updates
- [ ] Kill Rebble → verify `PebbleBLE: disconnected` → JS resumes polling

### HTTP Fallback
- [ ] Without PebbleKit SDK: verify HTTP server still works normally
- [ ] With PebbleKit + BLE active: verify `/api/all` shows `"blePushActive": true`
- [ ] With PebbleKit + BLE disconnected: verify `/api/all` shows `"blePushActive": false`
- [ ] Verify JS poll interval changes (30s ↔ 5min) based on BLE status

### Commands
- [ ] Send bolus command from watch over BLE → verify queued in `PebbleCommandManager`
- [ ] Send carb command from watch over BLE → verify queued
- [ ] Confirm command on iPhone → verify execution

## Files Modified/Added

### Trio (Swift)
- **NEW** `PebbleAppMessageKeys.swift` — Key enum matching C/JS constants
- **NEW** `PebbleBLEBridge.swift` — PebbleKit iOS wrapper with conditional compilation
- **MODIFIED** `PebbleManager.swift` — Dual-channel (HTTP + BLE) management
- **MODIFIED** `PebbleDataBridge.swift` — Added `blePushActive` flag in `/api/all`
- **NEW** `Podfile` — CocoaPods dependency for PebbleKit

### trio-pebble (Pebble watchface)
- **MODIFIED** `src/pkjs/index.js` — Dynamic poll interval based on BLE status

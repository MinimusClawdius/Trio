# Pebble / Rebble: JS-primary architecture (Trio + trio-pebble)

This document is the **source of truth** for how Trio and the **trio-pebble** watchface communicate. It supersedes informal notes that treated native iOS BLE as “primary.”

## Goals

- **Single mental model:** PebbleKit **JavaScript** (running inside the **Rebble** iPhone app) is the **supported** data path to the watch.
- **Future-proofing:** Most community and tooling effort targets **pkjs** + HTTP + `Pebble.sendAppMessage`, not custom native iOS PebbleKit glue.
- **Functional contract:** One **versioned HTTP snapshot** on loopback; watch commands use **HTTP POST** to Trio; optional native BLE is **explicitly opt-in** and **off by default**.

## End-to-end flow (default)

```
Trio iOS                          Rebble (iPhone)                    Pebble watch
────────                          ───────────────                    ────────────
WatchState → PebbleDataBridge      PebbleKit JS (pkjs/index.js)
          → PebbleLocalAPIServer       │ GET http://127.0.0.1:<port>/api/all
          on 127.0.0.1:<port>          │ parse JSON
                                       │ normalize → mg/dL, arrows, graph
                                       ▼
                                   Pebble.sendAppMessage(dict)
                                       │
                                       └──────────────────────────────► inbox_received (C)
```

**Bolus / carbs from the watch:** C → AppMessage → **same pkjs** `appmessage` handler → **HTTP POST** to Trio (`/api/bolus`, `/api/carbs`). Trio queues commands for on-phone confirmation. No native Trio BLE is required for that path.

## HTTP API (canonical snapshot)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/all` | **Canonical** combined snapshot (same body as v1 snapshot). |
| GET | `/api/pebble/v1/snapshot` | Alias for `/api/all` — use in new JS if you want an explicit versioned URL. |
| GET | `/health` | Liveness check. |
| GET | `/api/pebble/v1/ping` | **Minimal** JSON: `pebbleProtocolVersion`, `stateRevision`, `serverTime` — for PebbleKit JS reachability without parsing the full snapshot. |
| GET | `/api/cgm`, `/api/loop`, `/api/pump` | Subsets (legacy / debugging). |
| POST | `/api/bolus`, `/api/carbs`, `/api/command/confirm`, `/api/command/reject` | Watch-initiated actions and confirmations. |

### Versioned fields (top-level, alongside `cgm` / `loop` / `pump`)

- **`pebbleProtocolVersion`** — `1` today; bump when breaking JSON shape.
- **`stateRevision`** — Monotonic `UInt64` incremented each time Trio applies a new `WatchState` to `PebbleDataBridge`. Useful for logs and detecting “Trio stopped updating.”
- **`transportProfile`** — `"jsPrimary"` — documents intended use.
- **`nativeIosBlePushEnabled`** — Trio's user/service toggle for optional PebbleKit iOS push.
- **`blePushActive`** — `true` only when native push is **enabled** and PebbleKit reports a connected watch.

PebbleKit JS should **not** change poll cadence based on `blePushActive` (historically a 5× slowdown caused stale UI when native BLE was unreliable).

## Trio iOS settings (single source)

- **Settings → Services → Pebble / Rebble** is the only place to enable integration, HTTP port, optional native BLE, and pending watch requests.
- **Native iOS BLE data push** (`PebbleService.useNativeBLEPush`) defaults to **off**. Leave it off unless you explicitly want Trio's `PebbleBLEBridge` to mirror snapshots over PebbleKit iOS.

## Optional native iOS BLE (`PebbleBLEBridge`)

When enabled, Trio can push the **same logical payload** as pkjs (AppMessage key layout aligned with `PebbleAppMessageKeys` / `trio-pebble` `K` map). iOS background and Rebble lifecycle still apply — this path is **best-effort**, not guaranteed streaming.

## iOS limitations (honest expectations)

- Loopback HTTP is served by Trio’s process. If iOS **suspends** Trio, **Rebble cannot reach** `127.0.0.1` until Trio runs again (short background tasks around each accepted connection help only marginally).
- **Reliability tactics:** keep Trio in foreground when debugging; use Rebble’s logs; watch `stateRevision` in `/api/all`; prefer a **reasonable poll interval** in pkjs (trio-pebble uses ~20s by default).

## trio-pebble repository

- **`src/pkjs/index.js`** — transport and normalization; extend here for new fields or sources.
- **`src/trio_types.h` / C handlers** — UI and vibration; keep AppMessage keys in sync with `PebbleAppMessageKeys.swift` and pkjs `K`.

## Related docs

- [PEBBLE_BLE_INTEGRATION_GUIDE.md](./PEBBLE_BLE_INTEGRATION_GUIDE.md) — historical dual-channel diagram; native BLE is now **optional** and **off by default**.

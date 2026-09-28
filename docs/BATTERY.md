# Battery

Battery life is a primary requirement, not a tuning step. This document defines the modes,
the algorithm, and the benchmark every release must report.

## Modes

| Mode | Stationary | Walking | Driving | Accuracy |
|---|---|---|---|---|
| Maximum accuracy | every 1 min | desired interval | desired interval | GPS/high |
| **Balanced** (default) | 10–30 min, significant-change | 1–5 min, 50 m filter | 15–60 s, 100 m filter | balanced (Wi-Fi/cell + GPS when moving) |
| Battery saver | significant-change only | 5–15 min, 250 m | 1–5 min, 500 m | low power |
| Custom | min interval · min distance · accuracy · retention, chosen by the user | | | |

"Every 15 s" is always a **desired** interval. The app records actual intervals and shows
*Requested vs Actual average*.

## Algorithm

```
OS location / activity callback
        │
   moving?  ──no──▶ low-power monitoring (significant change / geofence exit / low-accuracy request)
        │yes
   normal tracking at the mode's interval + distance filter
        │
   should send?  (interval elapsed AND (moved ≥ filter OR accuracy improved OR heartbeat due))
        │yes
   store locally (encrypted) ─▶ encrypt event ─▶ queue
        │
   socket open? ──yes──▶ send batch     no ──▶ keep queued; flush on reconnect / next wake
```

Principles: let the OS schedule (FusedLocationProvider requests with `setMinUpdateDistanceMeters`
and `setMaxUpdateDelayMillis` for batching; iOS `distanceFilter`, `desiredAccuracy`,
`activityType`, `pausesLocationUpdatesAutomatically`), never poll GPS on our own timer, no
wake-locks, one persistent connection only while actively sharing, P2P only while someone is
viewing.

## Benchmark protocol

Devices: at least one mid-range Android (Pixel-class) and one iPhone, fully charged, same
brightness, screen off unless stated, no other apps, 2-hour runs, repeated twice.

Matrix: intervals **15 s, 30 s, 1 min, 5 min, 15 min, battery saver, stationary** ×
conditions **stationary, walking, driving, screen off, Wi-Fi, 4G/5G, poor network, offline**.

Record per run:

| Metric | Android source | iOS source |
|---|---|---|
| Battery %/hour | `BatteryManager`, Battery Historian | Xcode Energy Log / MetricKit |
| GPS on-time, location requests | Battery Historian | MetricKit `MXLocationActivityMetric` |
| CPU time | `dumpsys batterystats` | MetricKit CPU metrics |
| Network bytes | `TrafficStats` per-UID | MetricKit network metrics |
| Location accuracy (mean/p90) | from the app's own log | same |
| Requested vs actual interval | app log | app log |

Results go in `docs/benchmarks/<version>.md`. A release that regresses Balanced mode by more
than 10 %/h must explain why.

## Budget targets (to be validated)
Balanced, walking, screen off: ≤ 2 %/h. Stationary: ≤ 0.5 %/h. Battery saver: ≤ 1 %/h.

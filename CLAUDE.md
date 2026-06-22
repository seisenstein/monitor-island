# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Monitor Island is a single-binary macOS menu-bar app (Apple Silicon, arm64 only, macOS 14+) that
shows a floating, draggable "island" of live chip metrics and which AI workloads are running. All
metrics are read **sudoless** — no password prompt, never `powermetrics`, never `sudo`.

## Commands

```bash
swift build                       # debug build
swift build -c release            # release build (what packaging uses)
./scripts/package_app.sh          # build + assemble + ad-hoc sign dist/MonitorIsland.app
./scripts/build_dmg.sh            # package_app + wrap into dist/MonitorIsland.dmg (run package_app.sh first)
```

There is **no test target**. The binary is its own verification harness — these text modes prove the
metrics are real and are the primary way to check changes to the sampling layer:

```bash
swift run MonitorIsland --dump          # sample once, print one JSON Snapshot with every metric
swift run MonitorIsland --sensors       # enumerate every HID temp sensor + IOReport channel (M5/new-chip verification)
swift run MonitorIsland --shot out.png  # render the live expanded island UI to a PNG (no Screen Recording perm needed)
swift run MonitorIsland                 # launch the floating island GUI (default, no flag)
```

Cross-check `--dump` against `macmon pipe -s 1 -i 200`. When porting to a new chip, `--sensors` is the
tool: it dumps the raw sensor/channel map so the cluster mapping can be verified before trusting it.

## Architecture

**Two SwiftPM targets** (`Package.swift`):
- `CIOReport` — a tiny C target (`Sources/CIOReport/`) that `extern`-declares the private IOReport and
  IOHIDEventSystemClient symbols (power + temperature). These have no `.tbd` stub in the SDK, so they
  are linked with `-undefined dynamic_lookup` and resolved at runtime. **This is why the app cannot
  ship on the Mac App Store** and is distributed as an ad-hoc-signed DMG. `shim.c` wraps the IOReport
  subscribe/sample/delta dance in `mi_*` helpers so Swift never juggles CF pointer ownership.
- `MonitorIsland` — the executable (all Swift in `Sources/MonitorIsland/`).

**The data pipeline** (one direction, one snapshot per tick):

```
per-metric samplers ──► Sampler.tick() ──► Snapshot ──► IslandModel ──► Smoother ──► IslandView
   (one .swift each)     (holds prev state,   (Codable,    (@Published,   (60 Hz lerp   (SwiftUI)
                          computes deltas)    --dump out)   bg timer)      to targets)
```

- **`Sampler`** is the single owner of all per-metric samplers and the only place that holds previous
  state. CPU, power, and network are **delta-based**: `Sampler.prime()` must be called once before the
  first real `tick()` so the deltas have a baseline (GUI does this on a background queue at start;
  `--dump`/`--shot` `usleep` ~400ms after priming to let counters accumulate). One tick → one `Snapshot`.
- **`Snapshot`** (`Snapshot.swift`) is the single `Codable` struct the whole app passes around. It is
  both what the UI reads and what `--dump` serializes — keep them in sync; a new metric means a new field
  here. `round1`/`round2` helpers live here.
- **`IslandModel`** runs the `Sampler` on a background `DispatchQueue` via a `DispatchSourceTimer` at the
  refresh interval (1/2/5 s), then hops to `@MainActor` to publish `snap` and feed `Smoother` targets.
- **`Smoother`** is a separate 60 Hz `@MainActor` timer that lerps displayed values toward targets
  (`displayed += (target - displayed) * 0.18`) so numbers glide. The view reads the **smoothed** values,
  not the raw snapshot. It also owns the GPU sparkline history ring and temp C→F conversion. `--shot`
  drives `step()`/`snapToTargets()` manually to settle a frame before capture.

**Per-metric samplers** (each maps to a README table row documenting its sudoless API):
`CPUMem.swift` (host_processor_info + perflevel sysctls + vm_statistics64), `GPU.swift` (IOAccelerator
PerformanceStatistics), `Temperature.swift` (IOHID thermal sensors + `ThermalMap` cluster mapping),
`Power.swift` (IOReport Energy Model), `Network.swift` (getifaddrs deltas), `Workloads.swift` (process
detection), `SysInfo.swift` (chip/perflevel identity), `LocalModel.swift` (LM Studio/llama.cpp `/v1/models`).

**UI/glue:** `main.swift` (arg parsing + GUI bootstrap, `LSUIElement` accessory app), `AppDelegate.swift`
(borderless floating window, menu-bar `MI` item, "snap under camera" logic), `IslandView.swift` (the
SwiftUI island: compact pill ↔ expanded card, ring gauges, sparkline), `Theme.swift`, `FontLoader.swift`,
`Shot.swift`.

## Conventions and constraints

- **Sudoless or it doesn't ship.** Every metric must come from an API that needs no elevated privileges.
  Do not add `powermetrics`, `sudo`, or anything that triggers a password/permission prompt.
- **Apple Silicon only.** The sensor APIs don't exist on Intel; don't add Intel fallbacks.
- **Honesty about accuracy is a feature, not a bug.** GPU% is system-wide (no per-process attribution);
  temperature is a best-effort die average flagged `tempBestEffort` when the cluster mapping isn't
  verified; ANE is power-only (occupancy isn't exposed). Preserve these honest labels — don't fabricate
  precise-looking numbers. New chips may need `--sensors` to extend `ThermalMap`/perflevel handling.
- **Window rendering is deliberate.** The window is constructed borderless from creation (not by mutating
  a titled window's `styleMask`, which leaves a frame artifact) and the root view has no transparent
  padding so the AppKit shadow hugs the rounded glass. See the comment in `AppDelegate.buildWindow()`
  before touching window setup.
- **`Theme.swift` is a strict 3-color palette** (sky / snow / slate); the many color aliases all collapse
  into those three. Add real new colors only with intent.
- **Versioning:** bump `VERSION` in `scripts/package_app.sh` and the release links in `README.md` together.

## Untracked working files

`_*.md` scratch notes, `0*-*.sh` setup scripts, `.build/`, `dist/`, `models/`, and `*.gguf` are
git-ignored (see `.gitignore`). `_followups.md` is the one tracked working note.

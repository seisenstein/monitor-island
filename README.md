# Monitor Island

A Promptable Technologies open-source project — https://promptable.us

A small, draggable, always-on-top "island" panel for Apple Silicon Macs that shows live
chip-level activity and which AI workloads are running (a local model, Claude Code, the Claude
desktop app, Codex). It is built to keep a watchful eye on what AI work is doing to the
silicon: unified-memory headroom and GPU load while a local model runs, and CPU, process
count, and network load while agent tools run.

All metrics are read sudoless (no password prompt) through the same native and private
frameworks that macmon, mactop, and Stats use.

## Download

Get the latest DMG from the GitHub release:

- https://github.com/Promptable-Technologies/monitor-island/releases/latest
- Direct: https://github.com/Promptable-Technologies/monitor-island/releases/download/v1.2.0/MonitorIsland.dmg

## Requirements: Apple Silicon only

Monitor Island is arm64 and Apple Silicon only (M1 through M5 and newer, including the M5
"Super" cores). The sensor APIs it uses do not exist on Intel Macs, so the recipient must
also be on Apple Silicon. Runs on **macOS Sonoma 14.7.1 through macOS Tahoe 26**. Intel Macs
are not supported and never will be.

## One-time install (it is not notarized)

This app is ad-hoc signed, not notarized with a paid Apple Developer ID, so macOS shows a
Gatekeeper warning on first launch. That warning exists only because the app is not notarized.
It is safe and open source. A fully frictionless install would require a paid Apple Developer
ID, which this project intentionally does not use.

1. Open `MonitorIsland.dmg`, drag `Monitor Island` to Applications.
2. Double-click the included `Install.command`. It strips the quarantine flag with
   `xattr -dr com.apple.quarantine "/Applications/MonitorIsland.app"` and launches the app.
   This is the reliable path on current macOS.
3. Fallback: on macOS Sequoia and newer the older Control-click then Open shortcut does not
   always work in one step. If the first launch is blocked, open System Settings, Privacy and
   Security, and click Open Anyway. The `Install.command` (or running
   `xattr -dr com.apple.quarantine /Applications/MonitorIsland.app` in Terminal) avoids that.

Look for the `MI` item in the menu bar and the floating island near the top of the screen.
Click the island to expand or collapse it. Drag it anywhere. The menu has Show/Hide, Snap under
camera (centers it just below the notch/camera and keeps it centered as it expands; dragging it
unsnaps), the refresh interval (1, 2, 5 seconds), a local-model overlay toggle, and Quit.

## Features

- Live GPU utilization, unified-memory pressure, CPU (E+P core split), power in watts, die temperature
- Network up/down rate
- Workload detection: Claude Code, Claude desktop, Codex, local models (LM Studio / llama.cpp)
- Real-time SSD write tracking with a best-effort wear estimate and per-process attribution (Claude Code, Codex) — the wear % is a derived best-effort estimate (Apple publishes no TBW), labeled "~/est"
- Draggable, always-on-top pill that collapses to a compact view
- Snap-under-camera mode for notched displays
- Liquid Glass background on macOS Tahoe 26; frosted `.ultraThinMaterial` on Sonoma/Sequoia

## Which sudoless API backs each metric

| Metric | API | Private? |
|--------|-----|----------|
| CPU usage, per-core and per-core-type split | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` plus `hw.perflevelN.*` sysctls | No |
| Memory used / total / headroom, swap | `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage` | No |
| Swap used %, memory-pressure level | `vm.swapusage` (exact swap) + `kern.memorystatus_vm_pressure_level` (exact 1/2/4) + `host_statistics64` page counts (continuous proxy) | No |
| GPU utilization, in-use GPU memory | IOKit `IOAccelerator` -> `PerformanceStatistics` -> `Device Utilization %` | No |
| CPU / GPU / ANE / DRAM power (watts) | IOReport "Energy Model" group | Yes (IOReport) |
| Temperature (die sensors) | IOHIDEventSystemClient thermal sensors (PrimaryUsagePage 0xff00, usage 5) | Yes (IOHID) |
| Network up/down rate | `getifaddrs` per-interface byte counters, delta per tick | No |
| SSD writes, wear estimate | IOKit `IOBlockStorageDriver` -> `Statistics` -> `Bytes Written`, lifetime accumulation log | No |
| Workload detection (GUI) | `NSWorkspace.runningApplications` | No |
| Workload detection (CLI) | `proc_listpids` + `proc_pidpath` + `KERN_PROCARGS2` + `proc_pid_rusage` | No |
| Local model name | LM Studio / llama.cpp OpenAI-compatible `/v1/models`, or the `-m` / `-hf` arg | No |

A single sampler holds the previous sample and computes all deltas (CPU, power, network, SSD writes)
once per tick, then publishes one snapshot the UI reads.

### Private frameworks and the no-App-Store consequence

Power (IOReport) and temperature (IOHIDEventSystemClient) come from private Apple frameworks.
These have no `.tbd` stub in the SDK, so they are declared extern in an isolated C target
(`CIOReport`) and linked with `-undefined dynamic_lookup` so the symbols resolve at runtime.
Using private frameworks means this app cannot ship on the Mac App Store, which is why it is
distributed as a DMG. That also means no App Store sandbox, which is fine and expected here.

### Notes on accuracy, honestly stated

- GPU utilization is system-wide. macOS does not expose reliable per-process GPU utilization
  without Instruments-level tooling. When a local model is detected it is almost certainly the
  driver of the GPU reading, but this is not exact per-process attribution.
- Temperature on M5: the HID layer on this M5 Pro exposes only unlabeled `PMU tdie1..14` die
  sensors (no CPU/GPU labels; macmon reads SMC instead). Monitor Island reports a best-effort
  die average rather than guessing a fake CPU-vs-GPU split, and marks it best-effort. The
  `--sensors` mode prints the full discovered sensor map so the mapping can be verified per chip.
- ANE occupancy is not exposed by Apple. Any ANE figure is derived from ANE power and labeled
  accordingly, not a fabricated percentage.
- The SWAP gauge is a hybrid: its centered number is exact swap-used % (`vm.swapusage`, ground
  truth — 0 until the machine actually pages to SSD), while its ring fill is a continuous
  "distance to swap" proxy and its color escalates sky -> amber -> red. The proxy *number* is
  best-effort, but it is banded by the kernel's exact `kern.memorystatus_vm_pressure_level`
  (normal/warning/critical — the OS's own swap trigger), so the warning and critical zones are
  ground truth even though the smooth fill inside a band is an estimate. This lets you watch how
  close you are to swapping long before any page is written.
- SSD wear % is best-effort. Apple does not publish a rated TBW for its SSD controllers. The
  estimate uses lifetime-written bytes vs. a conservative reference figure and is labeled "~/est"
  in the UI to flag the approximation. Per-process SSD write attribution (Claude Code, Codex) is
  accurate to the tick granularity of `proc_pid_rusage`.

## Self-test and verification modes

The same binary has text modes that prove the values are real:

- `MonitorIsland --dump` samples once and prints one JSON object with every metric. Cross-check
  it against `macmon pipe -s 1 -i 200`.
- `MonitorIsland --sensors` enumerates every discovered HID temperature sensor and every
  IOReport channel with names and current values. This is the M5 verification tool.
- `MonitorIsland --shot island.png` renders the live island UI to a PNG.

## Building from source

Requires the Xcode command line tools (no full Xcode needed).

```
swift build -c release        # build
./scripts/package_app.sh      # assemble + ad-hoc sign MonitorIsland.app
./scripts/build_dmg.sh        # build + verify MonitorIsland.dmg
```

Apple Silicon only. Do not use `powermetrics`; all live metrics are sudoless.

## License

MIT License — © 2026 Promptable Technologies. See [LICENSE](LICENSE).

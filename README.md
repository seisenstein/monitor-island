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
- Clicking a Claude Code / Codex session focuses its hosting terminal tab or pane when the terminal exposes a safe sudoless control surface
- Real-time SSD write tracking (live rate + cumulative host bytes observed since first launch) with per-process attribution (Claude Code, Codex). No wear % is shown: true NAND wear (NVMe SMART) is not readable without admin on Apple Silicon, so any wear figure would be fabricated
- Draggable, always-on-top pill that collapses to a compact view
- Snap-under-camera mode for notched displays
- Liquid Glass background on macOS Tahoe 26; frosted `.ultraThinMaterial` on Sonoma/Sequoia

### Click-to-focus support

Session rows use the clicked process's parent chain and controlling TTY to focus the host app without sudo.

| App | Support level | How it works |
|-----|---------------|--------------|
| iTerm2 | Exact pane | Matches the CLI process TTY to an iTerm session `tty`, then selects the session, tab, and window with AppleScript. |
| Terminal.app | Exact tab | Matches the CLI process TTY to a Terminal tab `tty`, then selects the tab and frontmost window with AppleScript. |
| kitty | Exact pane when remote control is already enabled | Uses `KITTY_LISTEN_ON` plus `KITTY_WINDOW_ID`/PID and `kitten @ focus-window`. If kitty has no remote-control socket, it falls back. |
| Ghostty | Best-effort pane | Uses Ghostty AppleScript only when the clicked process cwd uniquely identifies one terminal. Duplicate cwd matches fall back to app activation. |
| Claude Desktop Cowork | Window-level only | Claude has no public tab-selection AppleScript surface; Monitor Island raises a matching Claude window by title through Accessibility only if permission is already granted. |
| Warp and other terminals | App activation fallback | Current public Warp URI actions open new windows/tabs and do not focus an existing pane by pid or tty. |

The first AppleScript focus for Terminal, iTerm2, or Ghostty may trigger the standard macOS Automation prompt. Denying it simply falls back to activating the owning app.

## Which sudoless API backs each metric

| Metric | API | Private? |
|--------|-----|----------|
| CPU usage, per-core and per-core-type split | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` plus `hw.perflevelN.*` sysctls | No |
| Memory used / total / headroom, swap | `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`, `vm.swapusage` | No |
| Swap in use (GB), memory-pressure level | `vm.swapusage` (exact swap used/total) + `kern.memorystatus_vm_pressure_level` (exact 1/2/4, drives the ring fill) | No |
| GPU utilization, in-use GPU memory | IOKit `IOAccelerator` -> `PerformanceStatistics` -> `Device Utilization %` | No |
| CPU / GPU / ANE / DRAM power (watts) | IOReport "Energy Model" group | Yes (IOReport) |
| Temperature (die sensors) | IOHIDEventSystemClient thermal sensors (PrimaryUsagePage 0xff00, usage 5) | Yes (IOHID) |
| Network up/down rate | `getifaddrs` per-interface byte counters, delta per tick | No |
| SSD write rate + cumulative host writes | IOKit `IOBlockStorageDriver` -> `Statistics` -> `Bytes (Write)`, scoped to the internal `IONVMeController`, accumulated since first launch (persisted JSONL survives reboots) | No |
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
- The SWAP gauge is honest end to end: its centered number is the swap **actually in use, in GB**
  (`vm.swapusage`, ground truth — `0` until the machine actually pages to SSD), shown in GB rather
  than as a "% of RAM" (RAM is a meaningless denominator for a dynamically-grown swap file, and
  scaling by installed RAM made the same swap read differently on an 8 GB vs 16 GB Mac). The ring
  **fill** is driven solely by the kernel's exact `kern.memorystatus_vm_pressure_level`
  (normal -> empty, warning, critical) and the color escalates sky -> amber -> red with it. So the
  ring is calm when the OS reports no pressure and fills only as the OS itself escalates — it never
  shows phantom pressure from ordinary RAM usage.
- No SSD wear % is shown. Apple's internal SSD does not expose its NVMe SMART health log
  (Percentage Used / Data Units Written) without admin rights, so a true wear figure is impossible
  under the sudoless rule and any estimate (host bytes ÷ a guessed TBW) would be fabricated.
  Instead the SSD panel shows the live **write rate** and the **cumulative host bytes Monitor
  Island has observed** since it first launched (labeled with that start date) — a verifiable lower
  bound, explicitly *not* the drive's lifetime total. The counter is scoped to the internal NVMe
  controller so mounted disk images and external drives don't inflate it. Per-process SSD write
  attribution (Claude Code, Codex) is accurate to the tick granularity of `proc_pid_rusage`.

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

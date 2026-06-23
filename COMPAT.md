# Monitor Island — Compatibility Audit

**Target range:** Apple Silicon M1 through M5 and newer, macOS Sonoma 14.7.1 through macOS Tahoe 26.

## Verdict

**PASS** — no unguarded macOS 15+ or macOS 26+ API usage was found. Every version-gated call has
a correct fallback branch covering macOS 14+. The one macOS 26 API (`glassEffect`) is properly
guarded with an `if #available(macOS 26.0, *)` block that falls back to `.ultraThinMaterial`.

---

## Availability gates found

### `grep -rnE '#available|@available|if #available' Sources/`

| File | Line | Gate | Notes |
|------|------|------|-------|
| `Sources/MonitorIsland/Disk.swift` | 222 | `if #available(macOS 10.15.4, *)` | `FileHandle.seekToEnd()` throwing variant; fallback to `seekToEndOfFile()` on 218 else-branch. OK. |
| `Sources/MonitorIsland/Disk.swift` | 233 | `if #available(macOS 10.15.4, *)` | `FileHandle.seek(toOffset:)` throwing variant; fallback present. OK. |
| `Sources/MonitorIsland/Disk.swift` | 240 | `if #available(macOS 10.15.4, *)` | `FileHandle.readToEnd()` throwing variant; fallback `readDataToEndOfFile()` present. OK. |
| `Sources/MonitorIsland/Disk.swift` | 264 | `if #available(macOS 10.15.4, *)` | `FileHandle.seekToEnd()` + `write(contentsOf:)` throwing variants; fallback present. OK. |
| `Sources/MonitorIsland/IslandView.swift` | 299 | `if #available(macOS 26.0, *)` | `glassEffect(in:)` — macOS 26 Liquid Glass. Fallback at line 304: `.ultraThinMaterial`. **Correctly guarded.** |
| `Sources/MonitorIsland/AppDelegate.swift` | 280 | `if #available(macOS 12.0, *)` | `NSScreen.safeAreaInsets` for notch detection. Falls back to `NSScreen.main`. OK. |

All gates have else-branches that work on macOS 14.0+.

---

## APIs checked for unguarded use (macOS 15+/26+ only)

| API | Status |
|-----|--------|
| `glassEffect` | Guarded behind `if #available(macOS 26.0, *)` in `IslandView.swift:299`. OK. |
| `scrollEdgeEffect` | Not used. |
| `MeshGradient` | Not used. |
| `TextRenderer` | Not used. |
| `onGeometryChange` | Not used. |
| `Tab(` (new TabView API) | Not used. |
| `@Animatable` | Not used. |
| `windowResizeBehavior` | Not used. |
| `symbolEffect` variants (macOS 15+) | Not used. |

---

## APIs confirmed fine on macOS 14.0+

- `NSColorSampler` — available since macOS 10.15. No guard required. OK.
- `IOKit` / `IOAccelerator` / IOReport private symbols — no OS version restriction for the
  dynamic-lookup pattern used (`-undefined dynamic_lookup`). Available on all macOS on arm64. OK.
- `proc_pid_rusage` / `proc_listpids` / `KERN_PROCARGS2` — BSD layer, available on all relevant macOS. OK.
- `getifaddrs` — POSIX, available everywhere. OK.
- `vm_statistics64` / `host_processor_info` / `host_statistics64` — Mach layer, no version restriction. OK.
- `vm.swapusage` / `kern.memorystatus_vm_pressure_level` — sysctl keys available on macOS 14+. OK.
- `NSScreen.safeAreaInsets` — guarded to macOS 12.0+ with `NSScreen.main` fallback. OK on 14+.

---

## arm64-only constraint

Intentional. The IOHID thermal sensor APIs and IOReport power channels do not exist on Intel Macs.
`Package.swift` declares `platforms: [.macOS(.v14)]` which enforces the macOS 14 floor at compile
time. No Intel fallbacks exist or are desired.

---

## Concerns for the orchestrator

None. All availability guards are present and correct.

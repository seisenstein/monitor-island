import Foundation
import Darwin
import AppKit

struct ProcInfo {
    var pid: Int32
    var path: String
    var name: String      // basename
    var args: String      // full command line
    var residentMB: Double
}

// Workload detection (sudoless): GUI apps via NSWorkspace, CLI processes via
// libproc + KERN_PROCARGS2.
final class WorkloadSampler {

    struct Result {
        var entries: [WorkloadEntry]
        var localModelName: String?
        var localModelMemoryMB: Double?
    }

    private func allPids() -> [Int32] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        let cap = Int(count) / MemoryLayout<Int32>.size + 64
        var buf = [Int32](repeating: 0, count: cap)
        let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buf, Int32(cap * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        let actual = Int(n) / MemoryLayout<Int32>.size
        return Array(buf.prefix(actual)).filter { $0 > 0 }
    }

    private func path(for pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        return r > 0 ? String(cString: buf) : ""
    }

    private func args(for pid: Int32) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 { return "" }
        var buf = [CChar](repeating: 0, count: size)
        if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 { return "" }
        // Layout: int argc; exec_path\0; \0 padding; argv[0]\0 argv[1]\0 ...
        return buf.withUnsafeBufferPointer { ptr -> String in
            guard ptr.count > 4 else { return "" }
            let base = UnsafeRawPointer(ptr.baseAddress!)
            var argc: Int32 = 0
            memcpy(&argc, base, 4)
            var offset = 4
            // skip exec path
            while offset < size && buf[offset] != 0 { offset += 1 }
            // skip nulls
            while offset < size && buf[offset] == 0 { offset += 1 }
            var parts: [String] = []
            var collected = 0
            while offset < size && collected < Int(argc) {
                let start = offset
                while offset < size && buf[offset] != 0 { offset += 1 }
                if offset > start {
                    let s = String(decoding: (start..<offset).map { UInt8(bitPattern: buf[$0]) }, as: UTF8.self)
                    parts.append(s)
                }
                offset += 1
                collected += 1
            }
            return parts.joined(separator: " ")
        }
    }

    private func residentMB(for pid: Int32) -> Double {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
            }
        }
        guard r == 0 else { return 0 }
        return Double(info.ri_resident_size) / (1024.0 * 1024.0)
    }

    // Per-process cumulative disk bytes written + process start time, from the SAME
    // rusage_info_v4 used for memory (sudoless for same-user processes, zero extra syscall).
    // ri_diskio_byteswritten is block-layer host bytes (the correct wear field), NOT ri_logical_writes.
    private func diskWritten(for pid: Int32) -> (written: UInt64, startAbs: UInt64) {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rp in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rp)
            }
        }
        guard r == 0 else { return (0, 0) }
        return (info.ri_diskio_byteswritten, info.ri_proc_start_abstime)
    }

    // Collapse matched processes (a tool's worker/helper tree) into logical sessions: one entry
    // per "leader" (a matched pid whose parent is NOT itself matched). Session memory sums the
    // tree; the representative pid prefers a member with a real project working directory, so the
    // label reads as the project and a click can walk up to the owning terminal / app.
    private func sessions(from matches: [(pid: Int32, mem: Double)]) -> [(pid: Int32, mem: Double)] {
        guard !matches.isEmpty else { return [] }
        let set = Set(matches.map { $0.pid })
        func leaderOf(_ pid: Int32) -> Int32 {
            var cur = pid, hops = 0
            while hops < 30 {
                let pp = parentPID(of: cur)
                if pp > 1, set.contains(pp) { cur = pp; hops += 1 } else { break }
            }
            return cur
        }
        var members: [Int32: [Int32]] = [:]
        var memByLeader: [Int32: Double] = [:]
        for m in matches {
            let L = leaderOf(m.pid)
            members[L, default: []].append(m.pid)
            memByLeader[L, default: 0] += m.mem
        }
        return members.map { (leader, pids) in
            let rep = pids.first(where: { p in
                if let c = cwd(for: p) { return c != NSHomeDirectory() && c != "/" }
                return false
            }) ?? leader
            return (pid: rep, mem: memByLeader[leader] ?? 0)
        }
    }

    // Current working directory of a pid (sudoless, own processes), used to label
    // an individual session (e.g. a Claude Code session by its project folder).
    private func cwd(for pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let r = proc_pidinfo(pid, 9 /* PROC_PIDVNODEPATHINFO */, 0, &vpi, sz)
        guard r > 0 else { return nil }
        let path = withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    private func instanceLabel(pid: Int32) -> String {
        let base: String
        if let c = cwd(for: pid) {
            base = (c == NSHomeDirectory()) ? "~" : (c as NSString).lastPathComponent
        } else {
            base = "session"
        }
        return "\(base) \u{00b7} \(pid)"   // e.g. "files \u{00b7} 45049"
    }

    private func scanProcs() -> [ProcInfo] {
        var out: [ProcInfo] = []
        for pid in allPids() {
            let p = path(for: pid)
            if p.isEmpty { continue }
            let name = (p as NSString).lastPathComponent
            let a = args(for: pid)
            out.append(ProcInfo(pid: pid, path: p, name: name, args: a, residentMB: residentMB(for: pid)))
        }
        return out
    }

    // Per-process disk-write attribution state (held across ticks).
    private var diskBaseline: [Int32: (written: UInt64, startAbs: UInt64)] = [:]  // last seen per pid
    private var sessionWritten: [String: UInt64] = [:]   // cumulative delta per workload label
    private var instWritten: [Int32: UInt64] = [:]       // cumulative delta per pid (for drill-down)

    func sample() -> Result {
        let procs = scanProcs()
        var groups: [String: (count: Int, mem: Double, detail: String?, instances: [WorkloadInstance])] = [:]

        func add(_ label: String, pid: Int32, mem: Double, detail: String? = nil, instLabel: String? = nil) {
            var g = groups[label] ?? (0, 0, nil, [])
            g.count += 1
            g.mem += mem
            if g.detail == nil { g.detail = detail }
            g.instances.append(WorkloadInstance(pid: pid, memoryMB: round2(mem),
                                                label: instLabel ?? instanceLabel(pid: pid)))
            groups[label] = g
        }

        var localModelName: String? = nil
        var localModelMem: Double? = nil
        // Matched Claude Code / Codex processes; collapsed into logical sessions after the scan.
        var claudeMatches: [(pid: Int32, mem: Double)] = []
        var codexMatches:  [(pid: Int32, mem: Double)] = []

        for p in procs {
            let nameL = p.name.lowercased()
            let argsL = p.args.lowercased()
            let hay = (p.path + " " + p.args).lowercased()
            let isAppBundle = p.path.contains(".app/Contents")

            // Claude Code CLI. The distinctive package substrings ("claude-code",
            // "anthropic-ai/claude") identify the CLI even when it ships INSIDE a .app bundle
            // — current Claude Code is .../claude-code/<ver>/claude.app/Contents/MacOS/claude,
            // so gating those behind !isAppBundle (as the desktop-app exclusion does) would
            // wrongly hide the CLI. Match those substrings regardless of bundling; keep the
            // looser basename/node heuristics gated by !isAppBundle so the Claude *desktop*
            // app (/Applications/Claude.app, no "claude-code" in its path) is still excluded.
            let isClaudeCodeCLI =
                hay.contains("claude-code") || hay.contains("anthropic-ai/claude") ||
                (!isAppBundle && (nameL == "claude" || nameL.hasPrefix("claude.") ||
                                  (nameL == "node" && hay.contains("/claude"))))
            if isClaudeCodeCLI {
                let cur = diskWritten(for: p.pid)
                if let base = diskBaseline[p.pid], base.startAbs == cur.startAbs {
                    // Same process (start time unchanged): count only the forward delta. A changed
                    // startAbs means the pid was reused by a different process → reset, don't count.
                    let delta = cur.written >= base.written ? cur.written - base.written : 0
                    sessionWritten["Claude Code", default: 0] += delta
                    instWritten[p.pid] = (instWritten[p.pid] ?? 0) + delta
                }
                diskBaseline[p.pid] = cur
                claudeMatches.append((pid: p.pid, mem: p.residentMB))
                continue
            }
            // Codex CLI. Current Codex launches a node wrapper that spawns a native
            // "codex" binary; counting both would double the instance count, so we
            // match only the native binary basename (one per logical instance).
            if !isAppBundle && (nameL == "codex" || nameL.hasPrefix("codex.")) {
                let cur = diskWritten(for: p.pid)
                if let base = diskBaseline[p.pid], base.startAbs == cur.startAbs {
                    // Same process (start time unchanged): count only the forward delta. A changed
                    // startAbs means the pid was reused by a different process → reset, don't count.
                    let delta = cur.written >= base.written ? cur.written - base.written : 0
                    sessionWritten["Codex", default: 0] += delta
                    instWritten[p.pid] = (instWritten[p.pid] ?? 0) + delta
                }
                diskBaseline[p.pid] = cur
                codexMatches.append((pid: p.pid, mem: p.residentMB))
                continue
            }
            // llama.cpp local model server
            if nameL == "llama-server" || nameL == "llama-cli" || nameL.contains("llama-server") {
                var detail: String? = nil
                func argValue(_ flag: String) -> String? {
                    guard let r = p.args.range(of: flag + " ") else { return nil }
                    return p.args[r.upperBound...].split(separator: " ").first.map(String.init)
                }
                if let modelPath = argValue("-m") ?? argValue("--model") {
                    detail = LocalModel.cleanName(modelPath)
                } else if let hf = argValue("-hf") ?? argValue("--hf-repo") {
                    detail = LocalModel.cleanName(hf)
                }
                if let d = detail {
                    localModelName = d
                    localModelMem = (localModelMem ?? 0) + p.residentMB
                }
                add("llama-server", pid: p.pid, mem: p.residentMB, detail: detail,
                    instLabel: detail ?? instanceLabel(pid: p.pid))
                continue
            }
            // LM Studio server helper (CLI side)
            if argsL.contains("lm-studio") || argsL.contains("lmstudio") || nameL.contains("lms") {
                if !p.path.contains(".app/Contents/MacOS/LM Studio") {
                    add("LM Studio (server)", pid: p.pid, mem: p.residentMB)
                }
                continue
            }
        }

        // Collapse Claude Code / Codex worker trees into logical sessions (one entry per leader).
        for sess in sessions(from: claudeMatches) { add("Claude Code", pid: sess.pid, mem: sess.mem) }
        for sess in sessions(from: codexMatches)  { add("Codex", pid: sess.pid, mem: sess.mem) }

        // GUI apps via NSWorkspace.
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName else { continue }
            let pid = app.processIdentifier
            let mem = residentMB(for: pid)
            if name.contains("LM Studio") {
                add("LM Studio", pid: pid, mem: mem, instLabel: name)
            } else if name.contains("Claude") && !name.contains("Claude Code") {
                add("Claude desktop", pid: pid, mem: mem, instLabel: name)
            } else if name.contains("Codex") {
                add("Codex desktop", pid: pid, mem: mem, instLabel: name)
            }
        }

        // Local model name via LM Studio OpenAI-compatible API (short timeout).
        if let lm = LocalModel.lmStudioModelName() {
            localModelName = lm
        }

        // Prune stale pid entries to prevent unbounded map growth; sessionWritten (by label)
        // is intentionally kept — the cumulative per-label total must survive pid churn.
        let livePids = Set(procs.map { $0.pid })
        diskBaseline = diskBaseline.filter { livePids.contains($0.key) }
        instWritten  = instWritten.filter  { livePids.contains($0.key) }

        var entries: [WorkloadEntry] = []
        for (label, g) in groups.sorted(by: { $0.key < $1.key }) {
            let insts = g.instances.sorted { $0.memoryMB > $1.memoryMB }.map { inst -> WorkloadInstance in
                var i = inst
                i.diskWrittenSessionMB = round2(Double(instWritten[inst.pid] ?? 0) / (1024 * 1024))
                return i
            }
            var entry = WorkloadEntry(label: label, count: g.count, cpuPercent: 0,
                                      memoryMB: round2(g.mem), detail: g.detail, instances: insts)
            entry.diskWrittenSessionMB = round2(Double(sessionWritten[label] ?? 0) / (1024 * 1024))
            entries.append(entry)
        }
        return Result(entries: entries, localModelName: localModelName, localModelMemoryMB: localModelMem.map(round1))
    }

    // Cumulative session bytes written attributed to a workload label (e.g. "Claude Code", "Codex").
    func sessionWrittenBytes(forLabel label: String) -> UInt64 { sessionWritten[label] ?? 0 }
}

// Parent PID via libproc (sudoless, same-user). Used to collapse worker trees into logical
// sessions and to walk up to the owning app for click-to-focus.
func parentPID(of pid: Int32) -> Int32 {
    var info = proc_bsdinfo()
    let r = proc_pidinfo(pid, 3 /* PROC_PIDTBSDINFO */, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
    return r > 0 ? Int32(info.pbi_ppid) : 0
}

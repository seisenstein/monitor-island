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

        for p in procs {
            let nameL = p.name.lowercased()
            let argsL = p.args.lowercased()
            let hay = (p.path + " " + p.args).lowercased()
            let isAppBundle = p.path.contains(".app/Contents")

            // Claude Code CLI: the executable is .../claude-code/bin/claude.exe, comm
            // "claude". Match the claude-code package path, the claude/claude.exe binary
            // name, or a node process running the claude-code CLI. Exclude desktop app.
            if !isAppBundle && (hay.contains("claude-code") || hay.contains("anthropic-ai/claude") ||
               nameL == "claude" || nameL.hasPrefix("claude.") ||
               (nameL == "node" && hay.contains("/claude"))) {
                add("Claude Code", pid: p.pid, mem: p.residentMB)
                continue
            }
            // Codex CLI. Current Codex launches a node wrapper that spawns a native
            // "codex" binary; counting both would double the instance count, so we
            // match only the native binary basename (one per logical instance).
            if !isAppBundle && (nameL == "codex" || nameL.hasPrefix("codex.")) {
                add("Codex", pid: p.pid, mem: p.residentMB)
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

        var entries: [WorkloadEntry] = []
        for (label, g) in groups.sorted(by: { $0.key < $1.key }) {
            let insts = g.instances.sorted { $0.memoryMB > $1.memoryMB }
            entries.append(WorkloadEntry(label: label, count: g.count, cpuPercent: 0,
                                         memoryMB: round2(g.mem), detail: g.detail, instances: insts))
        }
        return Result(entries: entries, localModelName: localModelName, localModelMemoryMB: localModelMem.map(round1))
    }
}

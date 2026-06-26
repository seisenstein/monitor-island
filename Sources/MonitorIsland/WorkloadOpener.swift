import Foundation
import Darwin
import AppKit
import ApplicationServices

private struct OpenerTarget {
    var pid: Int32
    var lineage: [Int32]
    var tty: String?
    var cwd: String?
    var argv: [String]
    var envByPID: [Int32: [String: String]]

    var commandLine: String { argv.joined(separator: " ") }

    var windowTitleNeedles: [String] {
        var out: [String] = []
        if let cwd, !cwd.isEmpty, cwd != "/" {
            out.append(cwd)
            let last = (cwd as NSString).lastPathComponent
            if last.count >= 3, last != NSUserName() { out.append(last) }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }
}

// Click-to-open: focus the actually-running instance. For terminals with a scriptable TTY/session
// model this selects the exact tab/pane. For apps without that surface, fall back to the old
// behavior of activating the owning app.
enum WorkloadOpener {
    static func open(pid: Int32) {
        let target = targetInfo(for: pid)

        for ownerPID in target.lineage {
            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  app.activationPolicy != .prohibited else { continue }

            if focusPrecisely(app: app, target: target) { return }
            activate(app)
            return
        }
    }

    private static func focusPrecisely(app: NSRunningApplication, target: OpenerTarget) -> Bool {
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? ""

        if let tty = target.tty {
            if bundleID == "com.googlecode.iterm2" || name.localizedCaseInsensitiveContains("iTerm") {
                return focusITerm(tty: tty)
            }
            if bundleID == "com.apple.Terminal" {
                return focusTerminal(tty: tty)
            }
        }

        if isKitty(bundleID: bundleID, name: name) {
            return focusKitty(app: app, target: target)
        }

        if isGhostty(bundleID: bundleID, name: name) {
            return focusGhosttyIfUniqueCWD(bundleID: bundleID, target: target)
        }

        if isClaude(bundleID: bundleID, name: name) {
            return focusClaudeWindowIfTrusted(app: app, target: target)
        }

        return false
    }

    private static func targetInfo(for pid: Int32) -> OpenerTarget {
        let lineage = processLineage(from: pid)
        var envByPID: [Int32: [String: String]] = [:]
        var argv: [String] = []

        for (idx, p) in lineage.enumerated() {
            let parsed = procArgsAndEnv(for: p)
            envByPID[p] = parsed.env
            if idx == 0 { argv = parsed.argv }
        }

        return OpenerTarget(pid: pid,
                            lineage: lineage,
                            tty: controllingTTY(for: pid),
                            cwd: processCWD(for: pid),
                            argv: argv,
                            envByPID: envByPID)
    }

    private static func processLineage(from pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var seen = Set<Int32>()
        var cur = pid
        var hops = 0

        while cur > 1, hops < 30, !seen.contains(cur) {
            out.append(cur)
            seen.insert(cur)
            let pp = parentPID(of: cur)
            guard pp > 1 else { break }
            cur = pp
            hops += 1
        }
        return out
    }

    @discardableResult
    private static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateAllWindows])
        return true
    }

    private static func focusITerm(tty: String) -> Bool {
        let script = """
        on focusTTY(targetTTY)
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with tb in tabs of w
                repeat with s in sessions of tb
                  try
                    if (tty of s as text) is targetTTY then
                      select s
                      select tb
                      select w
                      activate
                      return true
                    end if
                  end try
                end repeat
              end repeat
            end repeat
          end tell
          return false
        end focusTTY

        focusTTY(\(appleScriptString(tty)))
        """
        return runAppleScript(script)
    }

    private static func focusTerminal(tty: String) -> Bool {
        let script = """
        on focusTTY(targetTTY)
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                try
                  if (tty of t as text) is targetTTY then
                    try
                      set miniaturized of w to false
                    end try
                    set selected of t to true
                    set frontmost of w to true
                    activate
                    return true
                  end if
                end try
              end repeat
            end repeat
          end tell
          return false
        end focusTTY

        focusTTY(\(appleScriptString(tty)))
        """
        return runAppleScript(script)
    }

    private static func focusGhosttyIfUniqueCWD(bundleID: String, target: OpenerTarget) -> Bool {
        guard let cwd = target.cwd, !cwd.isEmpty else { return false }

        let script = """
        on focusCWD(targetCWD)
          tell application id \(appleScriptString(bundleID))
            set matches to {}
            repeat with t in terminals
              try
                if (working directory of t as text) is targetCWD then
                  set matches to matches & {t}
                end if
              end try
            end repeat
            if (count of matches) is 1 then
              focus item 1 of matches
              return true
            end if
          end tell
          return false
        end focusCWD

        focusCWD(\(appleScriptString(cwd)))
        """
        return runAppleScript(script)
    }

    private static func focusKitty(app: NSRunningApplication, target: OpenerTarget) -> Bool {
        guard let socket = firstEnvValue("KITTY_LISTEN_ON", target: target),
              let runner = kittyRemoteRunner(app: app) else { return false }

        var matches: [String] = []
        if let windowID = firstEnvValue("KITTY_WINDOW_ID", target: target), !windowID.isEmpty {
            matches.append("id:\(windowID)")
        }
        matches.append(contentsOf: target.lineage.prefix(while: { $0 != app.processIdentifier }).map { "pid:\($0)" })

        for match in matches {
            if runKittyRemote(runner: runner, socket: socket, match: match) {
                activate(app)
                return true
            }
        }
        return false
    }

    private static func focusClaudeWindowIfTrusted(app: NSRunningApplication, target: OpenerTarget) -> Bool {
        let needles = target.windowTitleNeedles.filter { $0.count >= 3 }
        guard !needles.isEmpty, AXIsProcessTrusted() else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return false }

        for window in windows {
            guard axString(window, kAXRoleAttribute as CFString) == (kAXWindowRole as String),
                  let title = axString(window, kAXTitleAttribute as CFString),
                  needles.contains(where: { title.localizedCaseInsensitiveContains($0) }) else { continue }

            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            activate(app)
            return true
        }
        return false
    }

    private static func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        return result.booleanValue || result.stringValue == "true"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func isKitty(bundleID: String, name: String) -> Bool {
        bundleID.localizedCaseInsensitiveContains("kitty") || name.localizedCaseInsensitiveContains("kitty")
    }

    private static func isGhostty(bundleID: String, name: String) -> Bool {
        bundleID.localizedCaseInsensitiveContains("ghostty") || name.localizedCaseInsensitiveContains("Ghostty")
    }

    private static func isClaude(bundleID: String, name: String) -> Bool {
        bundleID.localizedCaseInsensitiveContains("anthropic.claude") || name == "Claude"
    }

    private static func firstEnvValue(_ key: String, target: OpenerTarget) -> String? {
        for pid in target.lineage {
            if let value = target.envByPID[pid]?[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func kittyRemoteRunner(app: NSRunningApplication) -> (url: URL, prefix: [String])? {
        guard let bundleURL = app.bundleURL else { return nil }
        let kitten = bundleURL.appendingPathComponent("Contents/MacOS/kitten")
        if FileManager.default.isExecutableFile(atPath: kitten.path) {
            return (kitten, ["@"])
        }

        let kitty = bundleURL.appendingPathComponent("Contents/MacOS/kitty")
        if FileManager.default.isExecutableFile(atPath: kitty.path) {
            return (kitty, ["+kitten", "@"])
        }
        return nil
    }

    private static func runKittyRemote(runner: (url: URL, prefix: [String]), socket: String, match: String) -> Bool {
        let process = Process()
        process.executableURL = runner.url
        process.arguments = runner.prefix + [
            "--to", socket,
            "--use-password", "never",
            "focus-window",
            "--match", match
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        if done.wait(timeout: .now() + .milliseconds(700)) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

fileprivate func controllingTTY(for pid: Int32) -> String? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let r = proc_pidinfo(pid, 3 /* PROC_PIDTBSDINFO */, 0, &info, size)
    guard r > 0, info.e_tdev != 0, info.e_tdev != UInt32.max else { return nil }

    let target = Int32(bitPattern: info.e_tdev)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return nil }
    for name in names where name.hasPrefix("ttys") || name.hasPrefix("tty.") {
        let path = "/dev/\(name)"
        var st = stat()
        if Darwin.lstat(path, &st) == 0, st.st_rdev == target {
            return path
        }
    }
    return nil
}

fileprivate func processCWD(for pid: Int32) -> String? {
    var vpi = proc_vnodepathinfo()
    let sz = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
    let r = proc_pidinfo(pid, 9 /* PROC_PIDVNODEPATHINFO */, 0, &vpi, sz)
    guard r > 0 else { return nil }
    let path = withUnsafeBytes(of: &vpi.pvi_cdir.vip_path) { raw -> String in
        String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
}

fileprivate func procArgsAndEnv(for pid: Int32) -> (argv: [String], env: [String: String]) {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 { return ([], [:]) }

    var buf = [CChar](repeating: 0, count: size)
    if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 { return ([], [:]) }
    guard size > 4 else { return ([], [:]) }

    return buf.withUnsafeBufferPointer { ptr -> ([String], [String: String]) in
        let base = UnsafeRawPointer(ptr.baseAddress!)
        var argc: Int32 = 0
        memcpy(&argc, base, 4)

        var offset = 4
        while offset < size && buf[offset] != 0 { offset += 1 }
        while offset < size && buf[offset] == 0 { offset += 1 }

        var argv: [String] = []
        for _ in 0..<max(0, argc) {
            guard let value = readCString(buf, size: size, offset: &offset) else { break }
            argv.append(value)
        }

        var env: [String: String] = [:]
        while offset < size {
            while offset < size && buf[offset] == 0 { offset += 1 }
            guard let value = readCString(buf, size: size, offset: &offset) else { break }
            guard let eq = value.firstIndex(of: "=") else { continue }
            env[String(value[..<eq])] = String(value[value.index(after: eq)...])
        }
        return (argv, env)
    }
}

fileprivate func readCString(_ buf: [CChar], size: Int, offset: inout Int) -> String? {
    let start = offset
    while offset < size && buf[offset] != 0 { offset += 1 }
    guard offset > start else {
        if offset < size { offset += 1 }
        return nil
    }

    let value = String(decoding: (start..<offset).map { UInt8(bitPattern: buf[$0]) }, as: UTF8.self)
    if offset < size { offset += 1 }
    return value
}

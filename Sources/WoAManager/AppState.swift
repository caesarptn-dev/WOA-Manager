import SwiftUI
import AppKit

struct Step {
    let label: String
    let tool: String
    let args: [String]
    var timeout: Double = 60
    var optional = false
}

@MainActor
final class AppState: ObservableObject {
    @Published var log = ""
    @Published var busy = false
    @Published var detected: DeviceProfile?
    @Published var detectNote = "Not scanned yet"
    @Published var manual: DeviceProfile?
    @Published var props: [String: String] = [:]

    var active: DeviceProfile? { manual ?? detected }
    var adb: String { Pref.s("adbPath", Def.adb) }
    var fastboot: String { Pref.s("fastbootPath", Def.fastboot) }
    var heimdall: String { Pref.s("heimdallPath", Def.heimdall) }
    var logDir: String { Pref.s("logDir", Def.logDir) }

    // MARK: logging
    func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
    func line(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log += "[\(f.string(from: Date()))] \(s)\n"
    }
    func header() -> String {
        let d = active.map { "\($0.name) \($0.model) (\($0.id))" } ?? "none"
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        return "WoA Manager log\nmacOS: \(v)\nDevice: \(d)\nProps: \(props)\n\n"
    }
    func exportLog() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "woa-manager-\(stamp()).log"
        if p.runModal() == .OK, let u = p.url {
            try? (header() + log).write(to: u, atomically: true, encoding: .utf8)
            line("Log exported to \(u.path)")
        }
    }
    func autoExport() {
        guard Pref.b("autoExport", true) else { return }
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let path = "\(logDir)/woa-manager-\(stamp()).log"
        try? (header() + log).write(toFile: path, atomically: true, encoding: .utf8)
        line("Log saved to \(path)")
    }

    // MARK: prompts
    func ask(_ msg: String) async -> Bool {
        line("WARN: \(msg)")
        guard Pref.b("askOnError", true) else { line("Stopping (ask-on-error is off)"); return false }
        let a = NSAlert()
        a.messageText = "Problem detected"
        a.informativeText = msg
        a.alertStyle = .warning
        a.addButton(withTitle: "Continue anyway")
        a.addButton(withTitle: "Stop")
        let go = a.runModal() == .alertFirstButtonReturn
        line(go ? "User chose to continue" : "User chose to stop")
        return go
    }
    func confirm(_ msg: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Are you sure?"
        a.informativeText = msg
        a.alertStyle = .critical
        a.addButton(withTitle: "Proceed")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: exec
    @discardableResult
    func exec(_ tool: String, _ args: [String], timeout: Double = 30, quiet: Bool = false) async -> ShellResult {
        if !quiet { line("$ \(tool) \(args.joined(separator: " "))") }
        let r = await Shell.run(tool, args, timeout: timeout)
        if !quiet {
            if !r.out.isEmpty { log += r.out.hasSuffix("\n") ? r.out : r.out + "\n" }
            if r.code == 127 { line("Tool not found. Try: brew install android-platform-tools heimdall (or set the path in Settings)") }
            else if r.code != 0 { line("exit code \(r.code)") }
        }
        return r
    }

    // MARK: detection
    func detect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await scan()
    }

    func scan() async {
        detected = nil
        props = [:]
        let st = await exec(adb, ["get-state"], timeout: 15)
        let state = st.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if st.code == 0 && (state == "device" || state == "recovery") {
            for k in ["ro.product.device", "ro.product.model", "ro.product.name", "ro.hardware", "ro.board.platform", "ro.build.version.release"] {
                let r = await exec(adb, ["shell", "getprop", k], timeout: 15, quiet: true)
                props[k] = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let dev = props["ro.product.device"] ?? ""
            let model = props["ro.product.model"] ?? ""
            let chip = ((props["ro.hardware"] ?? "") + (props["ro.board.platform"] ?? "")).lowercased()
            if let m = DeviceProfile.catalog.first(where: { (!dev.isEmpty && dev.hasPrefix($0.id)) || (!model.isEmpty && model.hasPrefix($0.model)) }) {
                detected = m
                detectNote = "Recognized \(m.name) (\(m.model)) via ADB"
            } else if chip.contains("8890") {
                detectNote = "Exynos 8890 SoC (\(model)) but not in the device list. Pick it manually."
            } else {
                detectNote = "Connected device (\(model.isEmpty ? dev : model)) does not look like an Exynos 8890 phone."
            }
        } else if st.out.contains("unauthorized") {
            detectNote = "ADB sees the phone but it is unauthorized. Accept the prompt on the phone."
        } else {
            let usb = await exec("system_profiler", ["SPUSBDataType"], timeout: 20, quiet: true)
            if usb.out.lowercased().contains("0x04e8") {
                detectNote = "A Samsung USB device is attached but ADB does not answer (download mode / MTP?). Pick the model manually."
            } else {
                detectNote = "No device found."
            }
        }
        line("Detect: \(detectNote)")
    }

    func preflight() async -> Bool {
        if Pref.b("autoDetect", true) { await scan() }
        if let d = active {
            if manual != nil, let det = detected, det != d {
                return await ask("Selected device (\(d.model)) differs from the detected one (\(det.model)).")
            }
            line("Target: \(d.name) \(d.model)")
            return true
        }
        return await ask("No Exynos 8890 device recognized. \(detectNote)")
    }

    // MARK: step runner
    func runSteps(_ title: String, _ steps: [Step], needDevice: Bool = true) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        line("=== \(title) ===")
        if needDevice, !(await preflight()) { line("Cancelled"); autoExport(); return }
        for s in steps {
            line("-- \(s.label)")
            let r = await exec(s.tool, s.args, timeout: s.timeout)
            if r.code != 0 && !s.optional {
                if !(await ask("\"\(s.label)\" failed (exit \(r.code)).")) { line("Stopped"); break }
            }
        }
        line("=== end: \(title) ===")
        autoExport()
    }

    // MARK: actions
    func flashUEFI() async {
        let img = Pref.s("uefiImage", "")
        guard FileManager.default.fileExists(atPath: img) else { line("ERROR: choose a UEFI image first"); return }
        let method = Pref.s("flashMethod", "adb")
        let part = Pref.s("bootPartition", Def.bootPartition)
        let target = method == "adb" ? part : "the \(Pref.s("heimdallPart", Def.heimdallPart)) partition"
        guard confirm("This overwrites \(target) with \((img as NSString).lastPathComponent).") else { return }
        var steps: [Step] = []
        if method == "adb" {
            let su = Pref.b("useSu", false)
            func sh(_ c: String) -> [String] { su ? ["shell", "su", "-c", "'\(c)'"] : ["shell", c] }
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            if Pref.b("backupFirst", true) {
                steps.append(Step(label: "Backup boot partition", tool: adb, args: sh("dd if=\(part) of=/data/local/tmp/boot_backup.img bs=4M"), timeout: 120))
                steps.append(Step(label: "Pull backup", tool: adb, args: ["pull", "/data/local/tmp/boot_backup.img", "\(logDir)/boot_backup-\(stamp()).img"], timeout: 120))
            }
            steps.append(Step(label: "Push UEFI image", tool: adb, args: ["push", img, "/data/local/tmp/uefi.img"], timeout: 120))
            steps.append(Step(label: "Write to partition", tool: adb, args: sh("dd if=/data/local/tmp/uefi.img of=\(part) bs=4M"), timeout: 120))
            steps.append(Step(label: "Sync", tool: adb, args: sh("sync")))
        } else {
            steps.append(Step(label: "Heimdall flash", tool: heimdall, args: ["flash", "--\(Pref.s("heimdallPart", Def.heimdallPart))", img, "--no-reboot"], timeout: 300))
        }
        if Pref.b("rebootAfter", false) { steps.append(Step(label: "Reboot", tool: adb, args: ["reboot"], optional: true)) }
        await runSteps("Flash UEFI", steps)
    }

    func flashFFU() async {
        let ffu = Pref.s("ffuPath", "")
        let tool = Pref.s("ffuToolPath", "")
        guard FileManager.default.fileExists(atPath: ffu) else { line("ERROR: choose an FFU file first"); return }
        guard !tool.isEmpty else { line("ERROR: set your FFU flashing tool on the FFU tab"); return }
        guard confirm("Flash \((ffu as NSString).lastPathComponent) with \((tool as NSString).lastPathComponent)? This can overwrite the whole storage layout.") else { return }
        let args = splitArgs(Pref.s("ffuFlashArgs", Def.ffuArgs)).map { $0.replacingOccurrences(of: "{ffu}", with: ffu) }
        await runSteps("Flash FFU", [Step(label: "FFU flash", tool: tool, args: args, timeout: 3600)], needDevice: false)
    }

    func enterFFULoader() async {
        let img = Pref.s("ffuLoaderImage", "")
        let parts = splitArgs(Pref.s("ffuLoaderCmd", Def.loaderCmd)).map { $0.replacingOccurrences(of: "{img}", with: img) }
        guard let tool = parts.first else { line("ERROR: set the FFU loader boot command in Settings"); return }
        await runSteps("Boot into FFU loader mode", [Step(label: "Boot loader", tool: tool, args: Array(parts.dropFirst()), timeout: 120)], needDevice: false)
    }

    func reboot(_ target: String?) async {
        var a = ["reboot"]
        if let t = target { a.append(t) }
        await runSteps("Reboot \(target ?? "system")", [Step(label: "adb reboot", tool: adb, args: a)])
    }

    func inspectFFU(_ path: String) -> String {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return "No file selected" }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 16)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let sig = String(data: head.dropFirst(4).prefix(12), encoding: .ascii) ?? ""
        let ok = sig == "SignedImage "
        return "\(ok ? "Valid FFU signature" : "WARNING: no FFU signature found"), \(size / 1_048_576) MB"
    }
}

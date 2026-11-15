import Foundation

struct DeviceProfile: Identifiable, Hashable {
    let id: String      // codename
    let name: String
    let model: String
    static let catalog: [DeviceProfile] = [
        .init(id: "herolte",   name: "Galaxy S7",      model: "SM-G930F"),
        .init(id: "hero2lte",  name: "Galaxy S7 edge", model: "SM-G935F"),
        .init(id: "gracelte",  name: "Galaxy Note 7",  model: "SM-N930F"),
        .init(id: "gracerlte", name: "Galaxy Note FE", model: "SM-N935F"),
    ]
}

enum Def {
    static let adb = "adb"
    static let fastboot = "fastboot"
    static let heimdall = "heimdall"
    static let bootPartition = "/dev/block/platform/155a0000.ufs/by-name/BOOT"
    static let heimdallPart = "BOOT"
    static let ffuArgs = "{ffu}"
    static let loaderCmd = "fastboot boot {img}"
    static var logDir: String { NSHomeDirectory() + "/Documents/WoAManager-Logs" }
}

enum Pref {
    static func s(_ k: String, _ d: String) -> String { UserDefaults.standard.string(forKey: k) ?? d }
    static func b(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
}

struct ShellResult { let code: Int32; let out: String }

enum Shell {
    static func run(_ tool: String, _ args: [String], timeout: Double) async -> ShellResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ShellResult, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [tool] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(code: 127, out: "Cannot launch \(tool): \(error.localizedDescription)"))
                    return
                }
                var timedOut = false
                let timer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                var out = String(decoding: data, as: UTF8.self)
                if timedOut { out += "\n(timed out after \(Int(timeout))s)" }
                cont.resume(returning: ShellResult(code: timedOut ? 124 : p.terminationStatus, out: out))
            }
        }
    }
}

func splitArgs(_ s: String) -> [String] {
    var out: [String] = [], cur = ""
    var quote: Character? = nil
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == " " {
            if !cur.isEmpty { out.append(cur); cur = "" }
        } else {
            cur.append(ch)
        }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

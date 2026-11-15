import SwiftUI
import AppKit

@main
struct WoAManagerApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(state).frame(minWidth: 860, minHeight: 560)
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case device = "Device", flash = "Flash UEFI", ffu = "FFU", tools = "Tools", log = "Log", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .device: return "iphone"
        case .flash: return "bolt.fill"
        case .ffu: return "shippingbox"
        case .tools: return "wrench.and.screwdriver"
        case .log: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @State private var tab: Tab? = .device
    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            VStack(spacing: 0) {
                switch tab ?? .device {
                case .device: DeviceView()
                case .flash: FlashView()
                case .ffu: FFUView()
                case .tools: ToolsView()
                case .log: LogView()
                case .settings: SettingsView()
                }
                if s.busy {
                    HStack { ProgressView().controlSize(.small); Text("Working… see Log tab").font(.caption) }.padding(6)
                }
            }
        }
        .task { if Pref.b("autoDetect", true) { await s.detect() } }
    }
}

struct PathField: View {
    let title: String
    @Binding var path: String
    var dir = false
    var body: some View {
        HStack {
            TextField(title, text: $path)
            Button("Browse…") {
                let p = NSOpenPanel()
                p.canChooseFiles = !dir
                p.canChooseDirectories = dir
                if p.runModal() == .OK, let u = p.url { path = u.path }
            }
        }
    }
}

struct DeviceView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section("Detected") {
                Text(s.detected.map { "\($0.name) (\($0.model), \($0.id))" } ?? "None")
                Text(s.detectNote).foregroundStyle(.secondary)
                Button("Scan") { Task { await s.detect() } }.disabled(s.busy)
            }
            Section("Manual selection (overrides detection)") {
                Picker("Device", selection: $s.manual) {
                    Text("Auto").tag(DeviceProfile?.none)
                    ForEach(DeviceProfile.catalog) { Text("\($0.name) \($0.model)").tag(Optional($0)) }
                }
            }
            if !s.props.isEmpty {
                Section("Properties") {
                    ForEach(s.props.sorted(by: { $0.key < $1.key }), id: \.key) { LabeledContent($0.key, value: $0.value) }
                }
            }
        }.formStyle(.grouped)
    }
}

struct FlashView: View {
    @EnvironmentObject var s: AppState
    @AppStorage("uefiImage") var img = ""
    @AppStorage("flashMethod") var method = "adb"
    @AppStorage("bootPartition") var part = Def.bootPartition
    @AppStorage("heimdallPart") var hpart = Def.heimdallPart
    @AppStorage("useSu") var useSu = false
    @AppStorage("backupFirst") var backup = true
    @AppStorage("rebootAfter") var reboot = false
    var body: some View {
        Form {
            Section("UEFI image") { PathField(title: "e.g. n935f-uefi-test14.img", path: $img) }
            Section("Method") {
                Picker("Flash with", selection: $method) {
                    Text("ADB dd (recovery/root)").tag("adb")
                    Text("Heimdall (download mode)").tag("heimdall")
                }.pickerStyle(.segmented)
                if method == "adb" {
                    TextField("Boot partition", text: $part)
                    Toggle("Run through su", isOn: $useSu)
                    Toggle("Back up current partition first", isOn: $backup)
                } else {
                    TextField("Heimdall partition name", text: $hpart)
                }
                Toggle("Reboot after flashing", isOn: $reboot)
            }
            Button("Flash UEFI image") { Task { await s.flashUEFI() } }.disabled(s.busy || img.isEmpty)
        }.formStyle(.grouped)
    }
}

struct FFUView: View {
    @EnvironmentObject var s: AppState
    @AppStorage("ffuPath") var ffu = ""
    @AppStorage("ffuToolPath") var tool = ""
    @AppStorage("ffuFlashArgs") var args = Def.ffuArgs
    var body: some View {
        Form {
            Section("FFU image") {
                PathField(title: "image.ffu", path: $ffu)
                Text(s.inspectFFU(ffu)).foregroundStyle(.secondary)
            }
            Section("Flasher") {
                PathField(title: "FFU flashing tool", path: $tool)
                TextField("Arguments ({ffu} = image path)", text: $args)
            }
            Text("Experimental: the phone needs an FFU-capable loader mode before this can work.").font(.caption).foregroundStyle(.secondary)
            Button("Flash FFU") { Task { await s.flashFFU() } }.disabled(s.busy || ffu.isEmpty)
        }.formStyle(.grouped)
    }
}

struct ToolsView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        Form {
            Section("Boot") {
                HStack {
                    Button("Android") { Task { await s.reboot(nil) } }
                    Button("Recovery") { Task { await s.reboot("recovery") } }
                    Button("Download mode") { Task { await s.reboot("download") } }
                    Button("Bootloader") { Task { await s.reboot("bootloader") } }
                }
                Button("FFU loader mode") { Task { await s.enterFFULoader() } }
            }
            Section("Diagnostics") {
                HStack {
                    Button("adb devices") { Task { await s.runSteps("adb devices", [Step(label: "adb devices", tool: s.adb, args: ["devices", "-l"])], needDevice: false) } }
                    Button("fastboot devices") { Task { await s.runSteps("fastboot devices", [Step(label: "fastboot devices", tool: s.fastboot, args: ["devices"])], needDevice: false) } }
                    Button("heimdall detect") { Task { await s.runSteps("heimdall detect", [Step(label: "heimdall detect", tool: s.heimdall, args: ["detect"])], needDevice: false) } }
                    Button("Dump getprop") { Task { await s.runSteps("getprop", [Step(label: "getprop", tool: s.adb, args: ["shell", "getprop"])]) } }
                }
            }
            Section("Logs") { Button("Export log…") { s.exportLog() } }
        }.formStyle(.grouped).disabled(s.busy)
    }
}

struct LogView: View {
    @EnvironmentObject var s: AppState
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Export…") { s.exportLog() }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.log, forType: .string) }
                Button("Clear") { s.log = "" }
            }.padding([.top, .horizontal])
            ScrollView {
                Text(s.log.isEmpty ? "No output yet." : s.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("adbPath") var adb = Def.adb
    @AppStorage("fastbootPath") var fb = Def.fastboot
    @AppStorage("heimdallPath") var hd = Def.heimdall
    @AppStorage("autoDetect") var autoDetect = true
    @AppStorage("askOnError") var askOnError = true
    @AppStorage("autoExport") var autoExport = true
    @AppStorage("logDir") var logDir = Def.logDir
    @AppStorage("ffuLoaderImage") var loaderImg = ""
    @AppStorage("ffuLoaderCmd") var loaderCmd = Def.loaderCmd
    var body: some View {
        Form {
            Section("Tool paths") {
                TextField("adb", text: $adb)
                TextField("fastboot", text: $fb)
                TextField("heimdall", text: $hd)
            }
            Section("Behaviour") {
                Toggle("Auto-detect device before every action", isOn: $autoDetect)
                Toggle("On errors: ask whether to continue (off = stop)", isOn: $askOnError)
                Toggle("Save a log file after every task", isOn: $autoExport)
                PathField(title: "Log folder", path: $logDir, dir: true)
            }
            Section("FFU loader mode") {
                PathField(title: "Loader image ({img})", path: $loaderImg)
                TextField("Boot command", text: $loaderCmd)
            }
            Button("Reset all settings") {
                if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
            }
        }.formStyle(.grouped)
    }
}

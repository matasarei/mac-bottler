// The launcher window every kitchen-built app shares. It reads the recipe
// (Resources/recipe/recipe.json) and shows only what the player can choose:
// install the game from a folder, then the game variant (if the recipe has
// several), the display (if several are connected) and Play. Everything else is
// decided per launch by Resources/bin/launch.sh.
import AppKit
import SwiftUI

let resources = Bundle.main.resourceURL!
let bin = resources.appendingPathComponent("bin")

struct Variant: Decodable { let label: String }
struct RecipeInfo: Decodable {
    struct Launch: Decodable { let variants: [Variant] }
    let title: String
    let launch: Launch
}

let recipe: RecipeInfo = {
    let url = resources.appendingPathComponent("recipe/recipe.json")
    guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(RecipeInfo.self, from: data) else {
        fatalError("the app has no readable recipe at \(url.path)")
    }
    return r
}()

/// key=value settings the launcher remembers (Resources/launcher.conf).
enum Conf {
    static let url = resources.appendingPathComponent("launcher.conf")
    static func read() -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let eq = line.firstIndex(of: "=") { out[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
        }
        return out
    }
    static func write(_ values: [String: String]) {
        let text = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct DisplayChoice: Hashable { let id: String; let name: String }

func connectedDisplays() -> [DisplayChoice] {
    NSScreen.screens.enumerated().map { i, s in
        let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return DisplayChoice(id: i == 0 ? "main" : String(n), name: i == 0 ? "\(s.localizedName) (main)" : s.localizedName)
    }
}

/// Runs a script from Resources/bin and reports its output and exit code.
func runScript(_ name: String, _ args: [String], output: @escaping (String) -> Void,
               done: @escaping (Int32, String) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [bin.appendingPathComponent(name).path] + args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    out.fileHandleForReading.readabilityHandler = { h in
        if let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty {
            DispatchQueue.main.async { output(s) }
        }
    }
    p.terminationHandler = { p in
        out.fileHandleForReading.readabilityHandler = nil
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        DispatchQueue.main.async { done(p.terminationStatus, e) }
    }
    do { try p.run() } catch { done(127, "\(error)") }
}

final class Model: ObservableObject {
    @Published var installed = FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("game/.kitchen-install.json").path)
    @Published var busy = false
    @Published var status = ""
    @Published var error = ""
    @Published var variant: Int
    @Published var display: String
    @Published var displays = connectedDisplays()

    init() {
        let conf = Conf.read()
        variant = min(Int(conf["VARIANT"] ?? "0") ?? 0, recipe.launch.variants.count - 1)
        display = conf["DISPLAY"] ?? "main"
        if !displays.contains(where: { $0.id == display }) { display = "main" }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.displays = connectedDisplays()
            if !self.displays.contains(where: { $0.id == self.display }) { self.display = "main" }
        }
    }

    func chooseFolderAndInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder with your copy of \(recipe.title)."
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        busy = true; error = ""; status = "Installing…"
        runScript("install.sh", [resources.path, folder.path], output: { [weak self] s in
            if let last = s.split(separator: "\n").last { self?.status = String(last) }
        }, done: { [weak self] code, stderr in
            guard let self else { return }
            self.busy = false
            if code == 0 {
                self.installed = true; self.status = ""
                self.applyIcon()
            } else {
                self.status = ""
                self.error = stderr.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "kitchen install: refused: ", with: "") }
                    ?? "The installation failed (code \(code))."
            }
        })
    }

    /// The icon made from the player's own game becomes the app's icon.
    func applyIcon() {
        let icns = resources.appendingPathComponent("icon/AppIcon.icns")
        if let image = NSImage(contentsOf: icns) {
            NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
            NSApp.applicationIconImage = image
        }
    }

    func play() {
        Conf.write(["VARIANT": String(variant), "DISPLAY": display])
        busy = true; error = ""; status = "Playing…"
        NSApp.hide(nil)
        runScript("launch.sh", [resources.path, String(variant), display], output: { _ in }, done: { [weak self] code, _ in
            guard let self else { return }
            self.busy = false; self.status = ""
            if code == 2 { self.error = "The game could not be started. See Resources/logs/last-launch.log." }
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}

struct LauncherView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 18) {
            Text(recipe.title).font(.system(size: 26, weight: .semibold))
            if model.installed {
                if recipe.launch.variants.count > 1 {
                    Picker("Game", selection: $model.variant) {
                        ForEach(recipe.launch.variants.indices, id: \.self) { i in
                            Text(recipe.launch.variants[i].label).tag(i)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if model.displays.count > 1 {
                    Picker("Display", selection: $model.display) {
                        ForEach(model.displays, id: \.self) { d in Text(d.name).tag(d.id) }
                    }
                    .frame(maxWidth: 320)
                }
                Button(action: model.play) {
                    Text("Play").font(.title2).frame(maxWidth: 200).padding(.vertical, 6)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.busy)
                Button("Install from another folder…", action: model.chooseFolderAndInstall)
                    .buttonStyle(.link).font(.footnote).disabled(model.busy)
            } else {
                Text("Choose the folder with your copy of \(recipe.title). It is copied into this app; the original folder is not changed.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
                Button(action: model.chooseFolderAndInstall) {
                    Text("Install game…").font(.title3).frame(maxWidth: 200).padding(.vertical, 4)
                }
                .keyboardShortcut(.defaultAction).controlSize(.large).disabled(model.busy)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if !model.status.isEmpty { Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            if !model.error.isEmpty {
                Text(model.error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}

@main
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window(recipe.title, id: "main") { LauncherView(model: model) }
            .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // the window hides while playing; an app quit in that state would reopen hidden
    func applicationDidFinishLaunching(_ note: Notification) { NSApp.unhide(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

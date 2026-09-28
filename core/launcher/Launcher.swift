// The launcher every mac-bottler app shares. The game is installed when the app is
// built, so the window shows only what the player can choose: the game variant (if
// the recipe has several), the display (if several are connected) and Play. With
// nothing to choose there is no window: the game starts at once and the app quits
// with it (hold Option while opening the app to see the window anyway). The app is
// a background app (LSUIElement) and takes a Dock tile only while its window shows.
// Everything else is decided per launch by Resources/bin/launch.sh.
import AppKit
import SwiftUI

let resources = Bundle.main.resourceURL!
/// True while the game runs: the window is put away then, which must not quit the app.
var playing = false
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
    let installed = FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("game/.bottler-install.json").path)
    @Published var busy = false
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

    /// The launcher's window: put away while the game runs, shown again after.
    var window: NSWindow? { launcherWindow }

    /// Nothing to choose: one variant, one display (and the game is installed).
    var nothingToChoose: Bool { installed && recipe.launch.variants.count == 1 && displays.count == 1 }

    /// Starts the game. With a window, it is put away while the game runs and shown
    /// again after; without one (`direct`), the app quits with the game unless the
    /// game could not be started, which the window then explains.
    func play(direct: Bool = false) {
        Conf.write(["VARIANT": String(variant), "DISPLAY": display])
        busy = true; error = ""; playing = true
        let w = window
        w?.orderOut(nil)
        // out of the Dock while the game runs: the game is the one tile there
        NSApp.setActivationPolicy(.accessory)
        runScript("launch.sh", [resources.path, String(variant), display], output: { _ in }, done: { [weak self] code, _ in
            guard let self else { return }
            self.busy = false; playing = false
            if code == 2 { self.error = "The game could not be started. See Contents/Resources/logs/last-launch.log." }
            if direct && code != 2 { NSApp.terminate(nil); return }
            showWindow(self)
        })
    }
}

/// The launcher window, made when first needed; the app joins the Dock while it shows.
var launcherWindow: NSWindow?
func showWindow(_ model: Model) {
    if launcherWindow == nil {
        let w = NSWindow(contentViewController: NSHostingController(rootView: LauncherView(model: model)))
        w.title = recipe.title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        launcherWindow = w
    }
    NSApp.setActivationPolicy(.regular)
    launcherWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
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
                Button(action: { model.play() }) {
                    Text("Play").font(.title2).frame(maxWidth: 200).padding(.vertical, 6)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.busy)
            } else {
                Text("This app was built without its game. Rebuild it with make app.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
            }
            if model.busy { ProgressView().controlSize(.small) }
            if !model.error.isEmpty {
                Text(model.error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}

@main
enum LauncherMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = mainMenu()
        NSApp.unhide(nil)   // an app quit while hidden (its window put away) reopens hidden
        if model.nothingToChoose && !NSEvent.modifierFlags.contains(.option) {
            model.play(direct: true)
        } else {
            showWindow(model)
        }
    }

    // opening the app again (Finder, Dock) while it runs without a window
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !playing && !hasVisibleWindows { showWindow(model) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !playing }
}

/// The app menu the window needs: Hide and Quit, with their usual shortcuts.
func mainMenu() -> NSMenu {
    let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide \(recipe.title)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(recipe.title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    return menu
}

import AppKit
import SwiftUI

@main
struct SpatializeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Spatialize", id: "main") {
            ContentView()
                .environmentObject(app)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 820)
        // self-tests run headless: no window on the user's screen
        .defaultLaunchBehavior(SelfTest.active ? .suppressed : .automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Movie…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { app.open(url) }
                }
                .keyboardShortcut("o")
                .disabled(app.conversion.isRunning)
                Button("Close Movie") { app.close() }
                    .keyboardShortcut("w")
                    .disabled(app.info == nil || app.conversion.isRunning)
                Divider()
                Button("Show Queue") { app.showQueue = true }
                    .keyboardShortcut("l")
                Button("Adjust Audio Sync of a Movie…") { app.showResync = true }
                    .keyboardShortcut("y", modifiers: [.command, .option])
            }
            CommandMenu("Listening") {
                Button("Find My Head Model…") { app.showHeadTest = true }
                Button("Calibrate Height for My Ears…") { app.showCalibration = true }
            }
            CommandGroup(after: .toolbar) {
                Button("Reset All Settings") { app.settings.reset() }
                    .disabled(app.conversion.isRunning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["SPATIALIZE_LIVE_TEST"] {
            MainActor.assumeIsolated { LiveSelfTest.run(URL(fileURLWithPath: dir)) }
            exit(0)
        }
        if let out = ProcessInfo.processInfo.environment["SPATIALIZE_SNAPSHOT"],
           let movie = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            Task { @MainActor in
                await SelfTest.snapshot(movie: URL(fileURLWithPath: movie), to: URL(fileURLWithPath: out))
                exit(0)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Finder's right-click "Convert with Spatialize"
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        MainActor.assumeIsolated { AppState.shared.scanLeftovers() }
        // `Spatialize /path/to/movie.mkv` from a terminal
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }),
           FileManager.default.fileExists(atPath: path) {
            Task { @MainActor in AppState.shared.open(URL(fileURLWithPath: path)) }
        }
    }

    // Finder "Open With" and dropping a file on the Dock icon
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated { AppState.shared.conversion.isRunning || AppState.shared.queue.runner.isRunning }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A conversion is still running"
        alert.informativeText = "Quitting stops it. The steps it has finished are kept, so it can resume the next time you open Spatialize."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            MainActor.assumeIsolated { AppState.shared.conversion.suspend(); AppState.shared.queue.runner.suspend() }
            return .terminateNow
        }
        return .terminateCancel
    }
}

enum SelfTest {
    static var active: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SPATIALIZE_LIVE_TEST"] != nil || env["SPATIALIZE_SNAPSHOT"] != nil
    }

    /// Renders the editor for a movie into a PNG without opening a window (layout check).
    @MainActor
    static func snapshot(movie: URL, to out: URL) async {
        let app = AppState.shared
        app.open(movie)
        while app.loading || app.info == nil {
            if app.loadError != nil { print("snapshot: \(app.loadError!)"); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(4)) // thumbnail
        guard let info = app.info else { return }
        let part = ProcessInfo.processInfo.environment["SPATIALIZE_SNAPSHOT_PART"]
        if part == "banner" {
            app.interrupted = [InterruptedConversion(folder: URL(fileURLWithPath: "/tmp/.atmos2apple.r-x"), input: movie,
                                                     output: URL(fileURLWithPath: "/tmp/Gravity · Spatial.mov"), arguments: ["x"],
                                                     finished: ["decode", "audio"], bytes: 3_400_000_000, started: Date())]
            app.cleanedBytes = 17_200_000_000
        }
        let content: AnyView = part == "eq"
            ? AnyView(HeadphoneEQ(settings: app.settings).frame(width: 480).padding(26))
            : part == "sound"
            ? AnyView(SoundSection(settings: app.settings).frame(width: 525).padding(26))
            : part == "headtest"
            ? AnyView(HeadTestSheet())
            : part == "calibrate"
            ? AnyView(HeightCalibrationSheet())
            : part == "pickers"
            ? AnyView(HStack(spacing: 30) {
                DomePicker(answer: .constant(HRIRSet.Direction(az: 120, el: 30)), reveal: HRIRSet.Direction(az: 150, el: 0)).frame(width: 380, height: 380)
                ElevationPicker(elevation: .constant(40)).frame(width: 340, height: 300)
            }.padding(30))
            : part == "banner"
            ? AnyView(LeftoverBanners().frame(height: 200))
            : part == "audio"
            ? AnyView(AudioSection(settings: app.settings, info: info).frame(width: 525).padding(26))
            : part == "liveview"
            ? AnyView(LivePlayerView(app: app))
            : part == "live"
            ? AnyView(LiveDome(dots: [LiveDot(id: 10, name: "Object 1", az: 40, el: 10, level: 0.2, isBed: false),
                                      LiveDot(id: 11, name: "Object 2", az: -120, el: 55, level: 0.05, isBed: false),
                                      LiveDot(id: 2, name: "C", az: 0, el: 0, level: 0.1, isBed: true)], headYaw: 20)
                        .frame(width: 300, height: 300).padding(20))
            : AnyView(SnapshotEditor(info: info, settings: app.settings, conversion: app.conversion))
        let view = content
            .environmentObject(app)
            .frame(width: 1120)
            .background(Backdrop(image: app.thumbnail))
            .environment(\.colorScheme, .dark)
        // draw the real AppKit view hierarchy off-screen (the window is never shown)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))
        print("snapshot: laid out \(Int(host.fittingSize.width))×\(Int(host.fittingSize.height))")
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("snapshot: no bitmap"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: out)
        let img = NSImage(size: size)
        print("snapshot: \(Int(img.size.width))×\(Int(img.size.height))")
    }
}

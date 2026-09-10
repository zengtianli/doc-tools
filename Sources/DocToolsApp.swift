import SwiftUI
import AppKit

// =============================================================================
// DocTools — app entry point
//
// Layout rules this skeleton follows:
//   · The WindowGroup holds only ContentView; the initial size comes from
//     .defaultSize on the scene, and minimum-size constraints live on the
//     NavigationSplitView detail root (see ContentView) — putting
//     .frame(min…) on the WindowGroup / SplitView breaks layout.
//   · Menu commands broadcast via NotificationCenter (⌘R refresh) and views
//     consume them with onReceive instead of holding the ViewModel directly —
//     naturally decoupled across multiple windows/tabs.
// =============================================================================

// MARK: - Cross-view notifications (menu command → current view)

extension Notification.Name {
    static let consoleRefresh = Notification.Name("consoleRefresh")
}

// Recording is explicitly opt-in and valid only for a separately signed copy
// prepared by scripts/prepare-recording.py. An incomplete request never opens
// an ordinary window, because that could interrupt the user's active app.
enum DocKitRecording {
    static let identifierPrefix = "io.github.zengtianli.DocTools.Recording."
    static let requested = ProcessInfo.processInfo.environment["DOCKIT_BACKGROUND"] == "1"
        || Bundle.main.bundleIdentifier?.hasPrefix(identifierPrefix) == true
    static let valid = validate(environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)

    static func validate(environment env: [String: String], bundleIdentifier: String?) -> Bool {
        failure(environment: env, bundleIdentifier: bundleIdentifier) == nil
    }

    static func failure(environment env: [String: String], bundleIdentifier: String?) -> String? {
        guard env["DOCKIT_BACKGROUND"] == "1" else { return "background_flag_missing" }
        guard let identifier = bundleIdentifier,
              identifier.hasPrefix(identifierPrefix) else { return "bundle_id_not_recording" }
        guard let rootPath = env["DOCKIT_RECORDING_ROOT"] else { return "recording_root_missing" }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == rootPath, root.path != "/" else { return "recording_root_not_canonical" }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".dockit-recording.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["kind"] as? String == "dockit-recording-v1",
              marker["bundle_id"] as? String == identifier else { return "recording_marker_mismatch" }

        // LaunchServices may reset HOME/CFFIXED_USER_HOME. GUI preferences are
        // separated by the recording bundle ID; only product paths gate launch.
        let requiredPaths = [
            "DOCKIT_INPUT_DIR": "inputs", "DOCKIT_OUTPUT_DIR": "outputs",
            "DOCKIT_STATE_DIR": "state", "DOCKIT_BACKEND_HOME": "state/python-home"
        ]
        for (key, relativePath) in requiredPaths.sorted(by: { $0.key < $1.key }) {
            let expected = root.appendingPathComponent(relativePath).path
            guard let path = env[key], path == expected else { return "isolated_path_mismatch_" + key }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard url.path == expected,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return "isolated_directory_invalid_" + key }
        }
        guard let files = env["DOCKIT_DEMO_FILES"], !files.isEmpty else { return "selected_files_missing" }
        let inputsPrefix = root.appendingPathComponent("inputs").path + "/"
        for path in files.components(separatedBy: "\n") {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path == path, path.hasPrefix(inputsPrefix) else { return "selected_file_outside_inputs" }
            guard FileManager.default.fileExists(atPath: path) else { return "selected_file_missing" }
        }
        return nil
    }

    // The signed copy must sit beside its matching marker. This fallback works
    // even when a launcher drops LSEnvironment. Log condition names, never env.
    static func record(_ event: String, condition: String? = nil,
                       bundleURL: URL = Bundle.main.bundleURL,
                       bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        guard let identifier = bundleIdentifier,
              identifier.hasPrefix(identifierPrefix) else { return }
        let root = bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".dockit-recording.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["kind"] as? String == "dockit-recording-v1",
              marker["bundle_id"] as? String == identifier else { return }
        let state = root.appendingPathComponent("state")
        let log = state.appendingPathComponent("launch-diagnostics.jsonl")
        var isDirectory: ObjCBool = false
        guard state.resolvingSymlinksInPath().path == state.path,
              log.resolvingSymlinksInPath().path == log.path,
              FileManager.default.fileExists(atPath: state.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        var row = ["at": ISO8601DateFormatter().string(from: Date()), "event": event]
        if let condition { row["condition"] = condition }
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys) else { return }
        line.append(0x0a)
        if FileManager.default.fileExists(atPath: log.path), let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: line) } catch { }
        } else {
            try? line.write(to: log, options: .atomic)
        }
    }
}

private final class DocKitRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DocKitAppDelegate: NSObject, NSApplicationDelegate {
    private var recordingPanel: NSPanel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        if DocKitRecording.requested { DocKitRecording.record("will_finish_launching") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DocKitRecording.requested else { return }
        guard DocKitRecording.valid else {
            DocKitRecording.record("validation_failed", condition: DocKitRecording.failure(
                environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier))
            fputs("DocKit: refusing an incomplete or non-isolated recording environment.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let panel = DocKitRecordingPanel(
            contentRect: NSRect(x: 120, y: 120, width: 1060, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "DocKit"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.contentView = NSHostingView(rootView: ContentView().preferredColorScheme(.light))
        recordingPanel = panel
        panel.orderBack(nil)
        DocKitRecording.record("panel_ready")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !DocKitRecording.requested
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DocKitRecording.requested { DocKitRecording.record("termination_requested") }
        return .terminateNow
    }
}

@main
struct DocToolsApp: App {
    @NSApplicationDelegateAdaptor(DocKitAppDelegate.self) private var appDelegate

    init() {
        if DocKitRecording.requested { DocKitRecording.record("app_initialized") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1060, height: 760)
        .defaultLaunchBehavior(DocKitRecording.requested ? .suppressed : .automatic)
        .commands {
            CommandGroup(replacing: .help) {
                Link("DocKit 使用教程", destination: URL(string: "https://app-mac-doctools.tianli.cyou/#install")!)
            }
            CommandMenu("操作") {
                Button("搜索功能…") {
                    NotificationCenter.default.post(name: .tlPaletteToggle, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)   // ⌘K command palette
                Button("刷新") {
                    NotificationCenter.default.post(name: .consoleRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

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
    static let requested = ProcessInfo.processInfo.environment["DOCKIT_BACKGROUND"] == "1"
    static let valid = validate(environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)

    static func validate(environment env: [String: String], bundleIdentifier: String?) -> Bool {
        guard env["DOCKIT_BACKGROUND"] == "1",
              let identifier = bundleIdentifier,
              identifier.hasPrefix("io.github.zengtianli.DocTools.Recording."),
              let rootPath = env["DOCKIT_RECORDING_ROOT"] else { return false }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == rootPath, root.path != "/",
              let data = try? Data(contentsOf: root.appendingPathComponent(".dockit-recording.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["kind"] as? String == "dockit-recording-v1",
              marker["bundle_id"] as? String == identifier else { return false }

        let requiredPaths = [
            "DOCKIT_INPUT_DIR": "inputs", "DOCKIT_OUTPUT_DIR": "outputs",
            "DOCKIT_STATE_DIR": "state", "DOCKIT_PREFERENCES_DIR": "home/Library/Preferences",
            "HOME": "home", "CFFIXED_USER_HOME": "home"
        ]
        for (key, relativePath) in requiredPaths {
            let expected = root.appendingPathComponent(relativePath).path
            guard let path = env[key], path == expected else { return false }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard url.path == expected,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
        }
        guard let files = env["DOCKIT_DEMO_FILES"], !files.isEmpty else { return false }
        let inputsPrefix = root.appendingPathComponent("inputs").path + "/"
        for path in files.components(separatedBy: "\n") {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path == path, path.hasPrefix(inputsPrefix),
                  FileManager.default.fileExists(atPath: path) else { return false }
        }
        return true
    }
}

private final class DocKitRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DocKitAppDelegate: NSObject, NSApplicationDelegate {
    private var recordingPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard DocKitRecording.requested else { return }
        guard DocKitRecording.valid else {
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !DocKitRecording.requested
    }
}

@main
struct DocToolsApp: App {
    @NSApplicationDelegateAdaptor(DocKitAppDelegate.self) private var appDelegate

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

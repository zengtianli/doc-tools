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

@main
struct DocToolsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
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

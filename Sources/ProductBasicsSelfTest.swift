import AppKit
import SwiftUI

/// Executed by the candidate's own binary after the fixed acceptor re-identifies a private copy.
/// Builds the real settings window and ContentView, calls their actual action targets, never orders a window in.
@MainActor
final class ProductBasicsSelfTest: NSObject, NSApplicationDelegate {
    private var checks: [String: Bool] = [:]
    private var screenshots: [String] = []
    private var window: NSWindow?
    private var error: String?

    static func runAndExit() -> Never {
        guard Lifecycle.isolated, let store = Lifecycle.store(),
              store.domain == Bundle.main.bundleIdentifier,
              store.domain.hasPrefix(Lifecycle.productID + ".ProductBasics.") else {
            fputs("Product basics self-test requires a re-identified private bundle and isolated preferences/support/cloud.\n", stderr)
            exit(64)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let test = ProductBasicsSelfTest()
        application.delegate = test
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { test.error = "offscreen self-test timeout"; test.finish() }
        application.run()
        exit(1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { @MainActor in await run() } }
    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
    private func dispatch(_ control: NSControl) -> Bool {
        guard let action = control.action else { return false }
        return NSApp.sendAction(action, to: control.target, from: control)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func rowSwitch(_ title: String) -> NSSwitch? {
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            for row in descendants(root).compactMap({ $0 as? NSStackView }) where row.orientation == .horizontal {
                let nodes = descendants(row)
                if nodes.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == title }),
                   let toggle = nodes.compactMap({ $0 as? NSSwitch }).first { return toggle }
            }
        }
        return nil
    }
    private func texts() -> [String] {
        NSApp.windows.compactMap(\.contentView).flatMap(descendants).compactMap { ($0 as? NSTextField)?.stringValue }
    }
    private func run() async {
        do {
            let store = Lifecycle.store()!
            let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOP_OUT_DIR"]!)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            NSApp.mainMenu = NSMenu()
            let configuration = Lifecycle.installApp(store.defaults)
            let settings = DocKitSettings.current!
            settings.attachMenu()
            let model = AppViewModel(preferences: store.defaults)
            await model.loadOps()
            let view = NSHostingView(rootView: ContentView(vm: model, autoLoad: false).preferredColorScheme(.light))
            let main = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1060, height: 760),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            main.isReleasedWhenClosed = false; main.contentView = view; window = main
            view.layoutSubtreeIfNeeded()
            for (name, appearance) in [("settings-light", NSAppearance.Name.aqua), ("settings-dark", .darkAqua)] {
                let shot = out.appendingPathComponent(name + ".png")
                let captured = try AppLifecycleUI.shared.offscreenSnapshot(to: shot, appearance: appearance)
                for (key, passed) in captured { checks["settings." + name + "." + key] = passed }
                screenshots.append(shot.path)
            }
            settings.keyField.stringValue = "t"; settings.modifiers.selectItem(at: 1)
            checks["settings.actual_save_control"] = dispatch(settings.applyButton)
                && settings.shortcuts.binding.key == "t" && settings.shortcuts.binding.modifiers == [.command, .shift]
                && store.defaults.dictionary(forKey: AppShortcuts.bindingKey)?["key"] as? String == "t"
            let saved = settings.shortcuts.binding.dictionary as NSDictionary
            settings.keyField.stringValue = DocKitSettings.paletteKey; settings.modifiers.selectItem(at: 0)
            _ = dispatch(settings.applyButton)
            let duplicateRefused = saved.isEqual(to: settings.shortcuts.binding.dictionary) && settings.status.stringValue.contains("已用于搜索")
            settings.keyField.stringValue = "q"
            _ = dispatch(settings.applyButton)
            checks["shortcuts.ui_reserved_and_palette_conflicts"] = duplicateRefused
                && saved.isEqual(to: settings.shortcuts.binding.dictionary) && settings.status.stringValue.contains("保留")
            settings.refresh()
            settings.enabledToggle.state = .off
            let disabled = dispatch(settings.enabledToggle) && !settings.shortcuts.enabled && settings.shortcuts.menuItem?.keyEquivalent == ""
            settings.enabledToggle.state = .on
            checks["shortcuts.ui_disable_restore"] = dispatch(settings.enabledToggle) && disabled && settings.shortcuts.enabled
                && settings.shortcuts.menuItem?.keyEquivalent == "t" && saved.isEqual(to: settings.shortcuts.binding.dictionary)
            model.ops = []
            let item = settings.shortcuts.menuItem!
            let sent = NSApp.sendAction(item.action!, to: item.target, from: item)
            let loaded = await wait { !model.ops.isEmpty && !model.isLoadingOps }
            checks["shortcuts.actual_menu_to_content_view_refresh"] = sent && loaded && model.ops.count >= 9
            if let toggle = rowSwitch("使用 iCloud 记住配置") {
                toggle.state = .on
                let sent = dispatch(toggle)
                let cloud = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APP_LIFECYCLE_CLOUD_DIR"]!).appendingPathComponent(Lifecycle.productID + ".json")
                let pushed = await wait { FileManager.default.fileExists(atPath: cloud.path) }
                toggle.state = .off
                checks["icloud.actual_window_switch"] = dispatch(toggle) && sent && pushed && !configuration.enabled
                    && FileManager.default.fileExists(atPath: cloud.path)
            } else { checks["icloud.actual_window_switch"] = false }
            if let toggle = rowSwitch("自动检查更新") {
                toggle.state = .on
                checks["updates.actual_options_control"] = dispatch(toggle)
                    && AppUpdatePreferences.options(store.domain).automaticCheck
            } else { checks["updates.actual_options_control"] = false }
            // The same method called by the actual check button, using its existing non-presenting mode.
            AppLifecycleUI.shared.checkForUpdates(present: false)
            checks["updates.actual_check_in_settings"] = await wait { texts().contains(where: { $0.contains("有新版") }) }
            let shot = out.appendingPathComponent("settings-updates.png")
            _ = try AppLifecycleUI.shared.offscreenSnapshot(to: shot, showingUpdateOptions: true)
            screenshots.append(shot.path)
            checks["settings.never_visible_active_or_dock"] = NSApp.activationPolicy() == .prohibited && !NSApp.isActive
                && NSApp.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow }
            main.close()
            checks["settings.actual_close"] = !main.isVisible
        } catch { self.error = error.localizedDescription }
        finish()
    }
    private func finish() -> Never {
        if error != nil { checks["settings.execution_completed"] = false }
        let result: [String: Any] = ["checks": checks, "screenshots": screenshots, "error": error ?? "",
                                     "scope": "real private copy, prohibited activation, actual AppKit/SwiftUI controls and action paths"]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        exit(error == nil && !checks.isEmpty && checks.values.allSatisfy { $0 } ? 0 : 1)
    }
}

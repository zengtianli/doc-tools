import AppKit

/// Product controls and action routing; persistence, key validation and menu binding use AppShortcuts.
@MainActor
final class DocKitSettings: NSObject {
    static var current: DocKitSettings?
    static let paletteKey = "k"
    let shortcuts: AppShortcuts
    let enabledToggle = NSSwitch()
    let keyField = NSTextField(string: "")
    let modifiers = NSPopUpButton()
    let applyButton = NSButton(title: "保存快捷键", target: nil, action: nil)
    let status = AppLifecycleUI.detailLabel()
    private var observer: NSObjectProtocol?
    private let choices: [(String, NSEvent.ModifierFlags)] = [
        ("⌘", .command), ("⇧⌘", [.shift, .command]),
        ("⌥⌘", [.option, .command]), ("⌃⌘", [.control, .command])
    ]

    init(defaults: UserDefaults) {
        shortcuts = AppShortcuts(defaults: defaults) {
            NotificationCenter.default.post(name: .consoleRefresh, object: nil)
        }
        super.init()
        enabledToggle.target = self; enabledToggle.action = #selector(toggleEnabled)
        modifiers.addItems(withTitles: choices.map(\.0))
        keyField.placeholderString = "字母或数字"; keyField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        applyButton.target = self; applyButton.action = #selector(saveBinding)
        refresh()
    }

    func install() {
        Self.current = self
        AppLifecycleUI.shared.productGroups = { [weak self] in self.map { [$0.group()] } ?? [] }
        AppLifecycleUI.shared.willShow = { [weak self] in self?.refresh() }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.attachMenu() }
        }
    }

    func attachMenu() {
        shortcuts.installMenu()
        guard let menu = shortcuts.menuItem?.menu, !menu.items.contains(where: { $0.action == #selector(openPalette) }) else { return }
        let search = NSMenuItem(title: "搜索功能…", action: #selector(openPalette), keyEquivalent: Self.paletteKey)
        search.keyEquivalentModifierMask = .command; search.target = self
        menu.insertItem(search, at: 0)
    }

    @objc func openPalette() { NotificationCenter.default.post(name: .tlPaletteToggle, object: nil) }
    @objc func toggleEnabled() { shortcuts.setEnabled(enabledToggle.state == .on); refresh() }
    @objc func saveBinding() {
        do {
            try setBinding(key: keyField.stringValue.lowercased(), modifiers: choices[max(0, modifiers.indexOfSelectedItem)].1)
            refresh()
        } catch { status.stringValue = error.localizedDescription + " 原设置保留。" }
    }
    func setBinding(key: String, modifiers: NSEvent.ModifierFlags) throws {
        guard !(key.lowercased() == Self.paletteKey && modifiers == .command) else {
            throw AppUpdateError("⌘K 已用于搜索功能，请选择其他快捷键。")
        }
        try shortcuts.setBinding(.init(key: key, modifiers: modifiers))
    }
    func refresh() {
        shortcuts.refresh()
        enabledToggle.state = shortcuts.enabled ? .on : .off
        keyField.stringValue = shortcuts.binding.key
        modifiers.selectItem(at: choices.firstIndex(where: { $0.1 == shortcuts.binding.modifiers }) ?? 0)
        status.stringValue = shortcuts.descriptionText + "；⌘K 搜索，⌘↩ 执行；⌘Q/W/C/V 等系统与编辑快捷键保留。"
    }
    private func group() -> NSView {
        let editor = NSStackView(views: [modifiers, keyField, applyButton]); editor.spacing = 6
        return AppLifecycleUI.group("快捷键", rows: [
            AppLifecycleUI.row("启用刷新快捷键", detail: status, accessory: enabledToggle),
            AppLifecycleUI.row("刷新组合", detail: AppLifecycleUI.detailLabel("关闭只取消按键绑定，菜单和按钮仍可使用；只在 DocKit 内生效。"), accessory: editor)
        ])
    }
}

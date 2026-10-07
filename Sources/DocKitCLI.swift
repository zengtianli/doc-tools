import AppKit
import SwiftUI

// =============================================================================
// DocKitCLI — command words answered by the app executable itself.
//
//   DocKit.app/Contents/MacOS/DocTools status [--json]
//   DocKit.app/Contents/MacOS/DocTools settings [--json]
//   DocKit.app/Contents/MacOS/DocTools settings set <key> <value> [--json]
//   DocKit.app/Contents/MacOS/DocTools config status | export | import | sync
//   DocKit.app/Contents/MacOS/DocTools update check
//   DocKit.app/Contents/MacOS/DocTools help
//
// The window is for a person; these words let a script or an agent read and
// change the same things without it. Every word is answered before any
// NSApplication exists: no window, no Dock icon, no focus change, no prompt.
// A copy of the app that is already running is left alone.
//
//   · `status` loads the operation catalog through the same AppViewModel the
//     window uses, so its sentence is the window's status line.
//   · `settings` reads and writes the two preference keys the window
//     remembers (AppViewModel.portablePreferenceKeys), nothing else.
//   · `config` and `update` are the five items of the「配置与更新…」window,
//     run by the shared layer (AppLifecycleCLI.swift) on the configuration
//     and update source built by `Lifecycle` below — the window's own.
// =============================================================================

/// One factory for what the「配置与更新…」window and the `config` / `update` words work on.
@MainActor
enum Lifecycle {
    static let name = "DocKit"
    static let productID = "io.github.zengtianli.DocTools"
    static let updateSource: AppUpdateSource = .github(repository: "zengtianli/doc-tools")
    static let probeFlag = "--lifecycle-follow-probe"
    static let suiteVariable = "DOCKIT_LIFECYCLE_SUITE"
    static let refusal = "APP_LIFECYCLE_SUPPORT_DIR is set (an isolated run): \(suiteVariable) must name a throwaway preferences domain too, so the run never reaches your own settings."

    static var isolated: Bool { ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil }

    /// The app bundle these words belong to. Started through a symbolic link, `Bundle.main` has no
    /// Info.plist; the link is resolved so version, build and bundle identifier are still the app's.
    static let bundle: Bundle = {
        if Bundle.main.bundleIdentifier != nil { return .main }
        guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return .main }
        for _ in 0..<3 { url.deleteLastPathComponent() }   // Contents/MacOS/DocTools → DocKit.app
        return (url.pathExtension == "app" ? Bundle(url: url) : nil) ?? .main
    }()

    /// The preferences the window remembers its settings in, and their domain name.
    /// An isolated run (tests) must name its own throwaway domain; nil when it does not.
    static func store() -> (defaults: UserDefaults, domain: String)? {
        guard isolated else {
            if Bundle.main.bundleIdentifier == productID { return (.standard, productID) }
            // Started outside the bundle (a link, a bare build product): name the domain instead of
            // falling into the launcher's own.
            return UserDefaults(suiteName: productID).map { ($0, productID) }
        }
        guard let suite = ProcessInfo.processInfo.environment[suiteVariable], !suite.isEmpty, suite != productID,
              let defaults = UserDefaults(suiteName: suite) else { return nil }
        return (defaults, suite)
    }

    static func makeConfiguration(_ defaults: UserDefaults) -> AppConfiguration {
        AppConfiguration(productID: productID, defaultsKeys: AppViewModel.portablePreferenceKeys, defaults: defaults)
    }

    static func product(_ defaults: UserDefaults) -> AppLifecycleCLI.Product {
        AppLifecycleCLI.Product(command: DocKitCLI.name, name: name, configuration: makeConfiguration(defaults),
                                updateSource: updateSource, bundle: bundle)
    }

    /// The app side, in one place: the window, the reload signal the views listen to, and the follower
    /// that lets a running window keep up with `config sync` / `config import` typed in another process.
    /// The follower never stores the switch; only the command and the window's own switch write it.
    @discardableResult
    static func installApp(_ defaults: UserDefaults = .standard) -> AppConfiguration {
        let configuration = makeConfiguration(defaults)
        configuration.onChange = {
            NotificationCenter.default.post(name: .dockitPreferencesChanged, object: nil)
        }
        AppLifecycleUI.install(name: name, configuration: configuration, updateSource: updateSource)
        AppLifecycleCLI.follow(configuration, bundle: bundle)
        return configuration
    }
}

@MainActor
enum DocKitCLI {
    /// How the command is typed, for usage lines and `check_with`. A wrapper that forwards to this
    /// executable under another name says so in DOCKIT_CLI_NAME.
    nonisolated static let name: String = {
        if let given = ProcessInfo.processInfo.environment["DOCKIT_CLI_NAME"], !given.isEmpty { return given }
        return "DocTools"
    }()

    nonisolated private static let own = ["status", "settings", "help", "--help", "-h"]
    nonisolated static func handles(_ word: String?) -> Bool {
        guard let word else { return false }
        return own.contains(word) || AppLifecycleCLI.handles(word)
    }

    static var help: String {
        """
        usage: \(name) <command> [--json]
        DocKit 的命令入口：不打开窗口、不进 Dock、不抢焦点，与窗口读写同一份设置。已在运行的 DocKit 不受打扰。
        处理文档仍在窗口里做；这里是版本、状态、记住的设置，以及「\(AppLifecycleCLI.defaultWindowEntry)」窗口里的几项。

        读命令（不写任何文件或状态）:
          status                     版本与构建号、状态行（已就绪 / 文档引擎未就绪）、记住的上次操作与各操作的目标格式、窗口是否在运行
          settings                   记住的上次操作与各操作的目标格式
        \(AppLifecycleCLI.helpRead(name))

        写命令:
          settings set <键> <值>      改记住的设置：last_operation <op> 或 target_formats.<op> <目标>；值先按操作目录核对，窗口下次打开时按它选中
        \(AppLifecycleCLI.helpWrite(name))

        --json 输出形状（每条命令一个 JSON 对象）:
          status        {"ok":true,"command":"status","app":{name,bundle_id,version,build,path},
                         "engine":{ready,operations,status_line,error},"settings":{last_operation,target_formats},"app_running"}
          settings      {"ok":true,"command":"settings","domain","settings":{"last_operation":op|null,"target_formats":{op:目标}}}
                        settings set 另带 "changed":{key,from,to}
          config / update 见 \(name) config --help
          失败          {"ok":false,"command":…,"error":{"code":"稳定短码","message":"给人看的原因"}}，退出码非零

        退出码:
          0  成功（status 读到「文档引擎未就绪」也算成功，看 engine.ready）
          1  操作未完成：engine_unavailable（文档引擎没有答复，无法核对设置值）· not_written（设置没有写进去）·
             isolation_incomplete（隔离运行缺 \(Lifecycle.suiteVariable)）；config / update 的见 \(name) config --help
          2  用法错误：usage（参数不对）· unknown_setting · unknown_operation · unknown_target；
             config / update 另有 confirmation_required、file_exists

        仅在窗口中：\(AppLifecycleCLI.helpWindowOnly)；选文件、拖入文件、执行操作、查看结果
        暂无命令：\(AppLifecycleCLI.helpNoCommand)
        """
    }

    /// `words` starts at the command word. Returns the exit code.
    static func run(_ words: [String]) -> Int32 {
        let json = words.contains("--json")
        guard let verb = words.first else { return 2 }
        if ["help", "--help", "-h"].contains(verb) { emit(help); return 0 }
        guard let store = Lifecycle.store() else {
            let command = words.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: " ")
            return fail(Failure(exit: 1, code: "isolation_incomplete", message: Lifecycle.refusal), command: command, json: json)
        }
        if AppLifecycleCLI.handles(verb) {
            return AppLifecycleCLI.run(words, product: Lifecycle.product(store.defaults))
        }
        var command = verb
        do {
            let rest = Array(words.dropFirst())
            if rest.contains("--help") || rest.contains("-h") { emit(help); return 0 }
            let positionals = rest.filter { !$0.hasPrefix("-") }
            if let unknown = rest.first(where: { $0.hasPrefix("-") && $0 != "--json" }) {
                throw Failure.usage("未知参数 \(unknown)")
            }
            let body: [String: Any], text: String
            switch (verb, positionals.first) {
            case ("status", nil):
                (body, text) = status(store)
            case ("settings", nil):
                let settings = remembered(store.defaults)
                body = ["domain": store.domain, "settings": settings]
                text = sentence(settings)
            case ("settings", "set"?):
                command = "settings set"
                guard positionals.count == 3 else { throw Failure.usage("用法：\(name) settings set last_operation <op> | target_formats.<op> <目标>") }
                (body, text) = try set(positionals[1], positionals[2], store)
            default:
                throw Failure.usage("用法：\(name) status | settings | settings set <键> <值> | config … | update check（都可加 --json；\(name) help 看全部）")
            }
            if json {
                var out = body
                out["ok"] = true; out["command"] = command
                emit(Self.json(out))
            } else { emit(text) }
            return 0
        } catch let failure as Failure {
            return fail(failure, command: command, json: json)
        } catch {
            return fail(Failure(exit: 1, code: "failed", message: error.localizedDescription), command: command, json: json)
        }
    }

    // MARK: status

    private static func status(_ store: (defaults: UserDefaults, domain: String)) -> ([String: Any], String) {
        let bundle = Lifecycle.bundle
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let identifier = bundle.bundleIdentifier ?? ""
        let engine = loadCatalog(seconds: 12)
        let ready = engine.finished && !engine.model.ops.isEmpty && engine.model.banner?.kind != .error
        let line = engine.finished ? engine.model.statusText : "文档引擎 12 秒内没有答复。"
        let problem: Any = ready ? NSNull() : (engine.model.banner?.text ?? line)
        let settings = remembered(store.defaults)
        let running = isRunning(identifier)
        let body: [String: Any] = [
            "app": ["name": Lifecycle.name, "bundle_id": identifier, "version": version, "build": build, "path": bundle.bundlePath],
            "engine": ["ready": ready, "operations": engine.model.ops.count, "status_line": line, "error": problem],
            "settings": settings, "app_running": running,
        ]
        let text = """
        \(Lifecycle.name) \(version) (\(build)) · \(identifier) · \(bundle.bundlePath)
        状态行：\(line)\(ready ? "" : "\n\(problem)")
        \(sentence(settings))
        窗口：\(running ? "正在运行" : "未在运行")
        """
        return (body, text)
    }

    /// The catalog load behind the window's status line: the same view model, the same backend call.
    /// It keeps no preferences and writes nothing.
    private static func loadCatalog(seconds: TimeInterval) -> (model: AppViewModel, finished: Bool) {
        final class Flag { var done = false }
        let model = AppViewModel(usesPortablePreferences: false)
        let flag = Flag()
        let task = Task { @MainActor in
            await model.loadOps()
            flag.done = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !flag.done && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if !flag.done {
            task.cancel()   // ends the backend process; nothing is left running behind the command
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return (model, flag.done)
    }

    private static func isRunning(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0.processIdentifier != own }
    }

    // MARK: settings

    private static func remembered(_ defaults: UserDefaults) -> [String: Any] {
        defaults.synchronize()
        let keys = AppViewModel.portablePreferenceKeys
        return ["last_operation": defaults.string(forKey: keys[0]) ?? NSNull(),
                "target_formats": (defaults.dictionary(forKey: keys[1]) as? [String: String]) ?? [:]]
    }

    private static func sentence(_ settings: [String: Any]) -> String {
        let operation = settings["last_operation"] as? String ?? "（还没有）"
        let formats = (settings["target_formats"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "记住的上次操作：\(operation)；各操作的目标格式：\(formats.isEmpty ? "（还没有）" : formats)"
    }

    private static func set(_ key: String, _ value: String, _ store: (defaults: UserDefaults, domain: String)) throws -> ([String: Any], String) {
        let prefix = "target_formats."
        guard key == "last_operation" || (key.hasPrefix(prefix) && key.count > prefix.count) else {
            throw Failure(exit: 2, code: "unknown_setting", message: "没有设置项 \(key)：可改 last_operation 或 target_formats.<op>")
        }
        // Values are checked against the catalog the window would offer, before anything is written.
        let engine = loadCatalog(seconds: 20)
        guard engine.finished, !engine.model.ops.isEmpty else {
            throw Failure(exit: 1, code: "engine_unavailable", message: "文档引擎没有答复，无法核对设置值；设置未改。" + (engine.model.banner.map { " " + $0.text } ?? ""))
        }
        let catalog = engine.model.ops
        let defaults = store.defaults, keys = AppViewModel.portablePreferenceKeys
        defaults.synchronize()
        let before: Any, after: Any
        if key == "last_operation" {
            guard catalog.contains(where: { $0.id == value }) else {
                throw Failure(exit: 2, code: "unknown_operation", message: "没有操作 \(value)：可选 " + catalog.map(\.id).joined(separator: " "))
            }
            before = defaults.string(forKey: keys[0]) ?? NSNull()
            defaults.set(value, forKey: keys[0])
            defaults.synchronize()
            guard defaults.string(forKey: keys[0]) == value else { throw Failure(exit: 1, code: "not_written", message: "设置没有写进去") }
            after = value
        } else {
            let operation = String(key.dropFirst(prefix.count))
            guard let op = catalog.first(where: { $0.id == operation }) else {
                throw Failure(exit: 2, code: "unknown_operation", message: "没有操作 \(operation)：可选 " + catalog.map(\.id).joined(separator: " "))
            }
            guard op.targets.contains(where: { $0.id == value }) else {
                let choices = op.targets.map(\.id).joined(separator: " ")
                throw Failure(exit: 2, code: "unknown_target", message: op.targets.isEmpty ? "操作 \(operation) 没有目标格式可选" : "操作 \(operation) 没有目标 \(value)：可选 \(choices)")
            }
            var formats = defaults.dictionary(forKey: keys[1]) as? [String: String] ?? [:]
            before = formats[operation] ?? NSNull()
            formats[operation] = value
            defaults.set(formats, forKey: keys[1])
            defaults.synchronize()
            guard (defaults.dictionary(forKey: keys[1]) as? [String: String])?[operation] == value else {
                throw Failure(exit: 1, code: "not_written", message: "设置没有写进去")
            }
            after = value
        }
        let settings = remembered(defaults)
        return (["domain": store.domain, "settings": settings, "changed": ["key": key, "from": before, "to": after]],
                "已改 \(key)：\(before is NSNull ? "（空）" : "\(before)") → \(after)。窗口下次打开时按它选中。\n" + sentence(settings))
    }

    // MARK: plumbing

    private struct Failure: Error {
        let exit: Int32, code: String, message: String
        static func usage(_ message: String) -> Failure { Failure(exit: 2, code: "usage", message: message) }
    }

    private static func fail(_ failure: Failure, command: String, json: Bool) -> Int32 {
        if json {
            emit(Self.json(["ok": false, "command": command, "error": ["code": failure.code, "message": failure.message]]))
        } else {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
        }
        return failure.exit
    }

    private static func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    private static func json(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]))
            ?? Data("{\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - The running app, for the lifecycle test only

/// `--lifecycle-follow-probe <state file>`: this executable as the running app of tests/test_lifecycle_cli.py.
/// Accepted only in an isolated run (APP_LIFECYCLE_SUPPORT_DIR and a throwaway preferences domain). It installs
/// the production wiring (`Lifecycle.installApp`), hosts the real ContentView and builds the shared window, all
/// without ordering anything in: activation policy `.prohibited`, so no Dock icon, no menu bar, no focus.
/// What the configuration, the window's switch and the view model hold is written to the state file for the test.
@MainActor
enum LifecycleProbe {
    private static var keep: [Any] = []
    private static var write: (() -> Void)?

    static func run(_ path: String, defaults: UserDefaults) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let state = URL(fileURLWithPath: path)
        let configuration = Lifecycle.installApp(defaults)
        var changes = 0
        keep.append(NotificationCenter.default.addObserver(forName: .dockitPreferencesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changes += 1 }
        })
        let model = AppViewModel(preferences: defaults)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1060, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(vm: model))
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
        window.contentView = host
        host.layoutSubtreeIfNeeded()   // never ordered in: the view is live, the window stays off every screen
        keep.append(window)
        DispatchQueue.main.async {
            let built: [String: Bool]
            do { built = try AppLifecycleUI.shared.offscreenSnapshot(to: state.deletingPathExtension().appendingPathExtension("png")) }
            catch { FileHandle.standardError.write(Data("lifecycle window: \(error.localizedDescription)\n".utf8)); exit(1) }
            let control = NSApp.windows.lazy.filter { $0 !== window }.compactMap { cloudSwitch(in: $0.contentView) }.first
            var tick = 0
            write = {
                tick += 1
                let shown = (control as? NSButton)?.state ?? (control as? NSSwitch)?.state
                let seen: [String: Any] = [
                    "enabled": configuration.enabled, "status": configuration.status, "changes": changes, "tick": tick,
                    "window_switch": shown.map { $0 == .on } ?? NSNull(), "window_built": built,
                    "windows_on_screen": NSApp.windows.filter(\.isVisible).count,
                    "policy_prohibited": NSApp.activationPolicy() == .prohibited, "active": NSApp.isActive,
                    "operations": model.ops.count, "selected_operation": model.selectedOpID ?? NSNull(),
                    "selected_target": model.selectedTargetID ?? NSNull(), "status_line": model.statusText,
                ]
                try? JSONSerialization.data(withJSONObject: seen, options: [.sortedKeys]).write(to: state, options: .atomic)
            }
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { write?() } }
        }
        application.run()
        exit(0)
    }

    /// The「使用 iCloud 记住配置」control of the shared window: a checkbox in older copies, a switch in newer ones.
    private static func cloudSwitch(in view: NSView?) -> NSControl? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == "使用 iCloud 记住配置" { return button }
        if let toggle = view as? NSSwitch { return toggle }
        for child in view.subviews { if let found = cloudSwitch(in: child) { return found } }
        return nil
    }
}

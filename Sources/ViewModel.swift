import Foundation
import SwiftUI


struct BannerMsg: Equatable {
    enum Kind { case error, warning, info }
    var kind: Kind
    var text: String

    static func error(_ t: String) -> BannerMsg { .init(kind: .error, text: t) }
    static func warning(_ t: String) -> BannerMsg { .init(kind: .warning, text: t) }
    static func info(_ t: String) -> BannerMsg { .init(kind: .info, text: t) }
}

struct InputFile: Identifiable, Hashable {
    let id: String         // = path（去重键）
    var path: String { id }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isDir: Bool {
        var d: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &d)
        return d.boolValue
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var banner: BannerMsg?
    @Published var isLoadingOps = false
    @Published var isRunning = false {
        didSet { if !isRunning && pendingPreferenceRestore { reloadPortablePreferences() } }
    }

    @Published var ops: [DocOp] = []
    @Published var selectedOpID: String?
    @Published var selectedTargetID: String? {
        didSet { rememberTarget() }
    }

    @Published var optionValues: [String: Bool] = [:]

    @Published var optionPaths: [String: String] = [:]

    @Published var files: [InputFile] = []
    @Published var results: [FileResult] = []
    @Published var lastLog: String = ""
    @Published var summary: String = ""          // "成功 N/M" 之类
    @Published var statusText: String = "拖入文件或点「选择文件」，再挑一个操作。"

    private let backend: BackendClient
    static let portablePreferenceKeys = ["dockit.lastOperation", "dockit.targetFormats"]
    private let preferences: UserDefaults?
    private var restoringPreferences = false
    private var preferencesLoaded = false
    private var pendingPreferenceRestore = false

    init(backend: BackendClient = BackendClient(), preferences: UserDefaults? = nil,
         usesPortablePreferences: Bool = true) {
        self.backend = backend
        self.preferences = usesPortablePreferences ? (preferences ?? Self.runtimePreferences) : nil
    }

    private static var runtimePreferences: UserDefaults? {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "io.github.zengtianli.DocTools",
              !CommandLine.arguments.contains("--ui-self-test"),
              environment["DOCKIT_BACKGROUND"] != "1", environment["DOCKIT_DEMO_OP"] == nil else { return nil }
        return .standard
    }

    func reloadPortablePreferences() {
        guard let preferences else { return }
        pendingPreferenceRestore = true
        guard !isRunning, !isLoadingOps, !ops.isEmpty else { return }
        restoringPreferences = true
        defer { restoringPreferences = false; pendingPreferenceRestore = false }
        if let operation = preferences.string(forKey: Self.portablePreferenceKeys[0]),
           ops.contains(where: { $0.id == operation }) { selectedOpID = operation }
        syncTargetDefault()
        resetOptionsToDefaults()
    }

    private func rememberTarget() {
        guard !restoringPreferences, let preferences, let op = selectedOp, op.needsTarget,
              let target = selectedTargetID, op.targets.contains(where: { $0.id == target }) else { return }
        var formats = preferences.dictionary(forKey: Self.portablePreferenceKeys[1]) as? [String: String] ?? [:]
        formats[op.id] = target
        preferences.set(formats, forKey: Self.portablePreferenceKeys[1])
    }

    var selectedOp: DocOp? { ops.first { $0.id == selectedOpID } }

    var canRun: Bool {
        guard let op = selectedOp, !isRunning, !files.isEmpty else { return false }
        if op.needsTarget && (selectedTargetID?.isEmpty ?? true) { return false }
        for o in op.options where o.required {
            let filled = o.isFile ? !(optionPaths[o.id] ?? "").isEmpty : true
            if !filled { return false }
        }
        return true
    }


    func loadOps() async {
        guard !isRunning, !isLoadingOps else { return }
        isLoadingOps = true
        defer {
            isLoadingOps = false
            if !preferencesLoaded || pendingPreferenceRestore {
                reloadPortablePreferences()
                preferencesLoaded = true
            }
        }
        do {
            let r = try await backend.ops()
            ops = r.ops
            if !ops.contains(where: { $0.id == selectedOpID }) { selectedOpID = ops.first?.id }
            syncTargetDefault()
            if banner?.kind == .error { banner = nil }
            statusText = "已就绪 · 共 \(ops.count) 个操作。拖入文件开始。"
        } catch is CancellationError {
        } catch {
            banner = .error("加载操作列表失败：\(error.localizedDescription)")
            statusText = "文档引擎未就绪，请重新打开或重新下载 DocKit。"
        }
    }

    func onOpChanged() {
        results = []; lastLog = ""; summary = ""
        syncTargetDefault()
        resetOptionsToDefaults()
        if !restoringPreferences, let op = selectedOp {
            preferences?.set(op.id, forKey: Self.portablePreferenceKeys[0])
            rememberTarget()
        }
    }

    func resetOptionsToDefaults() {
        guard !isRunning else { return }
        guard let op = selectedOp else { optionValues = [:]; optionPaths = [:]; return }
        optionValues = Dictionary(uniqueKeysWithValues:
            op.options.filter { !$0.isFile }.map { ($0.id, $0.defaultOn) })
        optionPaths = [:]
    }

    var changedOptions: [String: String] {
        guard let op = selectedOp else { return [:] }
        var out: [String: String] = [:]
        for o in op.options {
            if o.isFile {
                let p = optionPaths[o.id] ?? ""
                if !p.isEmpty { out[o.id] = p }
            } else if let v = optionValues[o.id], v != o.defaultOn {
                out[o.id] = v ? "1" : "0"
            }
        }
        return out
    }

    private func syncTargetDefault() {
        guard let op = selectedOp, op.needsTarget else { selectedTargetID = nil; return }
        let saved = (preferences?.dictionary(forKey: Self.portablePreferenceKeys[1]) as? [String: String])?[op.id]
        let target = saved.flatMap { id in op.targets.contains(where: { $0.id == id }) ? id : nil }
            ?? (op.targets.contains(where: { $0.id == selectedTargetID }) ? selectedTargetID : op.targets.first?.id)
        let wasRestoring = restoringPreferences
        restoringPreferences = true
        selectedTargetID = target
        restoringPreferences = wasRestoring
    }


    func addPaths(_ paths: [String]) {
        guard !isRunning else { return }
        var seen = Set(files.map(\.id))
        for p in paths where !seen.contains(p) {
            files.append(InputFile(id: p)); seen.insert(p)
        }
        results = []; summary = ""
        statusText = "\(files.count) 个待处理。"
    }

    func remove(_ f: InputFile) {
        guard !isRunning else { return }
        files.removeAll { $0.id == f.id }
        statusText = files.isEmpty ? "已清空。" : "\(files.count) 个待处理。"
    }

    func clearFiles() {
        guard !isRunning else { return }
        files = []; results = []; lastLog = ""; summary = ""
        statusText = "已清空。拖入文件或点「选择文件」。"
    }


    func run() async {
        guard canRun, let op = selectedOp else { return }
        isRunning = true
        defer { isRunning = false }
        results = []; summary = ""; lastLog = ""
        statusText = "正在执行「\(op.title)」…"
        let target = op.needsTarget ? selectedTargetID : nil
        let paths = files.map(\.path)
        do {
            let r = try await backend.run(op: op.id, target: target,
                                          options: changedOptions, files: paths)
            results = r.results
            lastLog = r.log
            if op.wantsDir {
                summary = r.results.first?.ok == true ? "扫描完成" : "扫描出错"
            } else {
                summary = "成功 \(r.succeeded)/\(r.total)"
                if !r.skippedMissing.isEmpty {
                    summary += " · 跳过不存在 \(r.skippedMissing.count)"
                }
            }
            statusText = summary
            banner = nil
        } catch is CancellationError {
            statusText = "已取消。"
        } catch {
            banner = .error("执行失败：\(error.localizedDescription)")
            statusText = "执行失败（详见上方 banner）。"
        }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

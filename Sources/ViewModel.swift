import Foundation
import SwiftUI

// =============================================================================
// DocTools — ViewModel
//
// Shape rules:
//   · @MainActor ObservableObject; every backend call is async and errors go
//     into the banner (human-readable) — no alerts, no print-and-forget. The
//     detail root keeps a permanent StatusBanner slot so errors are visible
//     even with nothing selected.
//   · One independent @Published busy flag per action: isLoadingOps (listing
//     operations at startup) and isRunning (running an operation).
//   · Zero business logic in Swift: drop files → pick an operation → call the
//     backend → show results. Everything else is doc_gui_backend.py's job.
// =============================================================================

/// Persistent status/error banner (one at the detail root, visible even with
/// no selection).
struct BannerMsg: Equatable {
    enum Kind { case error, warning, info }
    var kind: Kind
    var text: String

    static func error(_ t: String) -> BannerMsg { .init(kind: .error, text: t) }
    static func warning(_ t: String) -> BannerMsg { .init(kind: .warning, text: t) }
    static func info(_ t: String) -> BannerMsg { .init(kind: .info, text: t) }
}

/// One dropped/picked file entry (deduplicated by absolute path).
struct InputFile: Identifiable, Hashable {
    let id: String         // = path (dedup key)
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
    @Published var isRunning = false

    @Published var ops: [DocOp] = []
    @Published var selectedOpID: String?
    @Published var selectedTargetID: String?     // convert only

    @Published var files: [InputFile] = []
    @Published var results: [FileResult] = []
    @Published var lastLog: String = ""
    @Published var summary: String = ""          // e.g. "成功 N/M"
    @Published var statusText: String = "拖入文件或点「选择文件」，再挑一个操作。"

    private let backend = BackendClient()

    var selectedOp: DocOp? { ops.first { $0.id == selectedOpID } }

    var canRun: Bool {
        guard let op = selectedOp, !isRunning, !files.isEmpty else { return false }
        if op.needsTarget && (selectedTargetID?.isEmpty ?? true) { return false }
        return true
    }

    // MARK: - Startup: list operations

    func loadOps() async {
        isLoadingOps = true
        defer { isLoadingOps = false }
        do {
            let r = try await backend.ops()
            ops = r.ops
            if selectedOpID == nil { selectedOpID = ops.first?.id }
            syncTargetDefault()
            if banner?.kind == .error { banner = nil }
            statusText = "已就绪 · 共 \(ops.count) 个操作。拖入文件开始。"
        } catch is CancellationError {
        } catch {
            banner = .error("加载操作列表失败：\(error.localizedDescription)")
            statusText = "后端不可达（UI 不崩，先排查 uv / 路径）。"
        }
    }

    /// When the operation changes (e.g. clean → convert), reset the target to
    /// the new operation's first destination format (or clear it).
    func onOpChanged() {
        results = []; lastLog = ""; summary = ""
        syncTargetDefault()
    }

    private func syncTargetDefault() {
        guard let op = selectedOp, op.needsTarget else { selectedTargetID = nil; return }
        if selectedTargetID == nil || !op.targets.contains(where: { $0.id == selectedTargetID }) {
            selectedTargetID = op.targets.first?.id
        }
    }

    // MARK: - Adding / removing files

    func addPaths(_ paths: [String]) {
        var seen = Set(files.map(\.id))
        for p in paths where !seen.contains(p) {
            files.append(InputFile(id: p)); seen.insert(p)
        }
        results = []; summary = ""
        statusText = "\(files.count) 个待处理。"
    }

    func remove(_ f: InputFile) {
        files.removeAll { $0.id == f.id }
        statusText = files.isEmpty ? "已清空。" : "\(files.count) 个待处理。"
    }

    func clearFiles() {
        files = []; results = []; lastLog = ""; summary = ""
        statusText = "已清空。拖入文件或点「选择文件」。"
    }

    // MARK: - Running an operation

    func run() async {
        guard let op = selectedOp, !files.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        results = []; summary = ""; lastLog = ""
        statusText = "正在执行「\(op.title)」…"
        let target = op.needsTarget ? selectedTargetID : nil
        let paths = files.map(\.path)
        do {
            let r = try await backend.run(op: op.id, target: target, files: paths)
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

    /// Reveal an output (file or directory) in Finder.
    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

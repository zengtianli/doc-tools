import SwiftUI
import AppKit

// =============================================================================
// DocTools — ContentView
//
// Design language (native macOS product shape; gotchas are baked in as code):
//   · Zero hard-coded semantic colors: .primary/.secondary/.tertiary +
//     controlBackgroundColor / windowBackgroundColor / separatorColor; the
//     status colors green/orange/red only accent icons and badges.
//   · Cards: RoundedRectangle(10) filled with controlBackgroundColor + 0.5pt
//     separator stroke (card()).
//   · Sidebar uses .listStyle(.sidebar) with List as the root and controls in
//     Sections; actions go in .toolbar; empty state = ContentUnavailableView;
//     code/paths always .monospaced.
//   · [fixedSize(horizontal:false, vertical:true) is banned] The window's
//     minimum-size probe uses a zero-width proposal; fixedSize(v:true) forces
//     long text to wrap character-by-character at zero width — 150 CJK chars
//     or a long command ≈ 2500px minimum height. Summed over all cards the
//     window height locks at thousands of px and the minimum changes with the
//     selection. A nil height proposal lets long text wrap naturally without
//     truncation — fixedSize is simply not needed. Diagnosis hint: check
//     whether the AX `set size` bounce-back value varies with content.
//   · The detail root keeps .frame(minWidth: 600) as a second line of defense
//     against character-wrapping at extreme narrow widths.
// Swift only renders; all business logic is delegated to the Python backend.
// =============================================================================

// MARK: - Shared visual components

/// Card language: RoundedRectangle(10) + controlBackgroundColor + 0.5pt
/// separator stroke.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 13
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 13) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Persistent error/warning/info banner: icon + message + close button.
/// Lives in a permanent slot at the detail root.
struct StatusBanner: View {
    let msg: BannerMsg
    var onClose: () -> Void

    private var color: Color {
        switch msg.kind {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
    private var icon: String {
        switch msg.kind {
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(msg.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("关闭")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showPalette = false   // ⌘K command palette overlay toggle

    var body: some View {
        NavigationSplitView {
            // Sidebar: the operation list (List as the root — do not wrap
            // another container around it outside the SplitView).
            List(selection: $vm.selectedOpID) {
                Section("操作") {
                    ForEach(vm.ops) { op in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(op.title)
                                Text(op.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: op.icon)
                        }
                        .tag(op.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("DocTools")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .overlay {
                if vm.isLoadingOps && vm.ops.isEmpty { ProgressView() }
            }
        } detail: {
            DetailView(vm: vm)
        }
        .task { await vm.loadOps() }
        .onChange(of: vm.selectedOpID) { vm.onOpChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .consoleRefresh)) { _ in
            Task { await vm.loadOps() }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { vm.clearFiles() } label: {
                    Label("清空", systemImage: "trash")
                }
                .help("清空待处理文件")
                .disabled(vm.files.isEmpty || vm.isRunning)
                Button { Task { await vm.loadOps() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重读操作列表（⌘R）")
                .disabled(vm.isLoadingOps)
            }
        }
        // ⌘K command palette: search the app's document operations; Enter
        // switches to that operation (purely additive integration).
        .commandPalette(items: paletteItems, isPresented: $showPalette)
    }

    // MARK: - ⌘K command palette items

    /// Map the backend's operation list (vm.ops) to searchable items;
    /// run = reuse the existing selectedOpID mechanism to switch operations
    /// (equivalent to clicking the sidebar; triggers onOpChanged).
    private var paletteItems: [PaletteItem] {
        vm.ops.map { op in
            PaletteItem(
                id: op.id,
                title: op.title,                 // operation display name
                subtitle: op.subtitle,           // one-line description
                icon: op.icon,                   // the operation's SF Symbol
                keywords: paletteKeywords(for: op)  // english verbs/aliases
            ) {
                // Jump = select the operation (NavigationSplitView sidebar
                // selection), identical to a sidebar click.
                vm.selectedOpID = op.id
            }
        }
    }

    /// English search aliases: backend verb + operation id + a small synonym
    /// dictionary (so typing normalize/convert etc. also matches).
    private func paletteKeywords(for op: DocOp) -> String {
        var words: [String] = [op.verb, op.id]
        // Common english synonyms per verb keyword (harmless when unmatched).
        let dict: [String: String] = [
            "clean":    "normalize clean tidy format 规范化",
            "convert":  "convert transform export 转换",
            "split":    "split divide separate 拆分",
            "merge":    "merge combine join concat 合并",
        ]
        for (key, syns) in dict where op.verb.contains(key) || op.id.contains(key) {
            words.append(syns)
        }
        return words.joined(separator: " ")
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Permanent banner slot: errors stay visible with no selection.
            if let b = vm.banner {
                StatusBanner(msg: b) { vm.banner = nil }
            }
            if let op = vm.selectedOp {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        opHeader(op)
                        DropZone(op: op, vm: vm)
                        if !vm.files.isEmpty { fileListCard(op) }
                        runBar(op)
                        if !vm.results.isEmpty { resultsCard }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                statusLine
            } else {
                ContentUnavailableView(
                    "选择一个操作",
                    systemImage: "sidebar.left",
                    description: Text("从左侧选择规范化 / 转换 / 拆分 / 合并 / 套模板 / 扫描。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        // minWidth backstop: the window's minimum-size probe proposes zero
        // width; long text wrapping character-by-character at extreme narrow
        // widths would blow up the minimum height (fixedSize(v:true) is the
        // amplifier and is banned throughout this codebase).
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(vm.selectedOp?.title ?? "DocTools")
    }

    // MARK: Operation header + target-format picker (convert only)

    private func opHeader(_ op: DocOp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: op.icon).font(.title3).foregroundStyle(.tint)
                Text(op.title).font(.headline)
                Spacer()
                if vm.isRunning { ProgressView().controlSize(.small) }
            }
            Text(op.subtitle).font(.callout).foregroundStyle(.secondary)
            if !op.exts.isEmpty {
                Text("支持源格式：" + op.exts.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if op.needsTarget {
                Divider()
                HStack(spacing: 8) {
                    Text("目标格式").font(.callout)
                    Picker("", selection: Binding(
                        get: { vm.selectedTargetID ?? op.targets.first?.id ?? "" },
                        set: { vm.selectedTargetID = $0 })) {
                        ForEach(op.targets) { t in Text(t.title).tag(t.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()   // short-label segmented control only — safe
                                   // (the ban is on long text with v:true)
                    Spacer()
                }
            }
        }
        .card()
    }

    // MARK: Drop zone / file list

    private func fileListCard(_ op: DocOp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(op.wantsDir ? "待扫描目录" : "待处理文件（\(vm.files.count)）")
                    .font(.subheadline.bold())
                Spacer()
            }
            Divider()
            ForEach(vm.files) { f in
                HStack(spacing: 8) {
                    Image(systemName: f.isDir ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.secondary)
                    Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if !f.ext.isEmpty {
                        Text(f.ext.uppercased())
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    Spacer()
                    Text(f.path).font(.caption.monospaced())
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Button { vm.remove(f) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .card()
    }

    // MARK: Run bar

    private func runBar(_ op: DocOp) -> some View {
        HStack(spacing: 12) {
            Button { pickFiles(op) } label: {
                Label(op.wantsDir ? "选择目录" : "选择文件", systemImage: "plus")
            }
            .disabled(vm.isRunning)
            Spacer()
            if !vm.summary.isEmpty {
                Text(vm.summary).font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await vm.run() } } label: {
                Label(vm.isRunning ? "执行中…" : "执行", systemImage: "play.fill")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canRun)
        }
        .card(padding: 10)
    }

    // MARK: Results

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("结果").font(.headline)
            Divider()
            ForEach(vm.results) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? Color.green : Color.red)
                        Text(r.name).font(.callout.bold())
                        Spacer()
                        Text(r.message).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.tail)
                    }
                    if !r.outputs.isEmpty {
                        ForEach(r.outputs, id: \.self) { out in
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Text((out as NSString).lastPathComponent)
                                    .font(.caption.monospaced())
                                Spacer()
                                Button("在 Finder 显示") { vm.reveal(out) }
                                    .buttonStyle(.link).font(.caption)
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            if !vm.lastLog.isEmpty {
                DisclosureGroup("后端日志") {
                    Text(vm.lastLog)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .card()
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if vm.isRunning { ProgressView().controlSize(.small) }
            Text(vm.statusText)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
    }

    // MARK: File picker

    private func pickFiles(_ op: DocOp) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = !op.wantsDir
        panel.canChooseDirectories = op.wantsDir
        panel.canChooseFiles = !op.wantsDir
        if panel.runModal() == .OK {
            if op.wantsDir {
                vm.clearFiles()  // directory ops take a single directory; clear the old one
            }
            vm.addPaths(panel.urls.map(\.path))
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    let op: DocOp
    @ObservedObject var vm: AppViewModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: op.wantsDir ? "folder.badge.plus" : "square.and.arrow.down")
                .font(.system(size: 30))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
            Text(op.wantsDir ? "把一个目录拖到这里" : "把文件拖到这里")
                .font(.callout).foregroundStyle(.secondary)
            Text("或用下方「\(op.wantsDir ? "选择目录" : "选择文件")」按钮")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            .foregroundStyle(hovering ? Color.accentColor : Color(nsColor: .separatorColor)))
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [String] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url.path) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // directory ops take a single directory: keep only the first drop
            if op.wantsDir {
                vm.clearFiles()
                if let first = collected.first { vm.addPaths([first]) }
            } else {
                vm.addPaths(collected)
            }
        }
        return true
    }
}

import SwiftUI
import UniformTypeIdentifiers
import AppKit



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


struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @State private var showPalette = false   // ⌘K 命令面板浮层开关

    var body: some View {
        NavigationSplitView {
            List(selection: $vm.selectedOpID) {
                Section("操作") {
                    ForEach(vm.ops) { op in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(op.title)
                                Text(op.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: op.icon)
                        }
                        .help(op.subtitle)   // 悬停看全文:2 行仍放不下的长句由 tooltip 兜底
                        .tag(op.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(vm.isRunning)
            .navigationTitle((Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DocKit"))
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .overlay {
                if vm.isLoadingOps && vm.ops.isEmpty { ProgressView() }
            }
        } detail: {
            DetailView(vm: vm)
        }
        .task {
            await vm.loadOps()
            let env = ProcessInfo.processInfo.environment
            if let op = env["DOCKIT_DEMO_OP"], vm.ops.contains(where: { $0.id == op }) {
                vm.selectedOpID = op
                vm.onOpChanged()
            }
            if let files = env["DOCKIT_DEMO_FILES"] {
                vm.addPaths(files.components(separatedBy: "\n").filter { !$0.isEmpty })
            }
        }
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
                .disabled(vm.isLoadingOps || vm.isRunning)
            }
        }
        .commandPalette(items: paletteItems, isPresented: $showPalette)
    }


    private var paletteItems: [PaletteItem] {
        vm.ops.map { op in
            PaletteItem(
                id: op.id,
                title: op.title,                 // 操作中文名
                subtitle: op.subtitle,           // 一行说明（分组/类别）
                icon: op.icon,                   // 操作已有的 SF Symbol
                keywords: paletteKeywords(for: op)  // 英文 verb/别名，拼写也能搜到
            ) {
                if !vm.isRunning { vm.selectedOpID = op.id }
            }
        }
    }

    private func paletteKeywords(for op: DocOp) -> String {
        [op.verb, op.id, op.aliases].filter { !$0.isEmpty }.joined(separator: " ")
    }
}


struct DetailView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    description: Text("从左侧选择规范化、引号统一、格式转换、拆分或合并。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(vm.selectedOp?.title ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DocKit"))
    }


    private func opHeader(_ op: DocOp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: op.icon).font(.title3)
                    .foregroundStyle(op.danger ? Color.red : Color.accentColor)
                Text(op.title).font(.headline)
                if op.danger {
                    Text("破坏性").font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
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
                    .disabled(vm.isRunning)
                    .fixedSize()   // 仅短标签的分段控件，安全（禁的是长文本 v:true）
                    Spacer()
                }
            }
            if op.hasOptions {
                Divider()
                optionsPanel(op)
                    .disabled(vm.isRunning)
            }
        }
        .card()
    }


    private func optionsPanel(_ op: DocOp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选项").font(.callout).bold()
                Spacer()
                Button("恢复默认") { vm.resetOptionsToDefaults() }
                    .buttonStyle(.link).font(.caption)
                    .disabled(vm.changedOptions.isEmpty)
            }
            ForEach(op.groupedOptions, id: \.group.id) { entry in
                optionGroup(entry.group, entry.items, op: op)
            }
        }
    }

    private func optionGroup(_ g: OpOptionGroup, _ items: [OpOption], op: DocOp) -> some View {
        let applicable = g.appliesTo.isEmpty || vm.files.isEmpty
            || vm.files.contains { g.appliesTo.contains(($0.path as NSString).pathExtension.lowercased()) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(g.title).font(.caption).bold()
                    .foregroundStyle(g.danger ? Color.red : .secondary)
                if !applicable, !g.appliesTo.isEmpty {
                    Text("(仅 " + g.appliesTo.joined(separator: "/") + ")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ForEach(items) { o in
                if o.isFile {
                    fileOptionRow(o, danger: g.danger, enabled: applicable)
                } else {
                    Toggle(isOn: Binding(
                        get: { vm.optionValues[o.id] ?? o.defaultOn },
                        set: { vm.optionValues[o.id] = $0 })) {
                        HStack(spacing: 5) {
                            Text(o.title).font(.callout)
                                .foregroundStyle(g.danger ? Color.red : .primary)
                            if !o.note.isEmpty {
                                Text(o.note).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!applicable)
                }
            }
        }
        .opacity(applicable ? 1 : 0.45)
    }

    private func fileOptionRow(_ o: OpOption, danger: Bool, enabled: Bool) -> some View {
        let picked = vm.optionPaths[o.id] ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(o.title).font(.callout).foregroundStyle(danger ? Color.red : .primary)
                if o.required {
                    Text("必选").font(.caption2).foregroundStyle(picked.isEmpty ? Color.red : .secondary)
                }
                if !o.note.isEmpty {
                    Text(o.note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                Button("选择…") { pickOptionFile(o) }.controlSize(.small)
                if picked.isEmpty {
                    Text("未选").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text((picked as NSString).lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(picked)                      // 悬停看全路径
                    Button {
                        vm.optionPaths[o.id] = nil
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("清除")
                }
            }
        }
        .disabled(!enabled)
    }

    private func pickOptionFile(_ o: OpOption) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if !o.exts.isEmpty {
            let types = o.exts.compactMap { UTType(filenameExtension: $0) }
            if types.count == o.exts.count {
                panel.allowedContentTypes = types
            } else {
                panel.allowedFileTypes = o.exts
            }
        }
        panel.prompt = "选择"
        panel.message = o.title
        if panel.runModal() == .OK, let u = panel.url {
            vm.optionPaths[o.id] = u.path
        }
    }


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
                    Text((f.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption.monospaced())
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Button { vm.remove(f) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.isRunning)
                }
            }
        }
        .card()
    }


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
                DisclosureGroup("处理详情") {
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


    private func pickFiles(_ op: DocOp) {
        let panel = NSOpenPanel()
        if let path = ProcessInfo.processInfo.environment["DOCKIT_INPUT_DIR"] {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        panel.allowsMultipleSelection = !op.wantsDir
        panel.canChooseDirectories = op.wantsDir
        panel.canChooseFiles = !op.wantsDir
        if panel.runModal() == .OK {
            if op.wantsDir {
                vm.clearFiles()  // scan 单目录，先清旧
            }
            vm.addPaths(panel.urls.map(\.path))
        }
    }
}


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
            guard !vm.isRunning else { return false }
            return handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let collected = DroppedPaths()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url.path) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let paths = collected.snapshot()
            if op.wantsDir {
                vm.clearFiles()
                if let first = paths.first { vm.addPaths([first]) }
            } else {
                vm.addPaths(paths)
            }
        }
        return true
    }
}

private final class DroppedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

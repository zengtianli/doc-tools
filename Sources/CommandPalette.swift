import SwiftUI
import AppKit

// ═══════════════════════════════════════════════════════════════════════════
// CommandPalette — ⌘K in-app search that jumps to a feature.
//
// Host integration is three steps:
//   1) add   .commandPalette(items: <[PaletteItem]>, isPresented: $showPalette)
//      to the root view
//   2) add   @State private var showPalette = false
//   3) add a ⌘K menu item in the App's .commands (post .tlPaletteToggle), or
//      simply include PaletteCommands()
//   Each PaletteItem.run = the jump performed when selected (usually setting
//   a selection / tab).
// ═══════════════════════════════════════════════════════════════════════════

/// One searchable "feature". The run closure is the jump action.
struct PaletteItem: Identifiable {
    let id: String
    let title: String           // primary name (main row, left)
    var subtitle: String = ""   // group/path/description (gray, right)
    var icon: String = ""       // SF Symbol name or emoji (auto-detected)
    var keywords: String = ""   // extra search terms (aliases; matched, not shown)
    let run: () -> Void
    var haystack: String { "\(title) \(subtitle) \(keywords)".lowercased() }
}

/// Match scoring: title prefix > title substring > haystack substring >
/// subsequence fuzz; nil = no match.
enum PaletteMatch {
    static func score(_ item: PaletteItem, query raw: String) -> Int? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        let title = item.title.lowercased()
        if title.hasPrefix(q) { return 1000 }
        if title.contains(q) { return 800 - max(0, title.count - q.count) }
        if item.haystack.contains(q) { return 500 }
        if isSubsequence(q, item.haystack) { return 200 }
        return nil
    }
    /// q's characters appear in order within s (latin fuzzy matching; CJK
    /// degrades to ordered containment, which is harmless).
    static func isSubsequence(_ q: String, _ s: String) -> Bool {
        var i = s.startIndex
        for ch in q {
            var hit = false
            while i < s.endIndex { let c = s[i]; i = s.index(after: i); if c == ch { hit = true; break } }
            if !hit { return false }
        }
        return true
    }
}

extension Notification.Name {
    /// App menu ⌘K → post this → the palette toggles.
    static let tlPaletteToggle = Notification.Name("TLCommandPaletteToggle")
}

/// Palette state (a reference type so the NSEvent keyboard monitor captures it
/// stably — struct @State closures go stale).
final class PaletteModel: ObservableObject {
    @Published var query: String = "" { didSet { recompute() } }
    @Published private(set) var results: [PaletteItem] = []
    @Published var sel: Int = 0
    private let all: [PaletteItem]

    init(_ items: [PaletteItem]) { all = items; results = items }

    func recompute() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            results = all
        } else {
            results = all
                .compactMap { it in PaletteMatch.score(it, query: q).map { (it, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        sel = 0
    }
    func move(_ d: Int) {
        guard !results.isEmpty else { return }
        sel = (sel + d + results.count) % results.count
    }
    var current: PaletteItem? { results.indices.contains(sel) ? results[sel] : nil }
}

/// The ⌘K command palette overlay.
struct CommandPalette: View {
    @Binding var isPresented: Bool
    @StateObject private var model: PaletteModel
    @FocusState private var focused: Bool
    @State private var monitor: Any?

    init(items: [PaletteItem], isPresented: Binding<Bool>) {
        _isPresented = isPresented
        _model = StateObject(wrappedValue: PaletteModel(items))
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            if model.results.isEmpty { empty } else { list }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
        .onAppear {
            DispatchQueue.main.async { focused = true }
            startMonitor()
        }
        .onDisappear { stopMonitor() }
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索功能…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit(run)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
            Text("\(model.results.count)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { idx, item in
                        row(item, active: idx == model.sel)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { model.sel = idx; run() }
                            .onHover { if $0 { model.sel = idx } }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.sel) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(model.sel, anchor: .center) }
            }
        }
    }

    private func row(_ item: PaletteItem, active: Bool) -> some View {
        HStack(spacing: 11) {
            icon(item.icon).frame(width: 22)
            Text(item.title).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 8)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Color.accentColor.opacity(0.16) : .clear))
    }

    @ViewBuilder private func icon(_ s: String) -> some View {
        if s.isEmpty {
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        } else if NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil {
            Image(systemName: s).foregroundStyle(.tint)
        } else {
            Text(s)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.tertiary)
            Text("没有匹配的功能").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 120)
    }

    private func run() {
        guard let item = model.current else { return }
        isPresented = false
        DispatchQueue.main.async(execute: item.run)
    }

    private func startMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 125: model.move(1); return nil      // ↓
            case 126: model.move(-1); return nil     // ↑
            case 36, 76: run(); return nil           // ⏎ / keypad enter
            case 53: isPresented = false; return nil // esc
            default: return e
            }
        }
    }
    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

extension View {
    /// One-line host integration: the .tlPaletteToggle notification (= the
    /// ⌘K menu item) toggles the palette overlay.
    func commandPalette(items: [PaletteItem], isPresented: Binding<Bool>) -> some View {
        overlay {
            if isPresented.wrappedValue {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.16).ignoresSafeArea()
                        .onTapGesture { isPresented.wrappedValue = false }
                    CommandPalette(items: items, isPresented: isPresented)
                        .padding(.top, 64)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tlPaletteToggle)) { _ in
            isPresented.wrappedValue.toggle()
        }
    }
}

/// Drop PaletteCommands() into the App's .commands to add a "Search ⌘K" menu
/// item. (Apps that already have a custom .commands block can add the same
/// Button inside that block instead.)
struct PaletteCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("搜索功能…") { NotificationCenter.default.post(name: .tlPaletteToggle, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

import AppKit
import SwiftUI

// =============================================================================
// UISelfTest — `DocKit --ui-self-test` (registered as sop.accept.native_ui).
//
// Runs in-process and offscreen: the real ContentView (with CommandPalette),
// a real AppViewModel and BackendClient are hosted in an NSHostingView inside a
// borderless NSWindow that is never ordered front. The activation policy is
// .prohibited, so the process never appears in the Dock, never activates and
// never takes focus. No input is synthesized, no menu is opened and the
// clipboard is untouched: the test posts the same notifications the ⌘R / ⌘K
// menu items post and sets the same view-model state the sidebar selection
// sets. Screenshots come from cacheDisplay into a bitmap.
//
// Environment:
//   DOCKIT_SELFTEST_INPUT_DIR  fictional inputs from scripts/make-demo.py (required)
//   SOP_OUT_DIR                screenshot directory (default perf/acceptance)
// Output: one JSON line {"ok", "checks", "screenshots", ...} on stdout; exit 0/1.
// =============================================================================

@MainActor
final class UISelfTest: NSObject, NSApplicationDelegate {
    private struct Check { let name: String; let ok: Bool; let detail: String }

    private var checks: [Check] = []
    private var screenshots: [String] = []
    private var window: NSWindow!
    private var paletteHistory: [Bool] = []
    private let started = Date()
    private let outDir: URL
    private let inputDir: String?

    nonisolated static func runAndExit() -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)   // no Dock icon, no activation, no focus
            let test = UISelfTest()
            app.delegate = test
            // Hard stop so a hung backend or SwiftUI stall can never leave a process behind.
            DispatchQueue.main.asyncAfter(deadline: .now() + 110) {
                test.finish(extra: ["error": "self-test watchdog timeout (110 s)"])
            }
            app.run()
        }
        exit(1)
    }

    override init() {
        let env = ProcessInfo.processInfo.environment
        outDir = URL(fileURLWithPath: env["SOP_OUT_DIR"] ?? "perf/acceptance")
        inputDir = env["DOCKIT_SELFTEST_INPUT_DIR"]
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.run() }
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(Check(name: name, ok: ok, detail: detail))
    }

    /// Poll the main actor until `cond` holds (SwiftUI updates land between polls).
    private func wait(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    private func run() async {
        let vm = AppViewModel(backend: BackendClient())
        let root = ContentView(vm: vm, paletteObserver: { [weak self] shown in
            self?.paletteHistory.append(shown)
        }).preferredColorScheme(.light)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1060, height: 760),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
        window.contentView = host
        // Deliberately never orderFront/makeKey: the window stays off every screen.
        host.layoutSubtreeIfNeeded()

        check("backend_script_resolved", BackendClient.resolveScriptPath() != nil,
              BackendClient.resolveScriptPath() ?? "not found")
        let script = BackendClient.resolveScriptPath() ?? ""
        check("bundled_python_runtime", BackendClient.resolvePython(for: script) != nil,
              BackendClient.resolvePython(for: script) ?? "would fall back to uv")
        check("window_not_visible", !window.isVisible && !window.isKeyWindow && !NSApp.isActive,
              "visible=\(window.isVisible) key=\(window.isKeyWindow) appActive=\(NSApp.isActive)")

        // 1) Initial load via ContentView.task → vm.loadOps() → backend gui-ops.
        let loaded = await wait(30) { vm.ops.count == 9 && !vm.isLoadingOps }
        check("ops_loaded_via_view_task", loaded, "ops=\(vm.ops.count) banner=\(vm.banner?.text ?? "-")")
        check("ops_count_eq_9", vm.ops.count == 9, "\(vm.ops.map(\.id))")
        check("default_selection_first_op", vm.selectedOpID == vm.ops.first?.id && vm.selectedOpID != nil,
              vm.selectedOpID ?? "nil")
        check("status_ready", vm.statusText.contains("共 9 个操作"), vm.statusText)
        shot("01-ops-loaded")

        // 2) ⌘R path: the menu item posts .consoleRefresh; ContentView.onReceive reloads.
        vm.ops = []
        NotificationCenter.default.post(name: .consoleRefresh, object: nil)
        let refreshed = await wait(30) { vm.ops.count == 9 && !vm.isLoadingOps }
        check("refresh_notification_reloads_ops", refreshed, "ops=\(vm.ops.count)")

        // 3) ⌘K path: the menu item posts .tlPaletteToggle; the overlay opens, then a
        //    second toggle closes it (Esc goes through a keyDown monitor, which we do
        //    not synthesize).
        NotificationCenter.default.post(name: .tlPaletteToggle, object: nil)
        let opened = await wait(5) { self.paletteHistory.last == true }
        check("palette_opens_on_toggle", opened, "history=\(paletteHistory)")
        try? await Task.sleep(for: .milliseconds(300))
        let paletteShot = shot("02-palette-open")
        NotificationCenter.default.post(name: .tlPaletteToggle, object: nil)
        let closed = await wait(5) { self.paletteHistory.last == false }
        check("palette_closes_on_second_toggle", closed && paletteHistory == [true, false],
              "history=\(paletteHistory)")
        let closedShot = shot("03-palette-closed")
        if let a = paletteShot, let b = closedShot {
            check("palette_changes_rendering", a != b, "open vs closed bitmap differ")
        }

        // 4) Selection path: sidebar List(selection:) writes selectedOpID; onChange
        //    runs vm.onOpChanged() → target default for convert.
        vm.selectedOpID = "convert"
        let convertReady = await wait(5) { vm.selectedTargetID == "md" }
        check("select_convert_sets_default_target", convertReady,
              "op=\(vm.selectedOpID ?? "nil") target=\(vm.selectedTargetID ?? "nil")")
        vm.selectedOpID = "quotes"
        let quotesReady = await wait(5) { vm.selectedTargetID == nil && vm.selectedOp?.id == "quotes" }
        check("select_quotes", quotesReady, "op=\(vm.selectedOp?.title ?? "nil")")

        // 5) Add one fictional input file and run the op through the real backend.
        guard let inputDir else {
            check("input_dir_env", false, "DOCKIT_SELFTEST_INPUT_DIR not set")
            finish(); return
        }
        let input = (inputDir as NSString).appendingPathComponent("活动说明.docx")
        check("fictional_input_exists", FileManager.default.fileExists(atPath: input), input)
        vm.addPaths([input])
        vm.addPaths([input])   // duplicate is ignored
        check("file_added_once", vm.files.count == 1 && vm.canRun,
              "files=\(vm.files.count) canRun=\(vm.canRun)")
        try? await Task.sleep(for: .milliseconds(200))
        shot("04-file-added")

        let runStart = Date()
        await vm.run()
        let runMs = Int(Date().timeIntervalSince(runStart) * 1000)
        let r = vm.results.first
        check("run_results_ok", vm.results.count == 1 && r?.ok == true,
              "results=\(vm.results.count) ok=\(r?.ok.description ?? "nil") msg=\(r?.message ?? vm.banner?.text ?? "-") ms=\(runMs)")
        check("run_summary_1_of_1", vm.summary == "成功 1/1", vm.summary)
        let output = r?.outputs.first ?? ""
        let inputRoot = URL(fileURLWithPath: inputDir).resolvingSymlinksInPath().path + "/"
        let outputReal = URL(fileURLWithPath: output).resolvingSymlinksInPath().path
        check("run_output_file_exists", !output.isEmpty && FileManager.default.fileExists(atPath: output)
              && outputReal.hasPrefix(inputRoot),
              (output as NSString).lastPathComponent)
        check("no_error_banner", vm.banner == nil && !vm.isRunning, vm.banner?.text ?? "")
        try? await Task.sleep(for: .milliseconds(300))
        shot("05-run-results")

        check("still_not_visible_or_active", !window.isVisible && !NSApp.isActive,
              "visible=\(window.isVisible) appActive=\(NSApp.isActive)")
        finish(extra: ["run_ms": runMs])
    }

    /// Render the hosting view offscreen into a PNG; asserts size and non-blank pixels.
    @discardableResult
    private func shot(_ name: String) -> Data? {
        guard let view = window.contentView else { check("shot_\(name)", false, "no content view"); return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            check("shot_\(name)", false, "no bitmap rep"); return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Non-blank: count distinct colours on a sparse grid.
        var colours = Set<UInt32>()
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in stride(from: 0, to: h, by: max(1, h / 60)) {
            for x in stride(from: 0, to: w, by: max(1, w / 80)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let v = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8)
                    | UInt32(c.blueComponent * 255)
                colours.insert(v)
            }
        }
        let png = rep.representation(using: .png, properties: [:])
        var path = ""
        if let png {
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let url = outDir.appendingPathComponent("native_ui-\(name).png")
            if (try? png.write(to: url)) != nil { path = url.path; screenshots.append(path) }
        }
        check("shot_\(name)_nonblank", w > 0 && h > 0 && colours.count >= 8 && !path.isEmpty,
              "\(w)x\(h) colours=\(colours.count)")
        return png
    }

    private var finished = false
    fileprivate func finish(extra: [String: Any] = [:]) {
        guard !finished else { return }
        finished = true
        let ok = !checks.isEmpty && checks.allSatisfy(\.ok) && extra["error"] == nil
        var payload: [String: Any] = [
            "ok": ok,
            "checks": checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
            "screenshots": screenshots,
            "passed": checks.filter(\.ok).count,
            "total": checks.count,
            "elapsed_ms": Int(Date().timeIntervalSince(started) * 1000),
        ]
        for (k, v) in extra { payload[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        fflush(stdout)
        window?.close()
        exit(ok ? 0 : 1)
    }
}

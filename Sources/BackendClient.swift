import Foundation

// =============================================================================
// BackendClient — thin wrapper around the external Python CLI backend.
//
// The Swift layer is a GUI shell only: it never parses documents or rewrites
// business logic. All real work is delegated to backend/doc_gui_backend.py via
// `Foundation.Process`, and stdout is decoded as JSON (Decodable).
//
// Envelope protocol: every gui-* subcommand exits 0;
//   success = {"ok": true, ...}, failure = {"ok": false, "error": "message"}.
// runDecoding first decodes an {ok, error} probe — ok == false throws the
// error text; otherwise it decodes the target type; if that fails it falls
// back to the probe again (never dumps raw JSON at the user).
//
// Hard-won gotchas baked into this file (think twice before removing any):
//   · GUI apps inherit launchd's minimal PATH, not your shell's. The uv
//     binary is therefore probed at well-known absolute locations, and extra
//     tool directories are prepended to the child PATH so the backend can
//     find helpers (soffice, textutil, pandoc, …).
//   · Child output >64KB deadlocks the pipe → stdout/stderr are drained
//     concurrently on background queues (readDataToEndOfFile); never read
//     them inside the terminationHandler.
//   · Large stdin input deadlocks symmetrically → write stdin only after
//     process.run() (a reader exists by then), then close; use the throwing
//     write(contentsOf:) so an early-exiting child (broken pipe) fails
//     silently instead of crashing the app.
//   · Timeout → terminate + human-readable error; Task cancellation →
//     terminate + CancellationError.
// =============================================================================

enum BackendError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderr: String, stdout: String)
    case decodeFailed(String)
    case emptyOutput
    case backend(String)            // envelope {ok:false, error}
    case timeout(TimeInterval)
    case uvNotFound
    case scriptNotFound

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m):
            return "无法启动后端进程: \(m)"
        case .nonZeroExit(let c, let e, let out):
            // Operational subcommands may fail with {"error": "..."} on stdout
            // and a non-zero exit; surface that message when present.
            if let data = out.data(using: .utf8),
               let env = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data) {
                return "后端错误: \(env.error)"
            }
            let detail = !e.isEmpty ? e : (out.isEmpty ? "(无输出)" : out)
            return "后端退出码 \(c): \(detail)"
        case .decodeFailed(let m):
            return "后端响应解析失败: \(m)"
        case .emptyOutput:
            return "后端没有输出"
        case .backend(let m):
            return m
        case .timeout(let t):
            return "后端超时（\(Int(t)) 秒未完成），已终止该进程。可重试或去终端跑同样命令排查。"
        case .uvNotFound:
            return "找不到 uv（Python 运行器）。请先安装：brew install uv，装好后重新打开本 app。"
        case .scriptNotFound:
            return "找不到后端脚本 backend/doc_gui_backend.py：app 包内 Resources/backend 缺失，"
                 + "开发目录里也没有 backend/。请用 ./build.sh 重新构建，或重新下载完整安装包。"
        }
    }
}

/// Reference box: the concurrent drain queues hand data back to the waiter.
/// `@unchecked Sendable` is safe here: each box is written by exactly one
/// drain task, and the waiter reads only after `group.wait()` establishes a
/// happens-before edge.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Boolean flag box (timeout / cancellation), visibility guaranteed by the
/// same queue ordering.
private final class FlagBox: @unchecked Sendable {
    var on = false
}

actor BackendClient {
    // MARK: - Backend script location (the script path is part of the contract)
    //
    // Release layout: build.sh copies the repo's backend/ directory into the
    // app bundle at Contents/Resources/backend/, so the bundled path wins.
    // Dev fallback: when running a bare build product (e.g. straight out of
    // Xcode's DerivedData with no bundled backend), walk up from the
    // executable looking for <repo>/backend/doc_gui_backend.py.
    // Neither found → nil; calls then throw a human-readable error.

    static func resolveScriptPath() -> String? {
        let fm = FileManager.default
        // 1) Bundled backend (release build).
        if let res = Bundle.main.resourcePath {
            let bundled = res + "/backend/doc_gui_backend.py"
            if fm.fileExists(atPath: bundled) { return bundled }
        }
        // 2) Dev fallback: walk up from the executable towards the repo root.
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var dir = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("backend/doc_gui_backend.py")
            if fm.fileExists(atPath: candidate.path) { return candidate.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - uv discovery
    //
    // GUI apps do not inherit the shell PATH, so probe well-known install
    // locations for the uv binary instead of relying on /usr/bin/env.

    static let uvCandidates = [
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        NSHomeDirectory() + "/.local/bin/uv",
    ]

    static func resolveUV() -> String? {
        uvCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Default 180s. Typical clean/convert operations finish in seconds, but
    /// the very first run lets uv resolve and install the backend's inline
    /// (PEP 723) dependencies, which can take 1–2 minutes.
    static let defaultTimeout: TimeInterval = 180

    let scriptPath: String?

    init(scriptPath: String? = BackendClient.resolveScriptPath()) {
        self.scriptPath = scriptPath
    }

    // MARK: - DocTools API (gui-ops lists operations / gui-run runs one)

    /// List available operations (clean / convert / split / merge / …).
    func ops() async throws -> OpsResult {
        try await runDecoding(args: ["gui-ops"])
    }

    /// Run one operation. op = operation id; target = destination format for
    /// convert (nil otherwise); files = absolute paths.
    func run(op: String, target: String?, files: [String]) async throws -> RunResult {
        var args = ["gui-run", "--op", op]
        if let target, !target.isEmpty { args += ["--to", target] }
        args.append("--files"); args += files
        return try await runDecoding(args: args, timeout: Self.defaultTimeout)
    }

    // MARK: - The actual command line
    //
    //   <uv> run <scriptPath> <args...>
    //
    // The backend declares its dependencies inline (PEP 723), so a plain
    // `uv run` is enough — uv provisions an isolated environment on demand.

    private func runDecoding<T: Decodable>(args: [String], stdin: String? = nil,
                                           script: String? = nil,
                                           timeout: TimeInterval = BackendClient.defaultTimeout)
    async throws -> T {
        let output = try await runProcess(args: args, stdin: stdin,
                                          script: script ?? scriptPath, timeout: timeout)
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw BackendError.emptyOutput
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // 1) Envelope probe: ok == false → throw the backend's own message.
        let probe = try? decoder.decode(BackendProbe.self, from: data)
        if probe?.ok == false {
            throw BackendError.backend(probe?.error ?? "后端返回失败（未给出原因）")
        }
        // 2) Decode the target type.
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // 3) Fallback probe: target decode failed but the envelope carries
            //    an error message → use it instead of dumping raw JSON.
            if let err = probe?.error, !err.isEmpty {
                throw BackendError.backend(err)
            }
            throw BackendError.decodeFailed(
                "\(error.localizedDescription) — raw: \(output.prefix(300))")
        }
    }

    /// Run the process; capture stdout/stderr/exit code.
    ///
    /// · stdout/stderr are drained concurrently on background queues while the
    ///   child runs (prevents the 64KB pipe deadlock).
    /// · stdin is written after run() (a reader exists by then) with the
    ///   throwing write(contentsOf:) — an early-exiting child no longer
    ///   raises an ObjC exception that would crash the app.
    /// · Timeout: terminate the process and throw .timeout.
    /// · Cancellation (Task.cancel): terminate and throw CancellationError.
    private func runProcess(args: [String], stdin: String?, script: String?,
                            timeout: TimeInterval) async throws -> String {
        guard let script else { throw BackendError.scriptNotFound }
        guard let uv = BackendClient.resolveUV() else { throw BackendError.uvNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", script] + args

        // GUI-launched apps only inherit launchd's minimal PATH; prepend the
        // usual tool directories so the backend can find helper binaries
        // (soffice, textutil, pandoc, …).
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "\(NSHomeDirectory())/.local/bin", "/usr/local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        // Keep Python from writing __pycache__ into the app bundle
        // (mutating Resources would also dirty the code signature).
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = (stdin != nil) ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        let canceled = FlagBox()
        let timedOut = FlagBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let ioQueue = DispatchQueue(
                    label: "cyou.tianli.DocTools.backend-io", attributes: .concurrent)
                let group = DispatchGroup()
                let outBox = DataBox()
                let errBox = DataBox()

                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: BackendError.launchFailed(error.localizedDescription))
                    return
                }

                // Write stdin after run() (a reader exists), then close so the
                // child sees EOF. The throwing write(contentsOf:) makes a
                // broken pipe fail silently instead of crashing the app.
                if let inPipe, let stdin {
                    ioQueue.async {
                        let h = inPipe.fileHandleForWriting
                        try? h.write(contentsOf: Data(stdin.utf8))
                        try? h.close()
                    }
                }

                // Concurrent drain: each side blocks on its own thread until
                // the child closes the pipe — the pipe can never fill up.
                group.enter()
                ioQueue.async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                ioQueue.async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                // Timeout guard: terminate on expiry (waitUntilExit then
                // returns; the timedOut flag drives the thrown error).
                ioQueue.asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.on = true
                        process.terminate()
                    }
                }

                // Wait for exit + both drains; resume exactly once.
                ioQueue.async {
                    process.waitUntilExit()
                    group.wait()
                    if canceled.on {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    if timedOut.on {
                        cont.resume(throwing: BackendError.timeout(timeout))
                        return
                    }
                    let out = String(decoding: outBox.data, as: UTF8.self)
                    let err = String(decoding: errBox.data, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        cont.resume(returning: out)
                    } else {
                        cont.resume(throwing: BackendError.nonZeroExit(
                            code: process.terminationStatus, stderr: err, stdout: out))
                    }
                }
            }
        } onCancel: {
            canceled.on = true
            if process.isRunning { process.terminate() }
        }
    }
}

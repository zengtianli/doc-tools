import Foundation

// =============================================================================
// DocTools — Codable contract (mirrors the Python backend's JSON)
//
// Contract conventions:
//   · Every gui-* subcommand exits 0; success = {"ok": true, ...},
//     failure = {"ok": false, "error": "human-readable message"}.
//   · The decoder uses .convertFromSnakeCase: display_path → displayPath etc.
//     map automatically. Backend fields are snake_case throughout, so the
//     Swift side never writes renaming CodingKeys.
//   · Every display field decodes with decodeIfPresent + a default — one
//     missing field from the backend must never fail the whole decode
//     (one bad row must never take down the whole list). The Decodable init
//     lives in an extension so the memberwise init stays available.
// =============================================================================

// MARK: - Envelope probe

/// First-pass probe for runDecoding: {ok, error}. ok == false throws the
/// error text as-is.
struct BackendProbe: Decodable {
    let ok: Bool?
    let error: String?
}

/// Legacy failure envelope (non-zero exit + {"error"}) — operational
/// subcommands are allowed to fail in this shape.
struct BackendErrorEnvelope: Codable {
    let error: String
}

// MARK: - Decoding helpers (shorthand for decodeIfPresent + default)

extension KeyedDecodingContainer {
    func str(_ key: Key, _ fallback: String = "") -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil ?? fallback
    }
    func int(_ key: Key, _ fallback: Int = 0) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? nil ?? fallback
    }
    func bool(_ key: Key, _ fallback: Bool = false) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil ?? fallback
    }
    func strOpt(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }
}

// MARK: - gui-ops: the operation catalog (the UI renders its menu from this)

/// Destination-format option, used by convert only.
struct OpTarget: Identifiable, Hashable {
    let id: String       // "md" / "word" / "xlsx" / "csv" / "txt"
    let title: String    // "Markdown" / "Word" …
}
extension OpTarget: Decodable {
    private enum CodingKeys: String, CodingKey { case id, title }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id); title = c.str(.title)
    }
}

/// One document operation (clean / convert / split / merge / …).
struct DocOp: Identifiable, Hashable {
    let id: String          // operation id, passed to gui-run --op
    let verb: String        // underlying dispatcher verb
    let title: String       // display title
    let subtitle: String    // one-line description
    let icon: String        // SF Symbol
    let exts: [String]      // supported source extensions (drag-in hint)
    let kind: String        // "files" (multiple files) / "dir" (one directory)
    let targets: [OpTarget] // convert only; empty otherwise

    var needsTarget: Bool { !targets.isEmpty }
    var wantsDir: Bool { kind == "dir" }
}
extension DocOp: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, verb, title, subtitle, icon, exts, kind, targets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id); verb = c.str(.verb)
        title = c.str(.title); subtitle = c.str(.subtitle)
        icon = c.str(.icon, "doc"); kind = c.str(.kind, "files")
        exts = (try? c.decodeIfPresent([String].self, forKey: .exts)) ?? nil ?? []
        targets = (try? c.decodeIfPresent([OpTarget].self, forKey: .targets)) ?? nil ?? []
    }
}

/// `gui-ops` → {"ok": true, "ops": [...]}
struct OpsResult: Decodable {
    let ok: Bool
    let ops: [DocOp]
    private enum CodingKeys: String, CodingKey { case ok, ops }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.bool(.ok, true)
        ops = (try? c.decodeIfPresent([DocOp].self, forKey: .ops)) ?? nil ?? []
    }
}

// MARK: - gui-run: per-file results

/// Result for one input. outputs = absolute paths of produced files/dirs.
struct FileResult: Identifiable, Hashable {
    let id = UUID()
    let input: String      // input absolute path (or "a + b" for merge)
    let name: String       // display name
    let ok: Bool
    let outputs: [String]  // produced absolute paths
    let message: String    // one-line human-readable result
}
extension FileResult: Decodable {
    private enum CodingKeys: String, CodingKey { case input, name, ok, outputs, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = c.str(.input); name = c.str(.name)
        ok = c.bool(.ok)
        outputs = (try? c.decodeIfPresent([String].self, forKey: .outputs)) ?? nil ?? []
        message = c.str(.message)
    }
}

/// `gui-run` → {"ok", "op", "results":[...], "succeeded", "total", "log", "skipped_missing"?}
struct RunResult: Decodable {
    let ok: Bool
    let op: String
    let results: [FileResult]
    let succeeded: Int
    let total: Int
    let log: String
    let skippedMissing: [String]
    private enum CodingKeys: String, CodingKey {
        case ok, op, results, succeeded, total, log, skippedMissing
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.bool(.ok, true)
        op = c.str(.op)
        results = (try? c.decodeIfPresent([FileResult].self, forKey: .results)) ?? nil ?? []
        succeeded = c.int(.succeeded)
        total = c.int(.total)
        log = c.str(.log)
        skippedMissing = (try? c.decodeIfPresent([String].self, forKey: .skippedMissing)) ?? nil ?? []
    }
}

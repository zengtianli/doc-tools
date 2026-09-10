import Foundation



struct BackendProbe: Decodable {
    let ok: Bool?
    let error: String?
}

struct BackendErrorEnvelope: Codable {
    let error: String
}


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

struct OpOption: Identifiable, Hashable, Decodable {
    let id: String            // "rule.quotes" / "scope.comments" / "ref"
    let group: String         // 归属分组 id
    let type: String          // "bool"（勾选框）/ "file"（文件选择器）
    let title: String
    let note: String          // 副标题（可空）
    let defaultOn: Bool
    let exts: [String]        // type=file 时限定可选后缀（空 = 不限）
    let required: Bool        // 必填：空值时禁用「执行」

    var isFile: Bool { type == "file" }

    private enum CodingKeys: String, CodingKey {
        case id, group, type, title, note, `default`, exts, required
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id); group = c.str(.group, "")
        type = c.str(.type, "bool"); title = c.str(.title)
        note = c.str(.note, "")
        defaultOn = (try? c.decodeIfPresent(Bool.self, forKey: .default)) ?? nil ?? true
        exts = (try? c.decodeIfPresent([String].self, forKey: .exts)) ?? nil ?? []
        required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? nil ?? false
    }
}

struct OpOptionGroup: Identifiable, Hashable, Decodable {
    let id: String
    let title: String
    let danger: Bool          // true → 红色标题 + 默认折叠
    let appliesTo: [String]   // 只对这些后缀有意义（空 = 全部）

    private enum CodingKeys: String, CodingKey { case id, title, danger, appliesTo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id); title = c.str(.title)
        danger = (try? c.decodeIfPresent(Bool.self, forKey: .danger)) ?? nil ?? false
        appliesTo = (try? c.decodeIfPresent([String].self, forKey: .appliesTo)) ?? nil ?? []
    }
}

struct DocOp: Identifiable, Hashable {
    let id: String          // 操作 id，传给 gui-run --op
    let verb: String        // 底层 doc_dispatch 动词
    let title: String       // 中文标题
    let aliases: String     // 英文/别名搜索词（后端声明；⌘K 面板用）
    let subtitle: String    // 一行说明
    let icon: String        // SF Symbol
    let exts: [String]      // 支持的源后缀（拖入提示用）
    let kind: String        // "files"（多文件）/ "dir"（单目录）
    let targets: [OpTarget] // 单选参数槽（convert 目标格式 / renum 范围 / bidfinal 模式）
    let danger: Bool        // 破坏性动词（原地覆写 / 不可撤销）→ UI 标红
    let optionGroups: [OpOptionGroup]  // 勾选项分组（后端声明，可空）
    let options: [OpOption]            // 勾选项（后端声明，可空）

    var needsTarget: Bool { !targets.isEmpty }
    var hasOptions: Bool { !options.isEmpty }
    var groupedOptions: [(group: OpOptionGroup, items: [OpOption])] {
        optionGroups.compactMap { g in
            let items = options.filter { $0.group == g.id }
            return items.isEmpty ? nil : (g, items)
        }
    }
    var wantsDir: Bool { kind == "dir" }
}
extension DocOp: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, verb, title, subtitle, icon, exts, kind, targets, options, optionGroups, danger, aliases
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id); verb = c.str(.verb)
        title = c.str(.title); subtitle = c.str(.subtitle)
        aliases = c.str(.aliases)
        icon = c.str(.icon, "doc"); kind = c.str(.kind, "files")
        exts = (try? c.decodeIfPresent([String].self, forKey: .exts)) ?? nil ?? []
        targets = (try? c.decodeIfPresent([OpTarget].self, forKey: .targets)) ?? nil ?? []
        options = (try? c.decodeIfPresent([OpOption].self, forKey: .options)) ?? nil ?? []
        optionGroups = (try? c.decodeIfPresent([OpOptionGroup].self, forKey: .optionGroups)) ?? nil ?? []
        danger = (try? c.decodeIfPresent(Bool.self, forKey: .danger)) ?? nil ?? false
    }
}

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


struct FileResult: Identifiable, Hashable {
    let id = UUID()
    let input: String      // 输入绝对路径（或 merge 的 "a + b"）
    let name: String       // 展示名
    let ok: Bool
    let outputs: [String]  // 产出绝对路径
    let message: String    // 一行人话结果
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

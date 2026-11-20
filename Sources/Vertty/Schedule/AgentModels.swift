import Foundation

struct AgentModel: Equatable, Identifiable {
    let id: String
    let name: String
    let efforts: [String]
}

struct AgentCatalog: Equatable {
    var models: [AgentModel]
    var defaultEfforts: [String]

    func efforts(for model: String?) -> [String]? {
        guard let model else { return defaultEfforts }
        return models.first { $0.id == model }?.efforts
    }
}

final class AgentModels: ObservableObject {
    static let shared = AgentModels()

    private let lock = NSLock()
    private var cache: [AgentKind: AgentCatalog] = [:]
    private var loading: Set<AgentKind> = []
    private let queue = DispatchQueue(label: "vertty.models", qos: .utility, attributes: .concurrent)

    func catalog(_ kind: AgentKind) -> AgentCatalog? {
        lock.lock(); defer { lock.unlock() }
        return cache[kind]
    }

    func refresh(_ kind: AgentKind) {
        lock.lock()
        let busy = !loading.insert(kind).inserted
        lock.unlock()
        guard !busy else { return }
        queue.async { [self] in
            load(kind)
            lock.lock()
            loading.remove(kind)
            lock.unlock()
        }
    }

    func loadMissing() {
        let group = DispatchGroup()
        for kind in AgentKind.allCases where catalog(kind) == nil {
            queue.async(group: group) { [self] in load(kind) }
        }
        group.wait()
    }

    @discardableResult
    private func load(_ kind: AgentKind) -> AgentCatalog? {
        guard let catalog = Self.read(kind) else { return nil }
        lock.lock()
        let changed = cache[kind] != catalog
        cache[kind] = catalog
        lock.unlock()
        if changed { DispatchQueue.main.async { self.objectWillChange.send() } }
        return catalog
    }

    private static func read(_ kind: AgentKind) -> AgentCatalog? {
        switch kind {
        case .claude: return readClaude("claude", kind: kind)
        case .deepseekClaude: return readClaude("deepseek_claude", kind: kind)
        case .codex: return readCodex()
        }
    }

    // The Agent SDK's initialize request returns the /model list without
    // sending anything to the model; no session is saved.
    // https://code.claude.com/docs/en/agent-sdk/typescript (supportedModels, ModelInfo)
    private static func readClaude(_ command: String, kind: AgentKind) -> AgentCatalog? {
        guard let exe = ShellEnvironment.which(command) else { return nil }
        let request = #"{"type":"control_request","request_id":"vertty-models","request":{"subtype":"initialize"}}"# + "\n"
        let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--no-session-persistence", "--strict-mcp-config"]
        guard let out = Proc.run(exe, args, cwd: NSTemporaryDirectory(), timeout: 30, input: Data(request.utf8))?.stdout
        else { return nil }
        for line in out.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "control_response",
                  let response = (obj["response"] as? [String: Any])?["response"] as? [String: Any],
                  let entries = response["models"] as? [[String: Any]] else { continue }
            return claudeCatalog(entries, kind: kind)
        }
        return nil
    }

    static func claudeCatalog(_ entries: [[String: Any]], kind: AgentKind) -> AgentCatalog {
        func efforts(_ e: [String: Any]) -> [String] {
            e["supportsEffort"] as? Bool == true ? e["supportedEffortLevels"] as? [String] ?? [] : []
        }
        var defaultEfforts: [String] = []
        var models: [AgentModel] = []
        var seen: Set<String> = []
        for e in entries {
            guard let value = e["value"] as? String else { continue }
            if value == "default" {
                defaultEfforts = efforts(e)
                continue
            }
            let resolved = e["resolvedModel"] as? String ?? value
            // DeepSeek's wrapper maps every alias to its own models; Claude Code
            // still lists Claude models, which DeepSeek's API doesn't serve.
            if kind == .deepseekClaude && resolved.hasPrefix("claude-") { continue }
            // Aliases the wrapper points at the same model.
            guard seen.insert(resolved).inserted else { continue }
            models.append(AgentModel(id: value, name: e["displayName"] as? String ?? value, efforts: efforts(e)))
        }
        return AgentCatalog(models: models, defaultEfforts: defaultEfforts)
    }

    private static func readCodex() -> AgentCatalog? {
        guard let exe = ShellEnvironment.which("codex") else { return nil }
        var env: [String: String] = [:]
        if let home = ShellEnvironment.codexHome { env["CODEX_HOME"] = home }
        guard let out = Proc.run(exe, ["debug", "models"], timeout: 15, extraEnv: env)?.stdout,
              let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
              let entries = obj["models"] as? [[String: Any]] else { return nil }
        return codexCatalog(entries)
    }

    static func codexCatalog(_ entries: [[String: Any]]) -> AgentCatalog {
        let listed = entries.filter { $0["visibility"] as? String == "list" && $0["slug"] is String }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
        let models = listed.map { e in
            let slug = e["slug"] as! String
            let levels = (e["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
            return AgentModel(id: slug, name: e["display_name"] as? String ?? slug, efforts: levels)
        }
        // Which model the user's config picks isn't in the catalog: offer what every model takes.
        let common = models.first.map { first in
            first.efforts.filter { level in models.allSatisfy { $0.efforts.contains(level) } }
        } ?? []
        return AgentCatalog(models: models, defaultEfforts: common)
    }
}

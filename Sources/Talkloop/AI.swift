// The conversation AI, called straight from the phone with the learner's own keys (saved in
// their Vocab Trainer account). Groq by default, with backup Groq keys, Cloudflare and Mistral
// when it is at its limit; or OpenAI, Gemini or Cloudflare as the main service.
// Replies are fetched whole (the web app streams OpenAI and Gemini to start the voice sooner).
import Foundation

// MARK: - Keys

struct KeyRing {
    static let services = ["openai", "mistral", "groq", "groq2", "groq3", "cfAccount", "cfToken", "gemini", "gemini2", "geminiLive"]
    static let providers = ["groq", "gemini", "openai", "cloudflare"]

    var keys: [String: String] = [:]
    var link: TrainerLink?

    func key(_ service: String) -> String { keys[service] ?? "" }
    /// The key for live calls: the Gemini Live key, else the ordinary Gemini key.
    var liveKey: String { key("geminiLive").isEmpty ? key("gemini") : key("geminiLive") }
    var hasCloudflare: Bool { !key("cfAccount").isEmpty && !key("cfToken").isEmpty && link != nil }

    func ready(_ provider: String) -> Bool {
        provider == "cloudflare" ? (!key("cfAccount").isEmpty && !key("cfToken").isEmpty) : !key(provider).isEmpty
    }

    /// The saved choice, unless it has no key while another one does.
    var provider: String {
        let saved = Store.get("provider", "")
        if Self.providers.contains(saved), ready(saved) || !Self.providers.contains(where: ready) { return saved }
        return Self.providers.first(where: ready) ?? "groq"
    }

    static func setProvider(_ p: String) { Store.set("provider", p) }

    static let openaiDefaultModel = "gpt-6-luna"
    static var openaiModel: String {
        let m = Store.get("openai_model", "")
        return m.isEmpty ? openaiDefaultModel : m
    }

    var summary: String {
        switch provider {
        case "gemini": return key("gemini2").isEmpty ? "✓ Using Google Gemini." : "✓ Using Google Gemini, with a second Gemini key as backup."
        case "openai": return "✓ Using OpenAI (\(Self.openaiModel))\(key("groq").isEmpty ? "" : ", with Groq as backup")."
        case "cloudflare": return key("groq").isEmpty ? "✓ Using Cloudflare Workers AI." : "✓ Using Cloudflare Workers AI, with Groq as backup."
        default:
            let groqBackups = ["groq2", "groq3"].filter { !key($0).isEmpty }.count
            var backups: [String] = []
            if groqBackups > 0 { backups.append(groqBackups == 1 ? "a second Groq key" : "\(groqBackups) more Groq keys") }
            if !key("cfAccount").isEmpty && !key("cfToken").isEmpty { backups.append("Cloudflare") }
            if !key("mistral").isEmpty { backups.append("Mistral") }
            return backups.isEmpty ? "✓ Using Groq." : "✓ Using Groq, with \(backups.joined(separator: " and ")) as backup."
        }
    }
}

// MARK: - Requests

struct AIMessage {
    let role: String // "user" | "assistant"
    let content: String
}

struct AIRequest {
    var system: String
    var schema: [String: Any] // in Gemini's format
    var messages: [AIMessage]
    var temperature: Double = 0.8
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

private struct ChatService {
    let name: String
    let url: String
    let model: String
    var extra: [String: Any] = [:]
    var noTemperature = false
}

private let groq = ChatService(name: "Groq", url: "https://api.groq.com/openai/v1/chat/completions",
                               model: "openai/gpt-oss-120b", extra: ["reasoning_effort": "low"])
private let mistral = ChatService(name: "Mistral", url: "https://api.mistral.ai/v1/chat/completions", model: "mistral-small-latest")
private func openai() -> ChatService {
    ChatService(name: "OpenAI", url: "https://api.openai.com/v1/chat/completions", model: KeyRing.openaiModel, noTemperature: true)
}

private let geminiBase = "https://generativelanguage.googleapis.com/v1beta/models"
private let geminiModel = "gemini-flash-lite-latest"
private let geminiFallbackModel = "gemini-flash-latest"

struct AIClient {
    let keys: KeyRing

    /// One JSON answer from the chosen service.
    func json(_ request: AIRequest) async throws -> [String: Any] {
        switch keys.provider {
        case "groq": return try await groqJson(request)
        case "cloudflare": return try await cloudflareJson(request)
        case "openai": return try await openaiJson(request)
        default: return try await geminiJson(request)
        }
    }

    // MARK: OpenAI-style chat APIs

    private func chatMessages(_ r: AIRequest) -> [[String: String]] {
        [["role": "system", "content": Schema.chatSystemContent(r.system, r.schema)]]
            + r.messages.map { ["role": $0.role, "content": $0.content] }
    }

    private func post(_ service: ChatService, key: String, _ r: AIRequest) async throws -> (Int, Data) {
        var body: [String: Any] = [
            "model": service.model,
            "messages": chatMessages(r),
            "response_format": ["type": "json_object"],
        ]
        if !service.noTemperature { body["temperature"] = r.temperature }
        for (k, v) in service.extra { body[k] = v }
        var req = URLRequest(url: URL(string: service.url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func cloudflare(_ r: AIRequest) async throws -> (Int, Data) {
        guard let link = keys.link else { throw AIError.message("Cloudflare goes through the Vocab Trainer: log in there first.") }
        return try await Backend.cloudflare(link, account: keys.key("cfAccount"), token: keys.key("cfToken"), body: [
            "messages": chatMessages(r),
            "response_format": ["type": "json_object"],
            "temperature": r.temperature,
            "max_tokens": 2000,
            "reasoning_effort": "low",
        ])
    }

    private static func busy(_ status: Int) -> Bool { status == 429 || status >= 500 }

    private func groqJson(_ r: AIRequest) async throws -> [String: Any] {
        let main = keys.key("groq")
        guard !main.isEmpty else { throw AIError.message("Add your Groq API key to start.") }
        var name = "Groq"
        var (status, data) = try await post(groq, key: main, r)
        for backup in ["groq2", "groq3"] where status == 429 && !keys.key(backup).isEmpty {
            (status, data) = try await post(groq, key: keys.key(backup), r)
        }
        if Self.busy(status) && keys.hasCloudflare {
            name = "Cloudflare"
            (status, data) = try await cloudflare(r)
        }
        if Self.busy(status) && !keys.key("mistral").isEmpty {
            name = "Mistral"
            (status, data) = try await post(mistral, key: keys.key("mistral"), r)
        }
        return try Self.chatAnswer(status, data, name)
    }

    private func cloudflareJson(_ r: AIRequest) async throws -> [String: Any] {
        guard !keys.key("cfAccount").isEmpty, !keys.key("cfToken").isEmpty else {
            throw AIError.message("Add your Cloudflare account ID and API token to start.")
        }
        var name = "Cloudflare"
        var (status, data) = try await cloudflare(r)
        if Self.busy(status) && !keys.key("groq").isEmpty {
            name = "Groq"
            (status, data) = try await post(groq, key: keys.key("groq"), r)
        }
        return try Self.chatAnswer(status, data, name)
    }

    private func openaiJson(_ r: AIRequest) async throws -> [String: Any] {
        let key = keys.key("openai")
        guard !key.isEmpty else { throw AIError.message("Add your OpenAI API key to start.") }
        let service = openai()
        var name = "OpenAI (\(service.model))"
        var (status, data) = try await post(service, key: key, r)
        if Self.busy(status) && !keys.key("groq").isEmpty {
            name = "Groq"
            (status, data) = try await post(groq, key: keys.key("groq"), r)
        }
        return try Self.chatAnswer(status, data, name)
    }

    private static func chatAnswer(_ status: Int, _ data: Data, _ name: String) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { throw failure(json, status, name) }
        let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        return try parseModelJson(content)
    }

    // MARK: Gemini

    private func geminiJson(_ r: AIRequest) async throws -> [String: Any] {
        guard !keys.key("gemini").isEmpty else { throw AIError.message("Add your Gemini API key to start.") }
        let contents: [[String: Any]] = r.messages.map { m -> [String: Any] in
            ["role": m.role == "assistant" ? "model" : "user", "parts": [["text": m.content]]]
        }
        let config: [String: Any] = ["responseMimeType": "application/json", "responseSchema": r.schema, "temperature": r.temperature]
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": contents,
            "generationConfig": config,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        func send(_ model: String, _ key: String) async throws -> (Int, Data) {
            let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            var req = URLRequest(url: URL(string: "\(geminiBase)/\(model):generateContent?key=\(encoded)")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = payload
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        var (status, data) = try await send(geminiModel, keys.key("gemini"))
        // When one model is overloaded or out of free quota, the other usually isn't.
        if status == 503 || status == 429 { (status, data) = try await send(geminiFallbackModel, keys.key("gemini")) }
        if status == 429 && !keys.key("gemini2").isEmpty {
            (status, data) = try await send(geminiModel, keys.key("gemini2"))
            if status == 503 || status == 429 { (status, data) = try await send(geminiFallbackModel, keys.key("gemini2")) }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { throw Self.failure(json, status, "Gemini") }
        let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        return try Self.parseModelJson(parts.compactMap { $0["text"] as? String }.joined())
    }

    // MARK: Helpers

    private static func failure(_ json: [String: Any], _ status: Int, _ name: String) -> AIError {
        let error = json["error"]
        let message = (error as? [String: Any])?["message"] as? String
            ?? error as? String
            ?? json["message"] as? String
            ?? json["detail"] as? String
            ?? "Request failed (\(status))"
        return .message("\(name): \(message)")
    }

    /// Some models put a sentence or a code fence around the JSON: take the object itself.
    static func parseModelJson(_ text: String) throws -> [String: Any] {
        if let data = text.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return obj
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let data = String(text[start...end]).data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return obj
        }
        throw AIError.message("The model returned an unreadable response. Please try again.")
    }
}

// MARK: - The turn format

enum Schema {
    private static func s(_ type: String) -> [String: Any] { ["type": type] }
    private static func strings(_ values: [String]) -> [String: Any] { ["type": "STRING", "enum": values] }
    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "ARRAY", "items": items] }
    private static func object(_ properties: [String: [String: Any]], required: [String], ordering: [String]? = nil) -> [String: Any] {
        var out: [String: Any] = ["type": "OBJECT", "properties": properties, "required": required]
        if let ordering { out["propertyOrdering"] = ordering }
        return out
    }

    static let turn: [String: Any] = object([
        "coach": object([
            "understood": s("BOOLEAN"),
            "correction": s("STRING"),
            "mistakes": array(strings(MistakeTypes.ordered.map { $0.key })),
            "tip": s("STRING"),
            "used_words": array(object(["word": s("STRING"), "correct": s("BOOLEAN")], required: ["word", "correct"])),
        ], required: ["understood", "correction", "mistakes", "tip", "used_words"],
           ordering: ["understood", "correction", "mistakes", "tip", "used_words"]),
        "mood": strings(Moods.all),
        "reply": s("STRING"),
        "reply_translation": s("STRING"),
        "suggestions": array(s("STRING")),
        "rapport_delta": s("INTEGER"),
        "conversation_finished": s("BOOLEAN"),
        "next_word": s("STRING"),
        "situation": s("STRING"),
        "subject": s("STRING"),
    ], required: ["coach", "mood", "reply", "reply_translation", "suggestions", "rapport_delta", "conversation_finished", "next_word", "situation"],
       ordering: ["coach", "mood", "reply", "reply_translation", "suggestions", "rapport_delta", "conversation_finished", "next_word", "situation", "subject"])

    /// The side coach of a live call.
    static let liveCoach: [String: Any] = object([
        "correction": s("STRING"),
        "mistakes": array(strings(MistakeTypes.ordered.map { $0.key })),
        "tip": s("STRING"),
    ], required: ["correction", "mistakes", "tip"], ordering: ["correction", "mistakes", "tip"])

    /// The subjects a live call has talked about.
    static let subjects: [String: Any] = object(["subjects": array(s("STRING"))], required: ["subjects"])

    /// Gemini's schema format as standard JSON Schema, without the "required" lists (the
    /// prompt says once that every field is required) and Gemini's propertyOrdering.
    private static func jsonSchema(_ s: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["type": (s["type"] as? String ?? "").lowercased()]
        if let props = s["properties"] as? [String: Any] {
            out["properties"] = props.mapValues { jsonSchema($0 as? [String: Any] ?? [:]) }
        }
        if let items = s["items"] as? [String: Any] { out["items"] = jsonSchema(items) }
        if let e = s["enum"] { out["enum"] = e }
        return out
    }

    /// The answer format for chat APIs, which get it as text.
    static func chatSystemContent(_ system: String, _ schema: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonSchema(schema), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "\(system)\n\nAnswer with only a JSON object with every field of this JSON Schema:\n\(String(data: data, encoding: .utf8) ?? "{}")"
    }
}

struct UsedWord {
    let word: String
    let correct: Bool
}

struct Coach {
    var understood = true
    var correction = ""
    var mistakes: [String] = []
    var tip = ""
    var usedWords: [UsedWord] = []
}

struct Turn {
    var coach = Coach()
    var mood = "neutral"
    var reply = ""
    var replyTranslation = ""
    var suggestions: [String] = []
    var rapportDelta = 0
    var finished = false
    var nextWord = ""
    var situation = ""
    var subject = ""
    var focusWords: [VocabWord] = []

    /// A turn with every field present and of the right type: Groq and Mistral only promise
    /// JSON, not this shape.
    init(_ raw: [String: Any]) {
        let str = { (v: Any?) -> String in v as? String ?? "" }
        let c = raw["coach"] as? [String: Any] ?? [:]
        coach = Coach(
            understood: (c["understood"] as? Bool) != false,
            correction: str(c["correction"]),
            mistakes: (c["mistakes"] as? [Any] ?? []).compactMap { $0 as? String },
            tip: str(c["tip"]),
            usedWords: (c["used_words"] as? [Any] ?? []).compactMap { u in
                guard let u = u as? [String: Any], let w = u["word"] as? String else { return nil }
                return UsedWord(word: w, correct: (u["correct"] as? Bool) == true)
            }
        )
        let m = str(raw["mood"])
        mood = Moods.all.contains(m) ? m : "neutral"
        reply = str(raw["reply"]).trimmingCharacters(in: .whitespacesAndNewlines)
        replyTranslation = str(raw["reply_translation"])
        // Plain strings, or objects such as {"text": …} from models that wrap each one.
        suggestions = (raw["suggestions"] as? [Any] ?? []).map { s -> String in
            if let s = s as? String { return s }
            if let o = s as? [String: Any] { return o.values.compactMap { $0 as? String }.first ?? "" }
            return ""
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        rapportDelta = (raw["rapport_delta"] as? NSNumber)?.intValue ?? 0
        finished = (raw["conversation_finished"] as? Bool) == true
        nextWord = str(raw["next_word"])
        situation = str(raw["situation"])
        subject = String(str(raw["subject"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(60))
    }
}

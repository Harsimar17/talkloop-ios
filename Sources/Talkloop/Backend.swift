// The Vocab Trainer's API (the Spring Boot backend in Harsimar17/Deutsch-Vocab-Trainer-V2). The app logs in with the
// trainer's account, swaps that login for a Talkloop link, and uses the link for everything
// else: the saved AI keys, the learnt words, and the synced mistake log and speaking schedule.
import Foundation

struct VocabWord: Codable, Hashable {
    var de: String
    var en: String
    var example: String
    var level: String
    var cat: String?
}

struct TrainerLink: Codable {
    var token: String
    var api: String
}

enum BackendError: LocalizedError {
    case loggedOut
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .loggedOut: return "Your Vocab Trainer login has ended: log in again."
        case let .http(code, message): return message.isEmpty ? "The Vocab Trainer answered \(code)." : message
        case .badResponse: return "The Vocab Trainer sent an answer the app can't read."
        }
    }
}

enum Backend {
    /// The deployed trainer. Change this for a local backend (e.g. http://192.168.1.20:8080).
    static var baseURL = "https://deutsch-vocab-trainer-v2-1.onrender.com"

    // The free server sleeps when unused, so the first call can take up to a minute.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct Response {
        let json: [String: Any]
        let http: HTTPURLResponse
    }

    @discardableResult
    static func call(_ path: String, api: String = baseURL, method: String = "GET", token: String? = nil,
                     body: Any? = nil, headers: [String: String] = [:]) async throws -> Response {
        guard let url = URL(string: api + path) else { throw BackendError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BackendError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 401 { throw BackendError.loggedOut }
        guard (200..<300).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["error"] as? String) ?? ""
            throw BackendError.http(http.statusCode, message)
        }
        return Response(json: json, http: http)
    }

    // MARK: Login

    struct Login {
        let token: String
        let email: String
    }

    static func login(email: String, password: String) async throws -> Login {
        do {
            let r = try await call("/api/auth/login", method: "POST", body: ["email": email, "password": password])
            guard let token = r.json["token"] as? String else { throw BackendError.badResponse }
            let user = r.json["user"] as? [String: String]
            return Login(token: token, email: user?["email"] ?? email)
        } catch BackendError.loggedOut {
            throw BackendError.http(401, "Wrong email or password.")
        }
    }

    /// Whether a JWT has not expired yet (its payload's `exp`).
    static func tokenValid(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let exp = payload["exp"] as? Double else { return false }
        return exp > Date().timeIntervalSince1970
    }

    /// Swaps the login for a Talkloop link. Returns the link and the renewed login, if any.
    static func link(sessionToken: String) async throws -> (TrainerLink, String?) {
        let r = try await call("/api/talkloop/link", method: "POST", token: sessionToken)
        guard let token = r.json["token"] as? String else { throw BackendError.badResponse }
        return (TrainerLink(token: token, api: baseURL), r.http.value(forHTTPHeaderField: "X-Auth-Token"))
    }

    // MARK: With the link

    static func keys(_ link: TrainerLink) async throws -> [String: String] {
        let r = try await call("/api/talkloop/keys", api: link.api, token: link.token)
        return r.json["keys"] as? [String: String] ?? [:]
    }

    /// Saves keys (an empty value removes one) and returns every saved key.
    static func saveKeys(_ link: TrainerLink, _ keys: [String: String]) async throws -> [String: String] {
        let r = try await call("/api/talkloop/keys", api: link.api, method: "POST", token: link.token, body: ["keys": keys])
        return r.json["keys"] as? [String: String] ?? [:]
    }

    /// Learnt words, the least secure first (the trainer sorts them).
    static func learntWords(_ link: TrainerLink) async throws -> [VocabWord] {
        let r = try await call("/api/talkloop/words", api: link.api, token: link.token)
        let words = r.json["words"] as? [[String: Any]] ?? []
        return words.compactMap { w in
            guard let de = w["de"] as? String else { return nil }
            return VocabWord(de: de, en: w["en"] as? String ?? "", example: w["example"] as? String ?? "",
                             level: w["lvl"] as? String ?? "", cat: w["cat"] as? String)
        }
    }

    /// POST to one of the sync routes (mistakes, spoken, sentences, used).
    static func sync(_ link: TrainerLink, _ route: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await call("/api/talkloop/\(route)", api: link.api, method: "POST", token: link.token, body: body).json
    }

    /// Cloudflare Workers AI goes through the trainer, which forwards the learner's own account and token.
    static func cloudflare(_ link: TrainerLink, account: String, token: String, body: [String: Any]) async throws -> (Int, Data) {
        guard let url = URL(string: link.api + "/api/talkloop/cloudflare") else { throw BackendError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(account, forHTTPHeaderField: "X-Cloudflare-Account")
        req.setValue(token, forHTTPHeaderField: "X-Cloudflare-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: Static data

    /// The whole word list (A1–B1), flattened as the web app's flattenVocab does.
    static func vocabList() async throws -> [VocabWord] {
        guard let url = URL(string: baseURL + "/data/german_vocab.json") else { return [] }
        let (data, _) = try await session.data(from: url)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let levels = json["levels"] as? [String: Any] else { throw BackendError.badResponse }
        var out: [VocabWord] = []
        func add(_ e: Any, _ level: String, _ cat: String) {
            guard let e = e as? [String: Any], let de = e["de"] as? String, !de.isEmpty else { return }
            out.append(VocabWord(de: de, en: e["en"] as? String ?? "", example: e["example"] as? String ?? "", level: level, cat: cat))
        }
        for (level, cats) in levels {
            for (cat, v) in cats as? [String: Any] ?? [:] {
                if let list = v as? [Any] { list.forEach { add($0, level, cat) } }
                else if let sub = v as? [String: Any] {
                    for (_, list) in sub { (list as? [Any])?.forEach { add($0, level, cat) } }
                }
            }
        }
        return out
    }

    static func connectors() async throws -> [Connector] {
        guard let url = URL(string: baseURL + "/data/connectors.json") else { return [] }
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([Connector].self, from: data)
    }
}

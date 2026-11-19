// What Talkloop learns about the learner: the mistake log, the speaking schedule of their
// learnt words, and how a "say it again" try is checked. Both logs sync with the trainer,
// so they are the same as in the web app.
import Foundation

// MARK: - Text helpers

enum TextMatch {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\b2\\b", with: "zwei", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func wordCount(_ t: String) -> Int { t.split(separator: " ").count }
    private static func has(_ t: String, _ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

    /// "zwei Minuten" pauses the call (only short utterances count).
    static func isPause(_ text: String) -> Bool {
        let t = normalize(text)
        return wordCount(t) <= 4 && has(t, "\\bzwei minuten\\b")
    }

    static func isSkip(_ text: String) -> Bool {
        let t = normalize(text)
        return wordCount(t) <= 3 && has(t, "(?<!\\p{L})(weiter|überspringen|skip|next)(?!\\p{L})")
    }

    /// Which of today's words the model means: it may drop or change the article.
    static func bare(_ s: String) -> String {
        normalize(s).replacingOccurrences(of: "^(der|die|das) ", with: "", options: .regularExpression)
    }

    /// A card can hold alternatives ("zuerst / dann / danach"): each one counts.
    static func forms(_ de: String) -> [String] {
        let parts = de.components(separatedBy: CharacterSet(charactersIn: "/;")).map(bare)
        return ([bare(de)] + parts).filter { !$0.isEmpty }
    }

    static func isWord(_ w: VocabWord, _ word: String) -> Bool { forms(w.de).contains(bare(word)) }

    /// Whether a text contains a word (at a word start); a long verb also by its stem.
    static func says(_ text: String, _ de: String) -> Bool {
        let hay = " " + normalize(text)
        return forms(de).contains { word in
            if hay.contains(" " + word) { return true }
            guard !word.contains(" "), word.count >= 7 else { return false }
            let stem = word.replacingOccurrences(of: "e?n$", with: "", options: .regularExpression)
            return hay.contains(" " + stem)
        }
    }
}

// MARK: - Say it again

enum Drill {
    static func words(_ text: String) -> [String] {
        TextMatch.normalize(text.replacingOccurrences(of: "ß", with: "ss")).split(separator: " ").map(String.init)
    }

    static func editDistance<T>(_ a: [T], _ b: [T], same: (T, T) -> Bool) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var row = [i]
            for j in 1...b.count {
                row.append(min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (same(a[i - 1], b[j - 1]) ? 0 : 1)))
            }
            prev = row
        }
        return prev[b.count]
    }

    /// Speech recognition mishears a little, so long words may be one letter off.
    static func sameWord(_ x: String, _ y: String) -> Bool {
        x == y || (min(x.count, y.count) >= 6 && editDistance(Array(x), Array(y), same: ==) <= 1)
    }

    static func similarity(_ a: [String], _ b: [String], same: (String, String) -> Bool = sameWord) -> Double {
        1 - Double(editDistance(a, b, same: same)) / Double(max(a.count, b.count, 1))
    }

    /// Worth drilling: a real change from what was said, short enough to say in one go.
    static func drillable(_ correction: String, said: String) -> Bool {
        let fix = words(correction)
        return !fix.isEmpty && fix.count <= 30 && fix.joined(separator: " ") != words(said).joined(separator: " ")
    }

    /// Did the attempt say the corrected sentence? Every changed word exactly, close to the
    /// correction overall, and closer to it than to the original mistake.
    static func match(attempt: String, target: String, said: String) -> (ok: Bool, missing: [String]) {
        let a = words(attempt), t = words(target), s = words(said)
        var pool: [String: Int] = [:]
        for w in s { pool[w, default: 0] += 1 }
        let changed = t.filter { w in
            let n = pool[w] ?? 0
            pool[w] = n - 1
            return n <= 0
        }
        var missing: [String] = []
        for w in changed where !a.contains(w) && !missing.contains(w) { missing.append(w) }
        let close = similarity(a, t)
        return (missing.isEmpty && close >= 0.75 && close > similarity(a, s, same: ==), missing)
    }
}

// MARK: - Mistake log

struct MistakeEntry: Codable, Hashable {
    var type: String
    var at: Double
    var said: String
    var fix: String
}

enum Mistakes {
    private static let halfLifeDays = 7.0

    static var log: [String: [MistakeEntry]] {
        get { Store.get("mistakes", [String: [MistakeEntry]]()) }
        set { Store.set("mistakes", newValue) }
    }
    static var resets: [String: Double] {
        get { Store.get("mistake_resets", [String: Double]()) }
        set { Store.set("mistake_resets", newValue) }
    }

    static func record(language: String, types: [String], said: String, fix: String) {
        let at = nowMs()
        var all = log
        all[language] = Array(((all[language] ?? []) + types.map { MistakeEntry(type: $0, at: at, said: said, fix: fix) }).suffix(300))
        log = all
    }

    /// Mistake kinds by how much they still matter: each counts less as it ages.
    static func ranked(language: String) -> [WeakSpot] {
        let now = nowMs()
        var order: [String] = []
        var byType: [String: (count: Int, weight: Double, example: MistakeEntry)] = [:]
        for m in log[language] ?? [] {
            var t = byType[m.type] ?? (count: 0, weight: 0.0, example: m)
            if byType[m.type] == nil { order.append(m.type) }
            t.count += 1
            t.weight += pow(0.5, (now - m.at) / 86_400_000 / halfLifeDays)
            t.example = m // oldest first, so this ends on the newest
            byType[m.type] = t
        }
        return order.compactMap { type in
            guard MistakeTypes.labels[type] != nil, let t = byType[type] else { return nil }
            return WeakSpot(type: type, count: t.count, weight: t.weight, example: t.example)
        }
        .sorted { $0.weight > $1.weight }
    }

    /// The top 3 that recur, which the partner deliberately tests.
    static func recurring(language: String) -> [WeakSpot] {
        Array(ranked(language: language).filter { $0.count >= 2 && $0.type != "other" }.prefix(3))
    }

    static func reset(language: String) {
        var r = resets
        r[language] = nowMs()
        resets = r
        var all = log
        all[language] = []
        log = all
    }

    private static func entryJSON(_ m: MistakeEntry) -> [String: Any] {
        ["type": m.type, "at": m.at, "said": m.said, "fix": m.fix]
    }

    /// Sends what this device recorded since its last sync and takes the trainer's merged log.
    static func sync(_ link: TrainerLink) async {
        let startedAt = nowMs()
        let since = Store.get("mistakes_synced_at", 0.0)
        let local = log, localResets = resets
        var languages: [String: Any] = [:]
        for language in Set(local.keys).union(localResets.keys) {
            languages[language] = [
                "resetAt": localResets[language] ?? 0,
                "entries": (local[language] ?? []).filter { $0.at >= since }.map(entryJSON),
            ] as [String: Any]
        }
        guard let reply = try? await Backend.sync(link, "mistakes", ["languages": languages]),
              let merged = reply["languages"] as? [String: Any] else { return }
        // The merged log replaces this device's, keeping anything recorded during the sync.
        var newLog = log
        var newResets = resets
        for (language, value) in merged {
            guard let v = value as? [String: Any] else { continue }
            let resetAt = max(newResets[language] ?? 0, (v["resetAt"] as? NSNumber)?.doubleValue ?? 0)
            newResets[language] = resetAt
            let entries: [MistakeEntry] = (v["entries"] as? [[String: Any]] ?? []).compactMap { e in
                guard let type = e["type"] as? String, let at = (e["at"] as? NSNumber)?.doubleValue else { return nil }
                return MistakeEntry(type: type, at: at, said: e["said"] as? String ?? "", fix: e["fix"] as? String ?? "")
            }
            let seen = Set(entries.map { "\($0.at)|\($0.type)|\($0.said)" })
            let late = (newLog[language] ?? []).filter { $0.at >= startedAt && !seen.contains("\($0.at)|\($0.type)|\($0.said)") }
            newLog[language] = Array((entries + late).filter { $0.at > resetAt }.sorted { $0.at < $1.at }.suffix(300))
        }
        resets = newResets
        log = newLog
        Store.set("mistakes_synced_at", startedAt)
    }
}

// MARK: - Speaking schedule

/// Knowing a word isn't the same as saying it without thinking: each call has a few of
/// "today's words", shown in English and elicited (never said first) by the partner. Said
/// correctly on a new day, a word moves up a stage; at stage 4 it is automatic.
struct SpokenEntry: Codable {
    var stage: Int
    var due: Double
    var uses: Int
    var lastDay: String
    var updatedAt: Double
}

struct WordStatus {
    var correct = 0
    var wrong = 0
    var peeked = false
}

final class TodayWords {
    static let count = 5
    static let doneAfter = 2 // correct uses in one call before a word makes room for the next
    private static let days: [Double] = [1, 3, 7, 21]
    private static let automaticRecheckDays = 60.0

    var active: [VocabWord]
    var waiting: [VocabWord]
    var status: [String: WordStatus] = [:]
    var asked: [String: [Int]] = [:]
    var situation: String?
    var current: String?

    static var spoken: [String: SpokenEntry] {
        get { Store.get("spoken", [String: SpokenEntry]()) }
        set { Store.set("spoken", newValue) }
    }

    /// Due words first (least secure first), then words never said. A drill also takes
    /// words not due yet, the soonest due first, so it never runs dry.
    init(learnt: [VocabWord], evenIfNotDue: Bool) {
        let spoken = Self.spoken
        let now = nowMs()
        let due = learnt.filter { (spoken[$0.de]?.due ?? .infinity) <= now }
            .sorted { a, b in
                let x = spoken[a.de]!, y = spoken[b.de]!
                return x.stage != y.stage ? x.stage < y.stage : x.due < y.due
            }
        let later = evenIfNotDue
            ? learnt.filter { (spoken[$0.de]?.due ?? 0) > now }.sorted { spoken[$0.de]!.due < spoken[$1.de]!.due }
            : []
        let order = due + learnt.filter { spoken[$0.de] == nil } + later
        active = Array(order.prefix(Self.count))
        waiting = Array(order.dropFirst(Self.count))
    }

    var correctSet: Set<String> { Set(status.filter { $0.value.correct > 0 }.map { $0.key }) }

    func find(_ word: String) -> VocabWord? { active.first { TextMatch.isWord($0, word) } }

    private static func set(_ de: String, _ entry: SpokenEntry) {
        var all = spoken
        var e = entry
        e.updatedAt = nowMs()
        all[de] = e
        spoken = all
    }

    /// Said correctly without peeking: up a stage, once per day.
    private static func correct(_ de: String) {
        let prev = spoken[de]
        let day = localDay()
        if let prev, prev.lastDay == day {
            var e = prev
            e.uses += 1
            set(de, e)
            return
        }
        let stage = min(4, (prev?.stage ?? 0) + 1)
        let wait = prev?.stage == 4 ? automaticRecheckDays : days[stage - 1]
        set(de, SpokenEntry(stage: stage, due: nowMs() + wait * 86_400_000, uses: (prev?.uses ?? 0) + 1, lastDay: day, updatedAt: 0))
    }

    /// Wrong, or needed the German shown: back to stage 1 (0 if never said), due tomorrow.
    private static func missed(_ de: String) {
        let prev = spoken[de]
        set(de, SpokenEntry(stage: prev.map { min($0.stage, 1) } ?? 0, due: nowMs() + 86_400_000,
                            uses: prev?.uses ?? 0, lastDay: prev?.lastDay ?? "", updatedAt: 0))
    }

    /// The coach's used_words for the learner's last message.
    func record(_ used: [UsedWord]) {
        for u in used {
            guard let w = find(u.word) else { continue }
            var s = status[w.de] ?? WordStatus()
            if u.correct {
                s.correct += 1
                if !s.peeked { Self.correct(w.de) } // after a peek it counts for this call only
            } else {
                s.wrong += 1
                Self.missed(w.de)
            }
            status[w.de] = s
        }
        // A word said correctly often enough makes room for the next one.
        for w in active where (status[w.de]?.correct ?? 0) >= Self.doneAfter {
            guard let i = active.firstIndex(of: w) else { continue }
            if waiting.isEmpty { active.remove(at: i) } else { active[i] = waiting.removeFirst() }
        }
    }

    func peek(_ de: String) {
        var s = status[de] ?? WordStatus()
        if s.peeked || s.correct > 0 { return }
        s.peeked = true
        status[de] = s
        Self.missed(de)
    }

    static var automaticCount: Int { spoken.values.filter { $0.stage >= 4 }.count }

    /// Like the mistake sync: sends what changed since the last sync, keeps the newer of each entry.
    static func sync(_ link: TrainerLink) async {
        let startedAt = nowMs()
        let since = Store.get("spoken_synced_at", 0.0)
        var changed: [String: Any] = [:]
        for (de, s) in spoken where s.updatedAt >= since {
            changed[de] = ["stage": s.stage, "due": s.due, "uses": s.uses, "lastDay": s.lastDay, "updatedAt": s.updatedAt] as [String: Any]
        }
        guard let reply = try? await Backend.sync(link, "spoken", ["words": changed]),
              let merged = reply["words"] as? [String: Any] else { return }
        var local = spoken
        for (de, value) in merged {
            guard let v = value as? [String: Any] else { continue }
            let num = { (k: String) in (v[k] as? NSNumber)?.doubleValue ?? 0 }
            let entry = SpokenEntry(stage: Int(num("stage")), due: num("due"), uses: Int(num("uses")),
                                    lastDay: v["lastDay"] as? String ?? "", updatedAt: num("updatedAt"))
            if local[de].map({ entry.updatedAt > $0.updatedAt }) ?? true { local[de] = entry }
        }
        spoken = local
        Store.set("spoken_synced_at", startedAt)
    }
}

// MARK: - Streak

enum Streak {
    private struct Saved: Codable { var count: Int; var last: String? }

    static var count: Int { Store.get("streak", Saved(count: 0, last: nil)).count }

    static func bump() {
        var s = Store.get("streak", Saved(count: 0, last: nil))
        let today = localDay()
        if s.last == today { return }
        s.count = s.last == localDay(nowMs() - 86_400_000) ? s.count + 1 : 1
        s.last = today
        Store.set("streak", s)
    }
}

// MARK: - Second grammar check (LanguageTool)

/// Every AI now and then misses a mistake. LanguageTool's free public API checks the sentence
/// too, alongside the AI; when the coach found nothing, its grammar and spelling fixes become
/// the correction.
enum LanguageTool {
    struct Match {
        let offset: Int
        let length: Int
        let replacement: String
        let message: String
        let ruleId: String
        let misspelling: Bool
    }

    static var enabled: Bool {
        get { Store.get("grammar_check", true) }
        set { Store.set("grammar_check", newValue) }
    }

    static func check(_ text: String, locale: String) async -> [Match]? {
        var req = URLRequest(url: URL(string: "https://api.languagetool.org/v2/check")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4 // checked alongside the AI: it must never hold up a reply for long
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "language", value: locale)]
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return nil }
        return (json["matches"] as? [[String: Any]] ?? []).compactMap { m in
            let rule = m["rule"] as? [String: Any] ?? [:]
            let category = (rule["category"] as? [String: Any])?["id"] as? String
            let misspelling = rule["issueType"] as? String == "misspelling"
            guard category == "GRAMMAR" || misspelling,
                  let value = (m["replacements"] as? [[String: Any]])?.first?["value"] as? String, !value.isEmpty,
                  let offset = m["offset"] as? Int, let length = m["length"] as? Int else { return nil }
            let short = m["shortMessage"] as? String ?? ""
            return Match(offset: offset, length: length, replacement: value,
                         message: short.isEmpty ? (m["message"] as? String ?? "") : short,
                         ruleId: rule["id"] as? String ?? "", misspelling: misspelling)
        }
    }

    /// The kind of mistake, from LanguageTool's rule, for the mistake log.
    private static func kind(_ m: Match, said: NSString) -> String {
        if m.ruleId.range(of: "HILFSVERB", options: .regularExpression) != nil { return "perfekt_auxiliary" }
        if m.ruleId.range(of: "PRAEP|AGREEMENT|KONGRUENZ|ARTIKEL|GENUS|DE_CASE", options: .regularExpression) != nil { return "case_article" }
        if m.misspelling, m.offset + m.length <= said.length,
           said.substring(with: NSRange(location: m.offset, length: m.length)).lowercased().hasPrefix("ge") { return "participle" }
        return "other"
    }

    /// When the AI found nothing, LanguageTool's fixes (applied from the end, so the offsets
    /// stay right) become the coach's correction.
    static func apply(_ matches: [Match]?, to coach: inout Coach, said: String) {
        guard let matches, !matches.isEmpty, coach.correction.isEmpty else { return }
        let ns = NSMutableString(string: said)
        var end = Int.max
        for m in matches.sorted(by: { $0.offset > $1.offset }) {
            guard m.offset + m.length <= end, m.offset + m.length <= ns.length else { continue }
            ns.replaceCharacters(in: NSRange(location: m.offset, length: m.length), with: m.replacement)
            end = m.offset
        }
        let corrected = ns as String
        guard corrected != said else { return }
        coach.correction = corrected
        var kinds: [String] = []
        for m in matches { let k = kind(m, said: said as NSString); if !kinds.contains(k) { kinds.append(k) } }
        coach.mistakes = kinds
        coach.tip = "Grammar check: " + matches.map(\.message).joined(separator: " ")
    }
}

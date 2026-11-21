// Talkloop's conversation engine: speech in, an AI partner's turn out, spoken back with word
// highlighting, corrections said again, and the learner's words and mistakes tracked.
// Ported from Deutsch-Vocab-Trainer-V2: frontend/src/talkloop/engine.js (the parts this app has; see README).
import Foundation
import SwiftUI

// MARK: - Screen state

struct SetupForm: Codable, Equatable {
    var language = "German"
    var native = "English"
    var level = "A1"
    var mode = "lead"
    var tense = "any"
    var scenario = "cafe"
    var connector = "mix"
    var useVocab = true
    var sayAgain = true
}

struct ChatMessage: Identifiable {
    enum Kind { case learner, character }
    let id = UUID()
    let kind: Kind
    let who: String
    var text: String // grows while a live call's partner speaks
    var translation = ""
    var showTranslation = false
    var mood = "neutral"
    /// The characters being spoken right now, for the highlight.
    var speaking: NSRange?
}

struct CoachCard {
    let understood: Bool
    let correction: String
    let tip: String
}

struct DrillCard {
    let target: String
    var feedback = ""
    var ok = false
}

struct WordChip: Identifiable {
    enum State { case plain, said, tried }
    let id: String // the German word
    let text: String
    let state: State
    let current: Bool
    let peekable: Bool
}

struct CallRecap {
    let said: [String]
    let tried: [String]
    let missed: [String]
    let automatic: Int
}

enum Screen { case loading, keys, setup, call }

/// What one call is about, fixed when it starts.
struct CallSettings {
    var locale: String
    var characterName: String
    var vocabEnabled: Bool
    var learnt: Bool
    var sayAgain: Bool
    var request: CallRequest
    var topic: String?
    var roleCard: String?
    var connectors: [Connector] = []
    var subjects: [String] = []
    var themes: [String] = []
    var sayThis: String?
    var joinThis: String?
    var given: [String] = []
    /// A Gemini Live voice call instead of turn by turn.
    var live = false
}

/// "Say it again" while it runs. In a live call Gemini asks for the repeat itself, so there is no reply to hold back.
struct DrillState {
    let id = UUID()
    let said: String
    let turn: Turn?
    var live = false
    var tries = 0
}

@MainActor
final class TalkloopEngine: ObservableObject {
    // Setup and keys
    @Published var screen: Screen = .loading
    @Published var form = Store.get("form", SetupForm()) {
        didSet { Store.set("form", form) }
    }
    /// "Live voice call (Gemini Live)" on the setup screen, remembered on this phone.
    @Published var liveVoice = Store.get("live_voice", false) {
        didSet { Store.set("live_voice", liveVoice) }
    }
    @Published var grammarCheck = LanguageTool.enabled {
        didSet { LanguageTool.enabled = grammarCheck }
    }
    @Published private(set) var keys = KeyRing()
    @Published var keyStatus = ""
    @Published var editingSavedKeys = false
    @Published var trainerStatus = ""
    @Published var vocabStatus = ""
    @Published private(set) var connectorGroups: [ChoiceGroup] = []
    @Published private(set) var recap: CallRecap?
    @Published private(set) var streak = Streak.count
    @Published private(set) var mistakesVersion = 0

    // The call
    @Published private(set) var transcript: [ChatMessage] = []
    @Published private(set) var coach: CoachCard?
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var chips: [WordChip] = []
    @Published private(set) var chipsLabel = ""
    @Published private(set) var drill: DrillCard?
    @Published private(set) var sayThis: (label: String, text: String)?
    @Published private(set) var heard = ""
    @Published var status = "" {
        didSet { if !status.isEmpty && status != oldValue { debug("status: \(status)") } }
    }
    @Published private(set) var busy = false
    @Published private(set) var micOn = false
    @Published private(set) var paused = false
    @Published private(set) var autoSend = true
    @Published var composer = ""
    @Published private(set) var callName = ""
    @Published private(set) var callMode = ""
    @Published private(set) var callTopic = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var rapport = 0

    private let sessionToken: () -> String?
    private let onRenewedToken: (String) -> Void
    private let onLoggedOut: () -> Void

    private var settings: CallSettings?
    private var history: [AIMessage] = []
    private var finished = false
    private var handsFree = false
    private var drillTurn: DrillState?
    // The running live call, if any (see startLive).
    private var live: LiveCall?
    @Published private(set) var liveSpeaking = false
    private var liveRetries = 0 // reconnects in a row that didn't get the call going again
    private var liveReconnectPending = false // dropped while paused: reconnect on resume
    private var liveReplyId: UUID? // the bubble that grows while the partner speaks
    private var liveLastReply = ""
    private var liveLearnerTurns = 0
    private var today: TodayWords?
    private var pendingReply: (id: UUID, turn: Turn)?
    private var timer: Task<Void, Never>?

    private var allVocab: [VocabWord] = []
    private var learnt: [VocabWord]?
    private var connectorList: [Connector] = []
    private var vocabPools: [(words: [VocabWord], pointer: Int)] = []
    private var vocabBatch: [VocabWord] = []

    private let listener = Listener()
    private let speaker = Speaker()
    // A live call shows as a phone call on the lock screen (CallKit), with End and Mute.
    private let phone = PhoneCall()

    init(sessionToken: @escaping () -> String?, onRenewedToken: @escaping (String) -> Void, onLoggedOut: @escaping () -> Void) {
        self.sessionToken = sessionToken
        self.onRenewedToken = onRenewedToken
        self.onLoggedOut = onLoggedOut
        listener.onHeard = { [weak self] text in self?.heard = text }
        listener.onEnd = { [weak self] text in
            guard let self else { return }
            self.micOn = false
            self.heard = ""
            self.afterListening(text)
        }
        listener.onError = { [weak self] message in
            guard let self else { return }
            self.micOn = false
            self.handsFree = false
            self.status = message
        }
        phone.onEnd = { [weak self] in
            guard let self, self.settings != nil else { return }
            self.endCall()
        }
        phone.onMute = { [weak self] on in self?.setLiveMuted(on) }
        phone.onHold = { [weak self] on in self?.setPaused(on) }
        phone.onAudioActive = { [weak self] in self?.live?.audioResumed() }
    }

    // MARK: - Starting up

    private static let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    private static func cache<T: Codable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func cache<T: Codable>(_ name: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: cacheDir.appendingPathComponent(name)) }
    }

    /// Links to the trainer with the login, loads the saved keys, then the words in the background.
    func start() async {
        allVocab = Self.cache("vocab.json") ?? []
        learnt = Self.cache("learnt.json")
        keyStatus = "Loading your saved AI keys…"
        trainerStatus = "Connecting to your Vocab Trainer… (it can take up to a minute to wake up)"
        var link: TrainerLink? = Store.get("trainer_link", TrainerLink?.none)
        if let token = sessionToken() {
            do {
                let (fresh, renewed) = try await Backend.link(sessionToken: token)
                if let renewed { onRenewedToken(renewed) }
                link = fresh
                Store.set("trainer_link", fresh)
            } catch BackendError.loggedOut {
                Store.remove("trainer_link")
                onLoggedOut()
                return
            } catch {
                // Offline or the server asleep: the link from last time still works.
            }
        }
        keys.link = link
        if let link, let saved = try? await Backend.keys(link) { keys.keys = saved }
        keyStatus = ""
        refreshKeyGate()

        Task { await loadWords() }
        Task {
            if let list = try? await Backend.connectors() {
                connectorList = list
                connectorGroups = ["A1", "A2", "B1"].map { level in
                    ChoiceGroup(label: level, options: list.filter { $0.level == level }.map { Choice(value: $0.key, label: "\($0.name) — \($0.en)") })
                }
                if form.connector != "mix" && !list.contains(where: { $0.key == form.connector }) { form.connector = "mix" }
            }
        }
        if let link {
            Task {
                await Mistakes.sync(link)
                mistakesVersion += 1
                await TodayWords.sync(link)
            }
        }
    }

    private func loadWords() async {
        if let list = try? await Backend.vocabList(), !list.isEmpty {
            allVocab = list
            Self.cache("vocab.json", list)
        }
        if let link = keys.link {
            do {
                let words = try await Backend.learntWords(link)
                learnt = words
                Self.cache("learnt.json", words)
            } catch BackendError.loggedOut {
                onLoggedOut()
                return
            } catch {
                trainerStatus = error.localizedDescription
            }
        }
        let b1 = (learnt ?? []).filter { !["A1", "A2"].contains($0.level) }.count
        trainerStatus = keys.link == nil
            ? "Not linked to your Vocab Trainer: log in again to use your learnt words."
            : "🔗 Linked to your Vocab Trainer · your partner uses all A1 and A2 words plus \(b1 > 0 ? "the \(b1) B1 words you have learnt there" : "your learnt B1 words (none yet)")."
        if !allVocab.isEmpty && vocabStatus.isEmpty { vocabStatus = "✓ \(allVocab.count) words ready." }
    }

    // MARK: - Keys

    func refreshKeyGate() {
        let ready = keys.ready(keys.provider)
        if screen != .call { screen = ready ? .setup : .keys }
    }

    var aiChoices: [Choice] { Options.providers.filter { keys.ready($0.value) } }

    func chooseAi(_ provider: String) {
        KeyRing.setProvider(provider)
        objectWillChange.send()
        refreshKeyGate()
    }

    func changeKeys() {
        screen = .keys
    }

    /// The key fields shown for a provider: a saved key needs no field unless the learner edits saved keys.
    func keyFields(for provider: String) -> [String] {
        let shownFor: [String: [String]?] = [
            "openai": ["openai"], "mistral": ["groq"], "groq": ["groq", "openai"], "groq2": ["groq"], "groq3": ["groq"],
            "cfAccount": ["groq", "cloudflare"], "cfToken": ["groq", "cloudflare"], "gemini": nil, "gemini2": nil, "geminiLive": nil,
        ]
        let cfSaved = !keys.key("cfAccount").isEmpty || !keys.key("cfToken").isEmpty
        return KeyRing.services.filter { service in
            guard let providers = shownFor[service] else { return false }
            if let providers, !providers.contains(provider) { return false }
            if (service == "cfAccount" || service == "cfToken") && cfSaved && !editingSavedKeys { return false }
            return editingSavedKeys || keys.key(service).isEmpty
        }
    }

    /// `typed`: service -> what was typed in its field.
    func saveKeys(provider: String, typed: [String: String], openaiModel: String) async -> Bool {
        let has = { (s: String) in !(typed[s] ?? "").isEmpty || !self.keys.key(s).isEmpty }
        let missing = provider == "cloudflare" ? !(has("cfAccount") && has("cfToken")) : !has(provider)
        if missing {
            let names = ["openai": "OpenAI", "groq": "Groq", "gemini": "Gemini"]
            keyStatus = provider == "cloudflare" ? "Paste your Cloudflare account ID and API token first." : "Paste your \(names[provider] ?? provider) API key first."
            return false
        }
        let toSave = typed.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        if !toSave.isEmpty {
            guard let link = keys.link else {
                keyStatus = "Not linked to the Vocab Trainer: log in again."
                return false
            }
            keyStatus = "Saving to your account…"
            do {
                keys.keys = try await Backend.saveKeys(link, toSave)
            } catch {
                keyStatus = error.localizedDescription
                return false
            }
        }
        editingSavedKeys = false
        let model = openaiModel.trimmingCharacters(in: .whitespaces)
        if provider == "openai" && !model.isEmpty { Store.set("openai_model", model) }
        KeyRing.setProvider(provider)
        keyStatus = ""
        refreshKeyGate()
        return true
    }

    // MARK: - Vocabulary for a call

    private static let knownLevels = ["A1", "A2"]

    /// Linked: every A1/A2 word, shuffled, plus the learnt B1 words in the trainer's order
    /// (the shakiest first). Each pool rotates on its own.
    private func loadVocab(levels: [String], learnt: [VocabWord]?) -> Int {
        let all = allVocab.filter { levels.contains($0.level) }
        var pools: [[VocabWord]]
        if let learnt {
            pools = [learnt.filter { levels.contains($0.level) && !Self.knownLevels.contains($0.level) },
                     all.filter { Self.knownLevels.contains($0.level) }.shuffled()]
        } else {
            pools = [all.shuffled()]
        }
        vocabPools = pools.filter { !$0.isEmpty }.map { (words: $0, pointer: 0) }
        vocabBatch = []
        return vocabPools.reduce(0) { $0 + $1.words.count }
    }

    /// The words for this turn: last turn's minus the oldest two, topped up from the pools.
    /// A steady set lets the partner bring each word in once the talk gets there.
    private func nextVocabBatch(_ n: Int) -> [VocabWord] {
        let drop = min(2, vocabBatch.count)
        var batch = Array(vocabBatch[drop..<max(drop, min(n, vocabBatch.count))])
        var fresh: [VocabWord] = []
        for i in vocabPools.indices {
            let remainingPools = vocabPools.count - i
            let share = Int((Double(n - batch.count - fresh.count) / Double(remainingPools)).rounded(.up))
            var k = 0, tries = 0
            while k < share && tries < vocabPools[i].words.count {
                let word = vocabPools[i].words[vocabPools[i].pointer % vocabPools[i].words.count]
                vocabPools[i].pointer += 1
                tries += 1
                if batch.contains(word) || fresh.contains(word) { continue }
                fresh.append(word)
                k += 1
            }
        }
        batch += fresh
        vocabBatch = batch
        return batch
    }

    // MARK: - Starting a call

    func startConversation() async {
        let f = form
        let mode = Modes.get(f.mode)
        let useVocab = f.useVocab && !allVocab.isEmpty && !mode.joiner
        let allLevels = ["A1", "A2", "B1"]
        let levels = Array(allLevels.prefix((allLevels.firstIndex(of: f.level) ?? 2) + 1))

        var vocabEnabled = false
        var linkedWords: [VocabWord]? = nil
        today = nil
        if useVocab {
            linkedWords = keys.link != nil ? (learnt ?? []) : nil
            vocabEnabled = loadVocab(levels: levels, learnt: linkedWords) > 0
            if let linkedWords {
                today = TodayWords(learnt: linkedWords.filter { levels.contains($0.level) }, evenIfNotDue: mode.drill)
            } else if mode.drill {
                today = TodayWords(learnt: allVocab.filter { levels.contains($0.level) }.shuffled(), evenIfNotDue: true)
            }
        }
        if mode.joiner && connectorList.isEmpty {
            do { connectorList = try await Backend.connectors() } catch {
                vocabStatus = "Couldn't load the connectors: \(error.localizedDescription)"
                return
            }
        }
        if mode.drill && (today?.active.isEmpty ?? true) {
            vocabStatus = useVocab
                ? "The sentence drill has no words to practise yet: learn some in the Vocab Trainer, or come back when some are due."
                : "The sentence drill practises your vocabulary: turn on “Weave my vocab into the conversation” first."
            return
        }
        // Gemini Live, except for the sentence drill, which needs the word chips of a normal call.
        let isLive = liveVoice && !mode.drill
        if isLive && keys.liveKey.isEmpty {
            vocabStatus = "The live voice call needs a Gemini key: tap “Add or change keys” and add your Gemini (or Gemini Live) key, or turn the live voice call off."
            return
        }

        var s = CallSettings(
            locale: Options.locale(for: f.language),
            characterName: Content.persona(scenario: f.scenario, mode: f.mode).character,
            vocabEnabled: vocabEnabled,
            learnt: linkedWords != nil,
            sayAgain: f.sayAgain,
            request: CallRequest(language: f.language, nativeLanguage: f.native, level: f.level, scenario: f.scenario, mode: f.mode, tense: f.tense)
        )
        if mode.topics {
            let topic = Content.pickTopic(level: f.level, recent: Store.get("used_topics", [String]()))
            s.topic = topic
            Store.set("used_topics", Array(([topic] + Store.get("used_topics", [String]()).filter { $0 != topic }).prefix(100)))
        }
        if mode.roleCard {
            let card = Content.makeRoleCard(recent: Recent.items("role-cards", 6))
            Recent.note("role-cards", card)
            s.roleCard = card
        }
        if mode.joiner { s.connectors = ConnectorTypes.pool(connectorList, key: f.connector, level: f.level) }
        s.live = isLive
        if let themes = mode.themes {
            s.themes = Themes.pick(themes == "story" ? Themes.story : Themes.talk, used: Store.get("used_subjects", [String]()))
            if let first = s.themes.first { s.subjects = [first] }
        }
        settings = s

        // Hands-free from the start: the mic opens once the opening line is spoken.
        handsFree = await AudioSession.requestPermissions()
        if !handsFree { status = "Allow the microphone and speech recognition in Settings to talk. You can still type." }

        Streak.bump()
        streak = Streak.count
        history = []
        finished = false
        rapport = 0
        transcript = []
        coach = nil
        suggestions = []
        drill = nil
        drillTurn = nil
        pendingReply = nil
        paused = false
        autoSend = true
        composer = ""
        recap = nil
        enterCall(s, mode: mode)
        renderChips([])
        if isLive {
            // Gemini listens itself: Apple's speech recognition stays off.
            handsFree = false
            LiveCall.clearHandle() // a new call: Gemini's copy of the last one doesn't belong to it
            liveRetries = 0
            liveLearnerTurns = 0
            liveLastReply = ""
            phone.start(partner: s.characterName)
            await startLive()
        } else {
            await sendTurn("")
        }
    }

    private func enterCall(_ s: CallSettings, mode: Mode) {
        let tense = Tenses.all[s.request.tense]
        let sceneLabel = Options.scenes.flatMap(\.options).first { $0.value == s.request.scenario }?.label.components(separatedBy: " — ").first ?? ""
        let base = mode.usesScene ? sceneLabel : (mode.label.components(separatedBy: " — ").first ?? mode.label)
        callName = s.characterName
        callMode = "\(base) · \(s.request.language)" + (tense.map { " · \($0.short)" } ?? "")
        if let topic = s.topic { callTopic = "Topic: \(topic)" }
        else if let card = s.roleCard { callTopic = "You are: \(card)" }
        else if mode.joiner, s.connectors.count == 1, let c = s.connectors.first { callTopic = "„\(c.name)“ (\(c.en)) — \(c.rule ?? "")" }
        else { callTopic = "" }
        renderSayThis()
        elapsed = 0
        screen = .call
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if !self.paused { self.elapsed += 1 }
            }
        }
    }

    // MARK: - A turn

    func sendTurn(_ message: String) async {
        guard !busy, !finished, let s = settings else { return }
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty {
            transcript.append(ChatMessage(kind: .learner, who: "You", text: said))
        }
        busy = true
        status = "\(s.characterName) is thinking…"
        let slowHint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.busy else { return }
            self.status = "Still thinking… longer replies take a moment."
        }
        defer {
            slowHint.cancel()
            busy = false
        }
        // Started together with the AI, so the second check adds (almost) no wait.
        let check: Task<[LanguageTool.Match]?, Never>? = !said.isEmpty && grammarCheck
            ? Task { await LanguageTool.check(said, locale: s.locale) } : nil
        do {
            var (turn, userText) = try await chatTurn(said)
            if let check { LanguageTool.apply(await check.value, to: &turn.coach, said: said) }
            guard var s = settings else { return } // ended while thinking
            let mode = Modes.get(s.request.mode)
            history.append(AIMessage(role: "user", content: said.isEmpty ? userText : said))
            history.append(AIMessage(role: "assistant", content: turn.reply))
            if mode.subjects, !turn.subject.isEmpty, !s.subjects.contains(turn.subject) { s.subjects.append(turn.subject) }
            if mode.interpreter {
                let next = turn.situation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !next.isEmpty { s.sayThis = next; s.given.append(next) }
            }
            if mode.joiner {
                let next = turn.situation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !next.isEmpty { s.joinThis = next; Recent.note("connector-tasks", next) }
            }
            settings = s

            rapport = max(0, rapport + max(-2, min(2, turn.rapportDelta)))
            if !said.isEmpty {
                today?.record(turn.coach.usedWords)
                let c = turn.coach
                coach = (c.correction.isEmpty && c.tip.isEmpty && c.understood) ? nil : CoachCard(understood: c.understood, correction: c.correction, tip: c.tip)
                if !c.correction.isEmpty {
                    let types = c.mistakes.filter { MistakeTypes.labels[$0] != nil }
                    var unique: [String] = []
                    for t in types where !unique.contains(t) { unique.append(t) }
                    Mistakes.record(language: s.request.language, types: unique.isEmpty ? ["other"] : unique, said: said, fix: c.correction)
                    mistakesVersion += 1
                }
            }
            // The word the reply asks for: its chip is highlighted.
            if let today {
                today.current = today.find(turn.nextWord)?.de
                let turnNo = history.count / 2
                if let current = today.current, (today.status[current]?.correct ?? 0) == 0,
                   !Prompt.wordResting(today.asked, current, turnNo - 1) {
                    today.asked[current, default: []].append(turnNo)
                }
                // The drill's situation is kept here and sent back each turn, so the story stays coherent.
                let situation = String(turn.situation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                if mode.drill, !situation.isEmpty {
                    if situation != today.situation { Recent.note("drill-situations", situation) }
                    today.situation = situation
                    callMode = "Sentence drill · \(situation)"
                }
            }
            if !paused { status = "" }
            // After a correction the reply waits until the learner has said the fix.
            if !said.isEmpty, s.sayAgain, Drill.drillable(turn.coach.correction, said: said) {
                startDrill(turn, said: said)
            } else {
                presentReply(turn)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func chatTurn(_ message: String) async throws -> (Turn, String) {
        guard let s = settings else { throw AIError.message("No call running.") }
        let mode = Modes.get(s.request.mode)
        var userText = message
        if userText.isEmpty {
            if mode.topics { userText = mode.opener(s.topic ?? "") }
            else if mode.themes != nil { userText = mode.opener(Themes.byName(s.themes.first)?.ask ?? "their life") }
            else { userText = mode.opener("") }
        }
        let snapshot = today.map {
            TodaySnapshot(words: $0.active, correct: $0.correctSet, situation: $0.situation, asked: $0.asked, turn: history.count / 2)
        }
        let todaySet = Set(today?.active.map(\.de) ?? [])
        let targetWords = s.vocabEnabled && !mode.drill ? nextVocabBatch(s.learnt ? 8 : 12).filter { !todaySet.contains($0.de) } : []

        var hints: PromptHints?
        if mode.topics {
            hints = Prompt.topicHints(history: history, topic: s.topic ?? "")
        } else if mode.subjects {
            var h = PromptHints()
            let next = Themes.byName(s.themes.first { !s.subjects.contains($0) })
            h.next = next
            h.current = s.subjects
            h.covered = Array(Store.get("used_subjects", [String]()).filter { !s.subjects.contains($0) && $0 != next?.name }.prefix(80))
            hints = h
        } else if mode.roleCard {
            var h = PromptHints(); h.card = s.roleCard; hints = h
        } else if mode.interpreter {
            var h = PromptHints(); h.target = s.sayThis; h.given = Array(s.given.suffix(30)); hints = h
        } else if mode.joiner {
            var h = PromptHints(); h.target = s.joinThis; h.pool = s.connectors; hints = h
        }

        let system = Prompt.system(s.request, targetWords: targetWords, learnt: s.learnt, learnerMessage: message,
                                   weakSpots: Mistakes.recurring(language: s.request.language), today: snapshot, hints: hints)
        // A drill only needs the last few turns: less to read and write, so replies come sooner.
        let messages = (mode.drill ? Array(history.suffix(6)) : history) + [AIMessage(role: "user", content: userText)]
        let temperature = mode.drill ? 0.4 : 0.8
        let ai = AIClient(keys: keys)
        let ask = { (extra: String) async throws -> Turn in
            let raw = try await ai.json(AIRequest(system: extra.isEmpty ? system : "\(system)\n\(extra)", schema: Schema.turn,
                                                  messages: messages, temperature: temperature))
            return Turn(raw)
        }

        var turn = try await ask("")
        // An answer without a reply is asked for once more rather than shown as an error.
        if turn.reply.isEmpty {
            turn = try await ask("")
            if turn.reply.isEmpty { throw AIError.message("The AI's answer came back incomplete. Please send that again.") }
        }
        // The connector drill runs until the learner ends it, so every turn must bring the next pair.
        if mode.joiner && !ConnectorTypes.isTask(turn.situation) {
            var task = ConnectorTypes.taskIn(turn.reply)
            if task.isEmpty {
                if let again = try? await ask("Your last draft had no task in situation: every reply must put the next task there, written as Verbinde mit „…“: … + …"),
                   !again.reply.isEmpty, ConnectorTypes.isTask(again.situation) {
                    turn = again
                }
                task = ConnectorTypes.isTask(turn.situation)
                    ? turn.situation.trimmingCharacters(in: .whitespacesAndNewlines)
                    : ConnectorTypes.fallbackTask(s.connectors, last: s.joinThis ?? "")
            }
            turn.situation = task
        }
        // A reply that says the word it asks for gives the answer away: written once more.
        if mode.drill || mode.topics, let snapshot,
           let asked = snapshot.words.first(where: { !snapshot.correct.contains($0.de) && TextMatch.isWord($0, turn.nextWord) }),
           TextMatch.says(turn.reply, asked.de) {
            let how = mode.drill
                ? "refer to it only as \"das Wort auf deinem Bildschirm\""
                : "ask the same kind of question in other words, so that the learner has to find the word, or ask for no word at all"
            if let again = try? await ask("Your last draft of this reply contained the word \"\(asked.de)\" itself, which gives the answer away. Write the reply again without that word in any form; \(how)."),
               !again.reply.isEmpty, !TextMatch.says(again.reply, asked.de) {
                turn = again
            }
        }
        turn.focusWords = targetWords
        // Suggested answers would give the drill's word, the sentence or the joined one away.
        if mode.drill || mode.interpreter || mode.joiner { turn.suggestions = [] }
        if !mode.endable { turn.finished = false }
        return (turn, userText)
    }

    // MARK: - Showing a reply

    private func presentReply(_ turn: Turn) {
        guard let s = settings else { return }
        let mode = Modes.get(s.request.mode)
        // A scene's opening line says how this call goes: kept, so the next one goes differently.
        if mode.usesScene, !transcript.contains(where: { $0.kind == .character }) {
            Recent.note("scene-\(s.request.scenario)", String(turn.reply.prefix(200)))
        }
        let message = ChatMessage(kind: .character, who: s.characterName, text: turn.reply, translation: turn.replyTranslation, mood: turn.mood)
        transcript.append(message)
        renderSayThis()
        suggestions = turn.suggestions
        renderChips(turn.focusWords)
        if turn.finished {
            finished = true
            suggestions = []
            handsFree = false
            status = "Scene complete! Tap End to start another."
        }
        if paused {
            pendingReply = (message.id, turn) // spoken on resume
            return
        }
        speak(message.id, turn.reply, mood: turn.mood) { [weak self] in self?.maybeResumeListening() }
    }

    private func speak(_ id: UUID?, _ text: String, mood: String = "neutral", then done: @escaping () -> Void) {
        guard let s = settings else { return }
        speaker.speak(text, locale: s.locale, slow: ["A1", "A2"].contains(s.request.level), mood: mood,
                      onRange: { [weak self] range in
                          guard let self, let id, let i = self.transcript.firstIndex(where: { $0.id == id }) else { return }
                          self.transcript[i].speaking = range
                      },
                      onDone: done)
    }

    func replay(_ id: UUID) {
        guard let m = transcript.first(where: { $0.id == id }) else { return }
        listener.cancel()
        micOn = false
        speak(id, m.text, mood: m.mood) { [weak self] in self?.maybeResumeListening() }
    }

    func toggleTranslation(_ id: UUID) {
        guard let i = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[i].showTranslation.toggle()
    }

    private func renderSayThis() {
        guard let s = settings else { sayThis = nil; return }
        let mode = Modes.get(s.request.mode)
        if mode.interpreter, let text = s.sayThis, !text.isEmpty {
            sayThis = ("Say it in \(s.request.language): ", text)
        } else if mode.joiner, let text = s.joinThis, !text.isEmpty {
            sayThis = ("Say it as one sentence · ", text)
        } else {
            sayThis = nil
        }
    }

    /// Today's words as their English cue (the learner recalls the German), or the words being practised.
    private func renderChips(_ focusWords: [VocabWord]) {
        if let today {
            let current = today.current
            let ordered = today.active.filter { $0.de == current } + today.active.filter { $0.de != current }
            chips = ordered.map { w in
                let st = today.status[w.de]
                let isCurrent = w.de == current
                let said = (st?.correct ?? 0) > 0
                let mark = said ? "✓ " : (st?.wrong ?? 0) > 0 ? "! " : ""
                let showGerman = st?.peeked == true || (said && !isCurrent)
                return WordChip(id: w.de, text: mark + (showGerman ? "\(w.en) = \(w.de)" : (w.en.isEmpty ? w.de : w.en)),
                                state: said ? .said : (st?.wrong ?? 0) > 0 ? .tried : .plain, current: isCurrent, peekable: !showGerman)
            }
            chipsLabel = "Say: "
        } else {
            chips = focusWords.map { WordChip(id: $0.de, text: $0.de, state: .plain, current: false, peekable: false) }
            chipsLabel = settings?.learnt == true ? "Your words: " : "Practising: "
        }
    }

    /// A tap on one of today's words shows its German (and counts as a miss).
    func peekWord(_ de: String) {
        guard let today else { return }
        today.peek(de)
        renderChips([])
    }

    func useSuggestion(_ text: String) {
        composer = text
    }

    // MARK: - Say it again

    private func startDrill(_ turn: Turn, said: String) {
        drillTurn = DrillState(said: said, turn: turn)
        suggestions = []
        drill = DrillCard(target: turn.coach.correction.trimmingCharacters(in: .whitespacesAndNewlines))
        // Hear it first; hands-free then listens for the attempt.
        speak(nil, drill!.target) { [weak self] in self?.maybeResumeListening() }
    }

    /// Returns whether the attempt passed.
    @discardableResult
    private func checkDrill(_ attempt: String) -> Bool {
        guard let d = drillTurn, let card = drill else { return false }
        let result = Drill.match(attempt: attempt, target: card.target, said: d.said)
        if result.ok {
            drill?.feedback = "✓ That's it: “\(attempt)”"
            drill?.ok = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if self?.drillTurn?.id == d.id { self?.endDrill() }
            }
        } else {
            drill?.feedback = "Heard “\(attempt)”. \(result.missing.isEmpty ? "" : "Listen for: \(result.missing.joined(separator: ", ")). ")Try again."
        }
        return result.ok
    }

    func endDrill() {
        guard let d = drillTurn else { return }
        drillTurn = nil
        drill = nil
        if d.live { return } // a live call carries on by itself
        listener.cancel()
        micOn = false
        speaker.stop()
        if let turn = d.turn { presentReply(turn) }
    }

    /// Skipped by the button: in a live call, Gemini is told to carry on.
    func skipDrill() {
        let wasLive = drillTurn?.live == true
        endDrill()
        if wasLive, let live, live.ready { live.note("The learner skipped saying it again: carry on with the conversation.") }
    }

    func drillSay() {
        guard drill != nil else { return }
        if drillTurn?.live == true { // Gemini is already listening: just make sure the mic is on
            if live?.muted == true { setLiveMuted(false) }
            return
        }
        guard !listener.isListening else { return }
        drill?.feedback = ""
        startListening()
    }

    func drillHear() {
        guard let card = drill else { return }
        if drillTurn?.live == true {
            if let live, live.ready { live.note("Say «\(card.target)» once more, slowly, and nothing else.") }
            return
        }
        listener.cancel()
        micOn = false
        speak(nil, card.target) { [weak self] in self?.maybeResumeListening() }
    }

    // MARK: - Listening

    private func startListening() {
        guard let s = settings else { return }
        speaker.stop()
        micOn = true
        status = "Listening… just talk. Tap the mic to stop hands-free."
        listener.start(locale: s.locale)
    }

    private func maybeResumeListening() {
        if handsFree && !finished && !paused && !listener.isListening { startListening() }
    }

    private func afterListening(_ spoken: String) {
        if paused {
            return // paused mid-sentence: dropped rather than sending half a thought
        } else if TextMatch.isPause(spoken) {
            setPaused(true)
        } else if drill != nil && !spoken.isEmpty {
            if TextMatch.isSkip(spoken) { endDrill() }
            else if !checkDrill(spoken) { maybeResumeListening() }
        } else if !spoken.isEmpty && !autoSend {
            // Manual send: collected in the text box until Send is tapped.
            composer = "\(composer.trimmingCharacters(in: .whitespaces)) \(spoken)".trimmingCharacters(in: .whitespaces)
            status = "Tap Send when you're done."
            maybeResumeListening()
        } else if !spoken.isEmpty {
            Task { await sendTurn(spoken) } // listening resumes after the reply is spoken
        } else if handsFree {
            maybeResumeListening()
        } else {
            status = ""
        }
    }

    func micTap() {
        if settings?.live == true {
            if let live { setLiveMuted(!live.muted) }
            else { Task { await startLive() } } // after a dropped connection
            return
        }
        if handsFree || micOn {
            handsFree = false
            listener.finish()
            status = "Hands-free off."
        } else {
            handsFree = true
            startListening()
        }
    }

    /// Before what was heard is sent: fix it in the text box…
    func heardEdit() {
        guard listener.isListening else { return }
        composer = heard
        listener.cancel()
        micOn = false
        heard = ""
        status = "Fix it, then tap Send."
    }

    /// …or drop it and say it again.
    func heardDelete() {
        guard listener.isListening else { return }
        listener.cancel()
        micOn = false
        heard = ""
        maybeResumeListening()
        status = "Deleted. Say it again."
    }

    func setAutoSend(_ on: Bool) {
        autoSend = on
        status = on ? "Auto-send on: I'll send when you pause." : "Auto-send off: tap Send when you're done."
        if on && !composer.trimmingCharacters(in: .whitespaces).isEmpty && !listener.isListening { submitComposer() }
    }

    func submitComposer() {
        guard !busy, !finished, !paused else { return }
        let unsent = !autoSend && listener.isListening ? heard.trimmingCharacters(in: .whitespaces) : ""
        let text = "\(composer.trimmingCharacters(in: .whitespaces)) \(unsent)".trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        composer = ""
        if !unsent.isEmpty {
            listener.cancel()
            micOn = false
            heard = ""
        }
        if drillTurn?.live == true, let live, live.ready {
            liveSendText(text, via: live) // typed: Gemini judges it like a spoken try
            return
        }
        if drill != nil {
            checkDrill(text) // typing the corrected sentence also counts
            return
        }
        if TextMatch.isPause(text) {
            setPaused(true)
            return
        }
        if settings?.live == true {
            if let live, live.ready { liveSendText(text, via: live) }
            else { composer = text; status = "The live call isn't connected: tap 🎤 first." }
            return
        }
        speaker.stop()
        Task { await sendTurn(text) }
    }

    // MARK: - Live voice (Gemini Live)

    private static let liveRecapLines = 30 // lines sent again when a call reconnects without a handle
    private static let liveVocabWords = 20
    private static let liveSubjectsEvery = 6 // learner turns

    /// Connects the live call (or reconnects it, carrying on the same conversation).
    func startLive() async {
        debug("live: starting (key \(keys.liveKey.isEmpty ? "missing" : "…" + keys.liveKey.suffix(4)))")
        guard live == nil, let s = settings, s.live else { return }
        liveReconnectPending = false
        let key = keys.liveKey
        guard !key.isEmpty else {
            status = "The live voice call needs a Gemini key: add it with “Add or change keys” on the start screen."
            return
        }
        guard await AudioSession.requestPermissions() else {
            status = "Allow the microphone in Settings for the live call."
            return
        }
        guard live == nil, settings != nil else { return } // started or ended while permission was asked
        await phone.waitForAudio() // CallKit activates the audio session for the call first
        guard live == nil, settings != nil else { return }
        // Gemini's own copy of the call, if it still has it; else the partner gets the end of the call.
        let handle: String? = transcript.isEmpty ? nil : LiveCall.savedHandle
        let recap: [String] = handle != nil ? [] : transcript.suffix(Self.liveRecapLines).map { m -> String in
            m.kind == .learner ? "Learner: \(m.text)" : "You: \(m.text)"
        }
        let call = LiveCall(resumed: handle != nil)
        live = call
        micOn = true
        status = handle != nil ? "Reconnecting the live call…" : "Connecting the live call…"
        call.events = LiveCall.Events(
            ready: { [weak self, weak call] in
                guard let self, let call, self.live === call else { return }
                self.liveRetries = 0
                self.status = ""
                self.phone.reportConnected()
                // The partner speaks first; resumed, it carries on where the call was.
                call.open(with: handle != nil
                    ? "(The call was on hold or the line dropped, and it is back now: carry on from where we were in one short line, without greeting again.)"
                    : recap.isEmpty ? Prompt.liveOpener(s) : "(The call reconnected: carry on.)")
                if self.paused { call.muted = true }
            },
            learnerTurn: { [weak self] said in self?.liveLearnerTurn(said) },
            replyText: { [weak self] text in self?.liveShowReply(text) },
            replyDone: { [weak self] text in self?.liveFinishReply(text) },
            speaking: { [weak self] on in self?.liveSpeaking = on },
            closed: { [weak self, weak call] before, resumed, goingAway, reason in
                guard let self, let call, self.live === call else { return }
                self.liveClosed(before: before, resumed: resumed, goingAway: goingAway, reason: reason)
            }
        )
        do {
            let model = try await LiveCall.model(key: key)
            guard live === call else { return } // ended while the model was looked up
            let prompt = Prompt.live(s, vocabLines: liveVocabLines(s), recap: recap)
            try call.start(key: key, model: model, systemPrompt: prompt, handle: handle)
        } catch {
            if live === call { stopLive() }
            status = "Live voice couldn't start: \(error.localizedDescription). Tap 🎤 to try again."
        }
    }

    func stopLive() {
        guard let call = live else { return }
        if drillTurn?.live == true { endDrill() }
        call.stop() // hands over what was said so far first
        live = nil
        liveSpeaking = false
        micOn = false
    }

    private func setLiveMuted(_ muted: Bool) {
        guard let live else { return }
        live.muted = muted
        phone.setMuted(muted)
        micOn = !muted
        status = muted ? "Mic muted: tap 🎤 to talk again." : ""
    }

    private func liveClosed(before: Bool, resumed: Bool, goingAway: Bool, reason: String) {
        debug("live: closed before ready=\(before) resumed=\(resumed) goingAway=\(goingAway) retries=\(liveRetries)")
        live = nil
        liveSpeaking = false
        micOn = false
        if before && resumed {
            // Gemini no longer has this call: start again from the recap.
            LiveCall.clearHandle()
            if paused { liveReconnectPending = true } else { Task { await startLive() } }
            return
        }
        if before { LiveCall.forgetModel() } // look the model up again next time
        // A call that was going carries on by itself (Google closes connections now and then),
        // unless that keeps failing.
        if !before && liveRetries < 3 {
            liveRetries += 1
            if paused {
                liveReconnectPending = true
                status = "Call paused. Tap ▶ to carry on."
            } else {
                if !goingAway { status = "The live call dropped: reconnecting…" }
                Task { await startLive() }
            }
            return
        }
        status = "\(before ? "The live call couldn't start" : "The live call stopped")\(reason.isEmpty ? "" : " (\(reason))"). Tap 🎤 to \(before ? "try again" : "reconnect")."
    }

    /// "Weave my vocab into the conversation": sent once when the call connects, so a longer list.
    private func liveVocabLines(_ s: CallSettings) -> [String] {
        let m = Modes.get(s.request.mode)
        guard s.vocabEnabled, !m.drill, !m.joiner else { return [] }
        let fmt = { (w: VocabWord) -> String in w.en.isEmpty ? w.de : "\(w.de) (\(w.en))" }
        let todayList = today?.active ?? []
        let todaySet = Set(todayList.map(\.de))
        let words = nextVocabBatch(Self.liveVocabWords).filter { !todaySet.contains($0.de) }
        var lines: [String] = []
        if !words.isEmpty {
            let kind = s.learnt ? "Words the learner knows and should practise saying" : "Vocabulary being practised"
            let subjects = m.subjects ? "; never change the subject to bring one in. \(Prompt.subjectsNotFromWords)" : ""
            lines.append("\(kind): \(words.map(fmt).joined(separator: "; ")). Conversation first: stay on topic and bring these in only where they fit naturally, a few at a time over the call\(subjects); use them yourself and ask questions whose natural answer needs one. Never list or quiz them.")
        }
        if !todayList.isEmpty {
            lines.append("Today's words, which the learner must recall and say: \(todayList.map(fmt).joined(separator: "; ")). Over the call, get them to say each one, one at a time, with a question on the current topic whose natural answer needs it\(m.subjects ? ", only where one fits it" : ""). Never say, translate or hint at one before they have said it.")
        }
        return lines
    }

    /// What the learner said, as Gemini heard it: shown, kept and checked once their turn is over.
    private func liveLearnerTurn(_ said: String) {
        debug("live: heard \(q(said))")
        guard settings != nil else { return }
        if status.hasPrefix("Mic muted") == false { status = "" }
        transcript.append(ChatMessage(kind: .learner, who: "You", text: said))
        history.append(AIMessage(role: "user", content: said))
        liveLearnerTurns += 1
        if liveLearnerTurns % Self.liveSubjectsEvery == 0 { noteLiveSubjects() }
        if drillTurn?.live == true { liveDrillAttempt(said) }
        else { Task { await liveCoach(said, partner: liveLastReply) } }
    }

    /// Typed during a live call: sent as text, and checked like a spoken sentence.
    private func liveSendText(_ text: String, via call: LiveCall) {
        call.sendText(text) // finishes the partner's bubble first
        transcript.append(ChatMessage(kind: .learner, who: "You", text: text))
        history.append(AIMessage(role: "user", content: text))
        if drillTurn?.live == true { liveDrillAttempt(text) }
        else { Task { await liveCoach(text, partner: liveLastReply) } }
    }

    /// The partner's words so far, in a bubble that grows while it speaks.
    private func liveShowReply(_ text: String) {
        guard let s = settings else { return }
        if let id = liveReplyId, let i = transcript.firstIndex(where: { $0.id == id }) {
            transcript[i].text = text
        } else {
            let m = ChatMessage(kind: .character, who: s.characterName, text: text)
            liveReplyId = m.id
            transcript.append(m)
        }
    }

    private func liveFinishReply(_ text: String) {
        if !text.isEmpty { debug("live: partner said \(q(String(text.prefix(60))))") }
        let id = liveReplyId
        liveReplyId = nil
        guard let s = settings else { return }
        if text.isEmpty {
            if let id { transcript.removeAll { $0.id == id } }
            return
        }
        if let id, let i = transcript.firstIndex(where: { $0.id == id }) {
            transcript[i].text = text
        } else {
            transcript.append(ChatMessage(kind: .character, who: s.characterName, text: text))
        }
        // A scene's opening line says how this call goes: kept, so the next one goes differently.
        if Modes.get(s.request.mode).usesScene && liveLastReply.isEmpty {
            Recent.note("scene-\(s.request.scenario)", String(text.prefix(200)))
        }
        liveLastReply = text
        history.append(AIMessage(role: "assistant", content: text))
    }

    /// The coach for a live call: the learner's sentence checked on the side, never holding up the call.
    private func liveCoach(_ said: String, partner: String) async {
        guard let s = settings else { return }
        let check: Task<[LanguageTool.Match]?, Never>? = grammarCheck ? Task { await LanguageTool.check(said, locale: s.locale) } : nil
        do {
            let raw = try await AIClient(keys: keys).json(AIRequest(
                system: Prompt.liveCoach(s.request),
                schema: Schema.liveCoach,
                messages: [AIMessage(role: "user", content: "The partner said: \(q(partner))\nThe learner said: \(q(said))")],
                temperature: 0.2))
            var c = Coach(correction: raw["correction"] as? String ?? "",
                          mistakes: (raw["mistakes"] as? [Any] ?? []).compactMap { $0 as? String },
                          tip: raw["tip"] as? String ?? "")
            if let check { LanguageTool.apply(await check.value, to: &c, said: said) }
            guard live != nil, settings != nil else { return } // the call ended meanwhile
            coach = (c.correction.isEmpty && c.tip.isEmpty) ? nil : CoachCard(understood: true, correction: c.correction, tip: c.tip)
            if !c.correction.isEmpty {
                var unique: [String] = []
                for t in c.mistakes where MistakeTypes.labels[t] != nil && !unique.contains(t) { unique.append(t) }
                Mistakes.record(language: s.request.language, types: unique.isEmpty ? ["other"] : unique, said: said, fix: c.correction)
                mistakesVersion += 1
                if s.sayAgain, drillTurn == nil, Drill.drillable(c.correction, said: said) {
                    // No note to Gemini: its prompt already has it ask for the repeat in the same reply.
                    drillTurn = DrillState(said: said, turn: nil, live: true)
                    drill = DrillCard(target: c.correction.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        } catch {
            // The coach is extra: a failed check never stops the call.
        }
    }

    /// Gemini heard the attempt and answers it itself; the app only decides when to put the
    /// panel away: once the attempt matches, or once the learner has clearly moved on.
    private func liveDrillAttempt(_ attempt: String) {
        guard var d = drillTurn, let card = drill else { return }
        if TextMatch.isSkip(attempt) { skipDrill(); return }
        d.tries += 1
        drillTurn = d
        let result = Drill.match(attempt: attempt, target: card.target, said: d.said)
        if result.ok {
            drill?.feedback = "✓ “\(attempt)”"
            drill?.ok = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if self?.drillTurn?.id == d.id { self?.endDrill() }
            }
        } else if d.tries >= 3 || Drill.similarity(Drill.words(attempt), Drill.words(card.target)) < 0.5 {
            endDrill()
        }
    }

    /// A live call has no subject field, so every few turns (and when it ends) the AI names the
    /// subjects talked about, which the next calls leave alone.
    private func noteLiveSubjects() {
        guard let s = settings, s.live, Modes.get(s.request.mode).subjects,
              transcript.filter({ $0.kind == .learner }).count >= 2 else { return }
        let conversation = transcript.suffix(14).map { "\($0.kind == .learner ? "Learner" : "Partner"): \($0.text)" }.joined(separator: "\n")
        let known = s.subjects
        let ai = AIClient(keys: keys)
        Task { [weak self] in
            let known_ = known.isEmpty ? "" : "Subjects already known: \(known.map(q).joined(separator: ", "))\n"
            guard let raw = try? await ai.json(AIRequest(system: Prompt.liveSubjects, schema: Schema.subjects,
                                                         messages: [AIMessage(role: "user", content: "\(known_)Conversation:\n\(conversation)")],
                                                         temperature: 0.2)) else { return }
            var found: [String] = []
            for item in raw["subjects"] as? [Any] ?? [] {
                let subject = String(String(describing: item).trimmingCharacters(in: .whitespaces).lowercased().prefix(60))
                if !subject.isEmpty && !found.contains(subject) { found.append(subject) }
            }
            found = Array(found.prefix(5))
            guard !found.isEmpty, let self else { return }
            if var current = self.settings, current.live {
                for f in found where !current.subjects.contains(f) { current.subjects.append(f) }
                self.settings = current
            } else {
                // The call has ended meanwhile: the next calls still leave these alone.
                let used = Store.get("used_subjects", [String]())
                Store.set("used_subjects", Array((found.reversed() + used.filter { !found.contains($0) }).prefix(200)))
            }
        }
    }

    // MARK: - Pause and end

    func togglePause() { setPaused(!paused) }

    private func setPaused(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        if !on { phone.resume() } // after iOS put the call on hold, CallKit gives the audio back
        // A live call stays connected while paused: the mic sends nothing and the voice stops.
        if let live {
            live.muted = on
            if on { live.stopVoice() }
            micOn = !on
        }
        if !on, settings?.live == true, live == nil {
            // It dropped while on hold: carry it on (Gemini still has it, with its handle).
            paused = false
            status = ""
            liveReconnectPending = false
            Task { await startLive() }
            return
        }
        if on {
            listener.cancel()
            micOn = false
            heard = ""
            speaker.stop()
            status = "On hold. Tap ▶ to carry on."
        } else {
            status = ""
            if let pending = pendingReply {
                pendingReply = nil
                speak(pending.id, pending.turn.reply, mood: pending.turn.mood) { [weak self] in self?.maybeResumeListening() }
            } else {
                maybeResumeListening()
            }
        }
    }

    func endCall() {
        noteLiveSubjects() // what a live free chat was about, for the next calls
        phone.end()
        stopLive()
        LiveCall.clearHandle()
        liveReconnectPending = false
        listener.cancel()
        speaker.stop()
        timer?.cancel()
        timer = nil
        AudioSession.deactivate()
        // The subjects talked about aren't brought up again in the next chats.
        if let s = settings, !s.subjects.isEmpty {
            let used = Store.get("used_subjects", [String]())
            Store.set("used_subjects", Array((s.subjects.reversed() + used.filter { !s.subjects.contains($0) }).prefix(200)))
        }
        // After a call: what was said, tried and not reached.
        if let today {
            let said = today.status.filter { $0.value.correct > 0 && !$0.value.peeked }.map { $0.key }
            let tried = today.status.keys.filter { !said.contains($0) }
            let missed = today.active.map(\.de).filter { today.status[$0] == nil }
            recap = said.isEmpty && tried.isEmpty ? nil : CallRecap(said: said, tried: Array(tried), missed: missed, automatic: TodayWords.automaticCount)
        } else {
            recap = nil
        }
        settings = nil
        today = nil
        history = []
        handsFree = false
        finished = false
        paused = false
        micOn = false
        busy = false
        drill = nil
        drillTurn = nil
        pendingReply = nil
        transcript = []
        coach = nil
        suggestions = []
        chips = []
        sayThis = nil
        heard = ""
        composer = ""
        status = ""
        screen = .setup
        if let link = keys.link {
            Task {
                await Mistakes.sync(link)
                mistakesVersion += 1
                await TodayWords.sync(link)
            }
        }
    }

    /// Leaving the app sends what this device recorded.
    func flushSyncs() {
        guard let link = keys.link else { return }
        Task {
            await Mistakes.sync(link)
            await TodayWords.sync(link)
        }
    }

    // MARK: - Mistakes panel

    func mistakes() -> [WeakSpot] { Mistakes.ranked(language: form.language) }

    func resetMistakes() {
        Mistakes.reset(language: form.language)
        mistakesVersion += 1
        if let link = keys.link { Task { await Mistakes.sync(link) } }
    }

    var isLiveCall: Bool { settings?.live == true }
    var liveConnected: Bool { live?.ready == true }

    var timerText: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }
}

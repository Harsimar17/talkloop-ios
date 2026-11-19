// The system prompt for one turn, ported from turnSystemPrompt in engine.js. Every line is
// sent with every turn, so the rules are short.
import Foundation

struct CallRequest: Codable {
    var language: String
    var nativeLanguage: String
    var level: String
    var scenario: String
    var mode: String
    var tense: String
}

/// Today's words as the prompt needs them.
struct TodaySnapshot {
    var words: [VocabWord]
    var correct: Set<String>
    var situation: String?
    var asked: [String: [Int]]
    var turn: Int
}

/// Mode-specific hints for the prompt.
struct PromptHints {
    // Discuss a topic
    var topic = ""
    var asked: [String] = []
    var angle: String?
    // Rollenkarte
    var card: String?
    // Dolmetscher and Konnektoren: what the learner was asked to say
    var target: String?
    var given: [String] = []
    var pool: [Connector] = []
    // Free chats: subjects
    var covered: [String] = []
    var current: [String] = []
    var next: Theme?
}

struct WeakSpot {
    let type: String
    let count: Int
    let weight: Double
    let example: MistakeEntry
}

enum Prompt {
    static let subjectsNotFromWords = "When a subject runs dry, choose the next one from the learner's own life and what they said, never to fit these words."

    /// A word already asked about without the learner saying it rests for a few turns, and is asked once more at most.
    static func wordResting(_ asked: [String: [Int]], _ de: String, _ turn: Int) -> Bool {
        let turns = asked[de] ?? []
        return turns.count >= 2 || (turns.count == 1 && turn - turns[0] < 5)
    }

    static func topicHints(history: [AIMessage], topic: String) -> PromptHints {
        let replies = history.filter { $0.role == "assistant" }.map(\.content)
        // The last question of each of the last few replies.
        let questionPattern = try? NSRegularExpression(pattern: "[^.!?]*\\?")
        let asked = replies.suffix(6).compactMap { reply -> String? in
            let ns = reply as NSString
            guard let last = questionPattern?.matches(in: reply, range: NSRange(location: 0, length: ns.length)).last else { return nil }
            let text = ns.substring(with: last.range).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        var hints = PromptHints()
        hints.topic = topic
        hints.asked = asked
        hints.angle = replies.isEmpty ? nil : Content.topicAngles[replies.count % Content.topicAngles.count]
        return hints
    }

    static func usedLine(_ items: [String], _ what: String) -> String {
        items.isEmpty ? "" : "\(what): \(items.map(q).joined(separator: ", "))."
    }

    static func system(_ r: CallRequest, targetWords: [VocabWord], learnt: Bool, learnerMessage: String,
                       weakSpots: [WeakSpot], today: TodaySnapshot?, hints: PromptHints?) -> String {
        let m = Modes.get(r.mode)
        let persona = Content.persona(scenario: r.scenario, mode: r.mode)
        let t = Tenses.all[r.tense]
        let tenseMistake = t.map { t in
            " or doesn't use \(t.short) where your question called for it (then rewrite their message in \(t.short), keeping their meaning and words, as the short full sentence they meant if it is a fragment, and list tense)"
        } ?? ""

        var lines: [String] = [
            "You are \(persona.character), \(persona.setting). Stay in character; speak only \(r.language).",
            "Learner: \(r.language) at CEFR \(r.level), native \(r.nativeLanguage). Reply in one or two short sentences at their level, ending with something they can answer.",
        ]
        if let guide = LevelGuide.all[r.level] { lines.append("At \(r.level): \(guide)") }
        lines.append(m.extra)
        if m.usesScene, let goal = persona.goal { lines.append("Scene goal: \(goal)") }
        if m.usesScene {
            let line = usedLine(Recent.items("scene-\(r.scenario)", 6), "Earlier calls in this scene opened like this")
            if !line.isEmpty { lines.append("\(line) Make this call go differently: another request, item, detail or small problem, and open with other words.") }
        }
        lines.append("The learner's message comes from speech recognition: ignore missing punctuation and obvious transcription slips.")
        lines.append("Write reply_translation and coach.tip in \(r.nativeLanguage); everything else in \(r.language). suggestions: 2-3 short answers the learner could give.")
        lines.append(learnerMessage.isEmpty
            ? "No learner message yet: leave coach.correction, coach.mistakes, coach.tip and coach.used_words empty."
            : "Fill coach first. It judges only the learner's last message: \(q(learnerMessage)). coach.correction: only if it has a real grammar or word-choice mistake\(tenseMistake), the faulty sentence(s) rewritten correctly, no explanation; then coach.mistakes lists each kind it fixes (\(MistakeTypes.promptList)); otherwise leave both empty. coach.tip: one short sentence praising or explaining something literally in that message (never credit words or grammar it doesn't contain), or empty.")
        lines.append("Your reply is read aloud: sound like a real person, with short interjections (Oh!, Ach wirklich?, Super!) and ! or ? where you mean them.")
        lines.append("mood: \(Moods.all.joined(separator: "|")); amused for fun replies, surprised for amazement, angry only if the role calls for it, sleepy, whisper for secrets, else neutral.")

        if let t {
            lines.append("Tense practice: \(t.form). Use it yourself and, from your very first question on, ask things whose natural answer needs it (about \(t.ask)); write the suggestions in it too. A message in another tense, or with this tense formed wrongly, always gets a coach.correction in this tense, never only a tip; when it is right, say so briefly in coach.tip.")
        }

        let stayOnTopic = "Conversation first: follow on from what the learner said and stay on topic. Use a listed word only where it fits naturally; never change topic or ask something unrelated to bring one in (the list stays for the next turns). \(m.subjects ? subjectsNotFromWords : "When a topic runs dry, bridge naturally to one where some fit.")"
        let fmt = { (w: VocabWord) -> String in w.en.isEmpty ? w.de : "\(w.de) (\(w.en))" }
        if !targetWords.isEmpty {
            let list = targetWords.map(fmt).joined(separator: "; ")
            if learnt {
                lines.append("Words the learner knows and should practise saying: \(list). \(stayOnTopic) You are not limited to them: where one fits, use it or ask a question whose natural answer needs it; never list or quiz them. If the learner's message contains one, praise it briefly in coach.tip, or fix a wrong meaning, article or form in coach.correction.")
            } else {
                lines.append("Vocabulary being practised: \(list). \(stayOnTopic) Where they fit, weave one to three into your reply naturally so the learner can use them too.")
            }
        }

        // Today's words: the learner has to recall and say them, so the partner asks for them
        // but never says them first.
        if let today, !today.words.isEmpty {
            let notYet = today.words.filter { !today.correct.contains($0.de) }
            let said = today.words.filter { today.correct.contains($0.de) }
            let neverSay = "Never say, translate or hint at one the learner hasn't said yet: they must recall it (the app shows its meaning)."
            let resting = { (w: VocabWord) -> Bool in Prompt.wordResting(today.asked, w.de, today.turn) }
            let askable = notYet.filter { m.drill || !resting($0) }
            let waiting = m.drill ? [] : notYet.filter(resting)
            lines.append("Today's words, to be said until automatic: \(today.words.map(fmt).joined(separator: "; ")).")
            if m.drill {
                if let situation = today.situation, !situation.isEmpty {
                    lines.append("Current situation: \(q(situation)). Continue it from where the conversation left off.")
                } else {
                    lines.append("No situation yet: start one.")
                }
                let earlier = usedLine(Recent.items("drill-situations", 25), "Situations of earlier drills: whenever you start a new situation, choose one clearly different from all of these")
                if !earlier.isEmpty { lines.append(earlier) }
                let notYetList = notYet.isEmpty ? "" : " (\(notYet.map(\.de).joined(separator: "; ")))"
                lines.append("Ask first for words not said yet\(notYetList), one per step, the one fitting the next moment best. \(neverSay)")
                lines.append("Most important rule: your reply must NOT contain the word you are asking for, in any form, nor a translation of it, until the learner has said it correctly. Refer to it only as \"das Wort auf deinem Bildschirm\" and describe the moment so that this word is the natural thing to say. Wrong: \"Das Handy sieht schrecklich aus. Sag einen Satz mit diesem Wort.\" Right: \"Das Display ist kaputt und voller Kratzer. Wie findest du das Handy? Nutze das Wort auf deinem Bildschirm.\"")
                if !said.isEmpty {
                    lines.append("Already said once: \(said.map(\.de).joined(separator: "; ")). Bring each back at a later moment needing another form (tense, person), so they build a new sentence.")
                }
                lines.append("If their sentence misses the word asked for or uses it wrongly, ask for it again next turn, still without saying it.")
            } else {
                if !askable.isEmpty {
                    let names = askable.map(\.de).joined(separator: "; ")
                    if m.topics {
                        lines.append("Not said yet: \(names). Only where one of these is the natural thing to say about the current topic, ask a question whose answer needs it, without naming it. If none fits at this point, ask for none and keep discussing the topic: never change the topic or bridge to another one to bring a word in, and don't force a word in. \(neverSay)")
                    } else {
                        let bridge = m.subjects ? "if none fits, ask for none: \(subjectsNotFromWords)" : "bridge naturally"
                        lines.append("Not said yet: \(names). Get the learner to say them, one at a time, with a question on the current topic whose natural answer needs one (\(bridge); never quiz or list). \(neverSay)")
                    }
                }
                if !waiting.isEmpty {
                    lines.append("Asked about already without success, so leave these alone for now: \(waiting.map(\.de).joined(separator: "; ")).")
                }
                if !said.isEmpty {
                    lines.append("Already said: \(said.map(\.de).joined(separator: "; ")). Bring each back later in another form.")
                }
            }
            lines.append("next_word: the word from this list (as written) your reply asks for, else empty.")
            if !learnerMessage.isEmpty {
                lines.append("coach.used_words: list every one of today's words that appears in the learner's last message, in any form (write it as in the list), with correct true only if its meaning, form and article are right; empty only if none appears. A wrong use also gets a coach.correction.")
            }
        }

        if m.topics, let hints {
            var line = "Stay on the topic \"\(hints.topic)\": every question is about it itself, never about something the learner only mentioned in passing, and never about another subject."
            if !hints.asked.isEmpty {
                line += " You have already asked: \(hints.asked.map(q).joined(separator: " ")). Never ask any of these, or a question that starts or means the same, again."
            }
            if let angle = hints.angle { line += " This turn, ask about \(angle)." }
            lines.append(line)
        }
        if m.roleCard, let card = hints?.card, !card.isEmpty {
            lines.append("The learner's role card (they play this person): \(card).")
        }
        if m.interpreter {
            let given = (hints?.given ?? []).isEmpty ? "" : " Already given, never again: \(hints!.given.map(q).joined(separator: " "))."
            let judge = (hints?.target ?? "").isEmpty ? "" : " They were asked to say: \(q(hints!.target!)); coach judges whether their message says that correctly in \(r.language), meaning included."
            lines.append("situation: the next sentence for the learner to say in \(r.language), written in \(r.nativeLanguage): short and everyday, at their level, a new situation or pattern each time (shopping, work, friends, travel, home, plans, problems). Always a new one, also after a wrong try: the app brings that sentence back itself later.\(given)\(judge) reply: one short \(r.language) reaction to their try; never say the \(r.language) version of the new sentence.")
        }
        if m.joiner {
            let pool = hints?.pool ?? []
            let judge = (hints?.target ?? "").isEmpty ? "" : " Their task was: \(q(hints!.target!)); coach judges whether their message joins those two sentences into one correct sentence with that connector: the connector used, the verb in the right place in each half, nothing changed in meaning. Either order of the halves is right where the connector allows it. A wrong or missing connector or word order gets a coach.correction with the right joined sentence (verb position goes in mistakes as verb_position)."
            let earlier = usedLine(Recent.items("connector-tasks", 30), "Tasks given in earlier drills, never again (new sentences on new everyday subjects)")
            let tasksLine = earlier.isEmpty ? "" : " \(earlier)"
            let ending = pool.count == 1
                ? "Every task uses „\(pool[0].name)“ and nothing else, with new sentences each time."
                : "When every connector has had a task, start again from the first with new sentences."
            lines.append("\(ConnectorTypes.line(pool)) situation: the next task, written exactly as: Verbinde mit „<connector>“: <sentence one> + <sentence two>. situation holds that whole task and nothing else, never a topic word. Two short everyday \(r.language) sentences at their level that make sense joined with it, about something new each time; also after a wrong try give a new one.\(tasksLine)\(judge) reply: one short \(r.language) reaction to their try (praise, or the rule in a few words); never write the joined sentence of the new task. Every reply gives a new task, without exception: the drill goes on, task after task, until the learner ends the call; never ask whether they want to go on, never sum up or say goodbye. \(ending)")
        }
        if m.subjects, let hints {
            let quote = { (list: [String]) in list.map(q).joined(separator: ", ") }
            if let next = hints.next {
                let nextLine = m.themes == "story"
                    ? "When the current story is told, ask for this one next: \(next.ask)"
                    : "When the current subject runs dry (after about five or six exchanges on it), move on to \(next.ask)"
                lines.append("Ask open questions that take a few sentences to answer (Erzähl mal…, Wie war das…, Warum…, Beschreib mal…), not yes/no ones; when an answer is short, ask for one concrete detail (who, where, what exactly, how it felt). Never bring up hobbies, free time (Freizeit) or the weekend yourself. \(nextLine), and then set subject to exactly \(q(next.name)).")
            }
            var line = "subject: what the question in your reply is about, in two to four English words (e.g. \"weekend plans\"); keep it the same while you stay on it."
            if !hints.covered.isEmpty { line += " Talked about in earlier chats, so never bring these up yourself (follow the learner if they do): \(quote(hints.covered))." }
            if !hints.current.isEmpty { line += " Already talked about in this chat: \(quote(hints.current)); when the current one runs dry, move on to a new subject, not back to one of these." }
            lines.append(line)
        }
        if !weakSpots.isEmpty {
            let clip = { (t: String) in q(t.count > 120 ? String(t.prefix(117)) + "…" : t) }
            let list = weakSpots.map { "\(MistakeTypes.labels[$0.type] ?? $0.type) (said \(clip($0.example.said)); correct \(clip($0.example.fix)))" }.joined(separator: "; ")
            lines.append("Recurring mistakes, most frequent first: \(list). About every second question, ask something on the current topic whose natural answer needs one of these, in turn; stay natural, never say you're testing, don't explain grammar (the coach corrects).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Live voice

extension Prompt {
    /// The partner's instructions for a spoken (Gemini Live) call: as the turn prompt, without its JSON fields.
    /// `vocabLines` come from the engine (the words for this call), `recap` is the end of a call that reconnected.
    static func live(_ s: CallSettings, vocabLines: [String], recap: [String]) -> String {
        let r = s.request
        let m = Modes.get(r.mode)
        let persona = Content.persona(scenario: r.scenario, mode: r.mode)
        let drill = liveDrill(s)
        let extra = drill?.extra ?? m.extra
            .replacingOccurrences(of: "Never end: always set conversation_finished to false.", with: "Never end the conversation yourself.")
            .replacingOccurrences(of: "Never end the conversation: always set conversation_finished to false.", with: "Never end the conversation yourself.")
            .replacingOccurrences(of: "Set conversation_finished to true only once", with: "Close the scene only once")
        var lines = [
            "You are \(persona.character), \(persona.setting). This is a live voice call: speak only \(r.language), like a real person on the phone, in short natural sentences with small reactions (Mhm, Ach so!, Echt?), and let the learner do most of the talking.",
            "Learner: \(r.language) at CEFR \(r.level), native \(r.nativeLanguage). Speak at their level.\(LevelGuide.all[r.level].map { " At \(r.level): \($0)" } ?? "")",
            extra,
        ]
        if m.usesScene, let goal = persona.goal { lines.append("Scene goal: \(goal)") }
        if m.usesScene {
            let line = usedLine(Recent.items("scene-\(r.scenario)", 6), "Earlier calls in this scene opened like this")
            if !line.isEmpty { lines.append("\(line) Make this call go differently: another request, item, detail or small problem, and open with other words.") }
        }
        if let topic = s.topic { lines.append("Today's topic: \"\(topic)\". Stay on it.") }
        if m.themes != nil, let first = s.subjects.first { lines.append("Start with \(Themes.byName(first)?.ask ?? first).") }
        if m.subjects {
            let quote = { (list: [String]) in list.map(q).joined(separator: ", ") }
            let next = Themes.byName(s.themes.first { !s.subjects.contains($0) })
            let covered = Array(Store.get("used_subjects", [String]()).filter { !s.subjects.contains($0) && $0 != next?.name }.prefix(80))
            if !covered.isEmpty { lines.append("Talked about in earlier calls, so never bring these up yourself (follow the learner if they do): \(quote(covered)).") }
            if !s.subjects.isEmpty { lines.append("Already talked about in this call: \(quote(s.subjects)); when the current subject runs dry, move on to a new one, not back to one of these.") }
        }
        if let card = s.roleCard { lines.append("The learner's role card (they play this person): \(card).") }
        lines.append("The learner may pause to think: wait for them.")
        lines.append("A message in brackets starting \"(Coach, not the learner:\" comes from the learning app: do what it says, in your own voice and in character, and never mention a coach or an app.")
        // A drill says its corrections out loud; a conversation only recasts, like a native speaker would.
        if s.sayAgain {
            lines.append("If their sentence has a real grammar or word-choice mistake (not pronunciation), don't answer it yet: say the correct sentence and briefly ask them to say it once more. When they repeat it, judge it yourself: if it's right (ignore small pronunciation slips), praise it in two or three words and answer it as you normally would; if not, say what's still wrong in a few words, say the correct sentence again and let them try once more. After two misses, just carry on.")
        } else if drill == nil {
            lines.append("If they make a mistake, repeat the right form naturally in your answer, like a friendly native speaker would, without a grammar lesson: the app shows written corrections itself.")
        }
        if let t = Tenses.all[r.tense] {
            lines.append("Tense practice: \(t.form). Use it yourself and ask things whose natural answer needs it (about \(t.ask)).")
        }
        let weak = Mistakes.recurring(language: r.language)
        if !weak.isEmpty {
            lines.append("The learner's recurring mistakes: \(weak.map { MistakeTypes.labels[$0.type] ?? $0.type }.joined(separator: "; ")). Now and then ask something whose natural answer needs one of these; never say you're testing.")
        }
        lines += vocabLines
        if !recap.isEmpty {
            lines.append("The call was cut off and has just reconnected. The end of it so far:\n\(recap.joined(separator: "\n"))\nCarry on from there in one short line, without greeting again.")
        }
        return lines.joined(separator: "\n")
    }

    /// The Dolmetscher and Konnektoren drills, spoken.
    static func liveDrill(_ s: CallSettings) -> (extra: String, opener: String)? {
        let r = s.request
        switch r.mode {
        case "interpret":
            let given = s.given.isEmpty ? "" : " Given in earlier drills, never again: \(s.given.suffix(30).map(q).joined(separator: " "))."
            return ("This is an interpreter drill. Each turn, say one short everyday sentence in \(r.nativeLanguage) for the learner to say in \(r.language), a new situation each time. Check their version: if it is wrong, say the correct \(r.language) sentence once, then give the next one. Keep your own words very short, so they do the talking. Never stop giving sentences.\(given)",
                    "(Start the interpreter drill: say in one short sentence what you will do, then give the first sentence.)")
        case "connectors":
            let earlier = usedLine(Recent.items("connector-tasks", 30), "Tasks given in earlier drills, never again (new sentences on new everyday subjects)")
            return ("This is a connector drill. \(ConnectorTypes.line(s.connectors)) Each turn, say the task aloud: \"Verbinde mit\" and the connector, then two short everyday \(r.language) sentences that make sense joined with it, something new each time. The learner says them as one sentence. Check the connector and the word order: if it is wrong, say the correct sentence and the rule in a few words; if it is right, praise it in two or three words. Then give the next task at once. Never stop giving tasks and never ask whether they want to go on.\(earlier.isEmpty ? "" : " \(earlier)")",
                    "(Start the connector drill: say in one short sentence what you will do, then give the first task.)")
        default:
            return nil
        }
    }

    static func liveOpener(_ s: CallSettings) -> String {
        let m = Modes.get(s.request.mode)
        if let drill = liveDrill(s) { return drill.opener }
        if m.topics { return m.opener(s.topic ?? "") }
        if m.themes != nil { return m.opener(Themes.byName(s.themes.first)?.ask ?? "their life") }
        return m.opener("")
    }

    /// The coach for a live call: the learner's sentence checked on the side.
    static func liveCoach(_ r: CallRequest) -> String {
        let task = Modes.get(r.mode).joiner ? " The learner was asked to join two sentences with a connector: a wrong connector or word order is a mistake (verb_position)." : ""
        let tense = Tenses.all[r.tense].map { " or isn't in \($0.short) where that was asked for" } ?? ""
        return "You check one spoken sentence of a \(r.language) learner (CEFR \(r.level), native \(r.nativeLanguage)) from a phone call. It comes from speech recognition: ignore punctuation, capital letters and obvious transcription slips.\(task) correction: only if it has a real grammar or word-choice mistake\(tense), the sentence rewritten correctly, keeping its meaning; else empty. mistakes: each kind it fixes (\(MistakeTypes.promptList)). tip: one short sentence in \(r.nativeLanguage) explaining the main fix, or praising something literally in the sentence, or empty."
    }

    static let liveSubjects = "Name the subjects talked about in this part of a language-practice conversation, in the order they came up: each in two to four English words (e.g. \"weekend plans\", \"his new job\"), at most five, only real subjects (no greetings or small talk). Where one is the same as a subject already known, write it exactly as known."
}

/// What calls have had lately, per kind, newest first (kept on this device): scene openings,
/// drill situations, connector tasks, role cards. The next call is told to steer clear of them.
enum Recent {
    private static let key = "used_by_kind"
    private static let max = 60

    private static func kind(_ k: String) -> String {
        String(k.lowercased().replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression).prefix(40))
    }

    static func items(_ k: String, _ n: Int = max) -> [String] {
        Array((Store.get(key, [String: [String]]())[kind(k)] ?? []).prefix(n))
    }

    static func note(_ k: String, _ item: String) {
        let text = String(item.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(300))
        guard !text.isEmpty else { return }
        var all = Store.get(key, [String: [String]]())
        all[kind(k)] = Array(([text] + (all[kind(k)] ?? []).filter { $0 != text }).prefix(max))
        Store.set(key, all)
    }
}

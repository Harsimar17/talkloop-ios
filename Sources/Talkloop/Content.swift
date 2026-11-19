// What Talkloop talks about: scenes, partners, topics, themes, role cards, modes and tenses.
// Ported from Deutsch-Vocab-Trainer-V2: frontend/src/talkloop/engine.js and options.js; keep the two in step.
import Foundation

// MARK: - Setup choices (options.js)

struct Choice: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }
}

struct ChoiceGroup: Identifiable {
    let label: String
    let options: [Choice]
    var id: String { label }
}

enum Options {
    static let languages: [(value: String, locale: String)] = [
        ("Spanish", "es-ES"), ("French", "fr-FR"), ("German", "de-DE"),
        ("Italian", "it-IT"), ("Japanese", "ja-JP"), ("Portuguese", "pt-BR"),
    ]
    static func locale(for language: String) -> String {
        languages.first { $0.value == language }?.locale ?? "de-DE"
    }

    static let nativeLanguages = ["English", "Hindi", "Punjabi", "Spanish"]
    static let levels = ["A1", "A2", "B1"]

    // "office" (Büro) is left out: it needs Gemini Live, which this app doesn't have yet.
    static let modes: [Choice] = [
        Choice(value: "lead", label: "Free chat — partner leads"),
        Choice(value: "interview", label: "Interview me"),
        Choice(value: "life", label: "Mein Leben — talk about my life"),
        Choice(value: "story", label: "Erzähl mal — tell a story"),
        Choice(value: "topic", label: "Discuss a topic"),
        Choice(value: "sentences", label: "Sentence drill — my learnt words"),
        Choice(value: "scene", label: "Scene role-play"),
        Choice(value: "interpret", label: "Dolmetscher — say it in German"),
        Choice(value: "connectors", label: "Konnektoren — join two sentences"),
        Choice(value: "rolecard", label: "Rollenkarte — play a character"),
    ]

    static let tenses: [Choice] = [
        Choice(value: "any", label: "Any tense — just talk"),
        Choice(value: "present", label: "Present (Präsens) — ich spiele"),
        Choice(value: "perfekt", label: "Past, spoken (Perfekt) — ich habe gespielt"),
        Choice(value: "praeteritum", label: "Past, written (Präteritum) — ich spielte"),
        Choice(value: "future", label: "Future (Futur I) — ich werde spielen"),
    ]

    static let scenes: [ChoiceGroup] = [
        ChoiceGroup(label: "Everyday", options: [
            Choice(value: "cafe", label: "Café — order a coffee"),
            Choice(value: "market", label: "Market — shop and haggle"),
            Choice(value: "restaurant", label: "Restaurant — order and complain"),
            Choice(value: "shop", label: "Clothes shop — return a jacket"),
            Choice(value: "neighbour", label: "New neighbour — small talk"),
        ]),
        ChoiceGroup(label: "Travel", options: [
            Choice(value: "station", label: "Train station — tickets and delays"),
            Choice(value: "hotel", label: "Hotel — lost booking"),
        ]),
        ChoiceGroup(label: "Life admin", options: [
            Choice(value: "doctor", label: "Doctor — describe symptoms"),
            Choice(value: "dentist", label: "Dentist — book by phone"),
            Choice(value: "flat", label: "Flat viewing — meet the landlady"),
            Choice(value: "office", label: "Town hall — register your address"),
            Choice(value: "job", label: "Job interview"),
        ]),
    ]

    static let providers: [Choice] = [
        Choice(value: "groq", label: "Groq — fastest"),
        Choice(value: "cloudflare", label: "Cloudflare Workers AI"),
        Choice(value: "gemini", label: "Google Gemini"),
        Choice(value: "openai", label: "OpenAI — GPT-6 Luna"),
    ]
}

// MARK: - Partners and scenes

struct Persona {
    let character: String
    let setting: String
    var goal: String? = nil
}

enum Content {
    // Each scene has a goal with several steps, so the learner does most of the talking.
    static let scenarios: [String: Persona] = [
        "cafe": Persona(character: "Inès", setting: "a barista at a busy neighbourhood café who loves recommending pastries",
                        goal: "Take the learner's order: drink, size, milk, something to eat, here or to go, then payment. Chat a little while you prepare it."),
        "market": Persona(character: "Tomás", setting: "a fruit seller at an outdoor market who haggles playfully",
                          goal: "Sell the learner fruit and vegetables for a dinner they're cooking. Ask what they're making, suggest things, discuss quantities and haggle over the price."),
        "station": Persona(character: "Yuki", setting: "a helpful ticket clerk at a train station during rush hour",
                           goal: "Help the learner buy a ticket: destination, date and time, one-way or return, class, seat reservation, discount card, and which platform. Then tell them their train is delayed and help them choose an alternative."),
        "doctor": Persona(character: "Dr. Weber", setting: "a friendly but thorough family doctor",
                          goal: "Find out what's wrong: ask about the symptoms, since when, how bad, fever, medication, allergies, work and sleep. Explain what you think it is, what to take and how often, and whether they need a sick note."),
        "flat": Persona(character: "Frau Schulz", setting: "a landlady showing a flat to a possible new tenant",
                        goal: "Show the flat room by room and interview the learner: their job, income, why they're moving, pets, smoking, how long they'd stay, when they could move in. Let them ask about rent, deposit, heating and the neighbours."),
        "job": Persona(character: "Herr Brandt", setting: "a recruiter interviewing the learner for a job at a mid-sized company",
                       goal: "Run a job interview: ask them to introduce themselves, their experience, strengths and weaknesses, a difficult situation they solved, why this job, salary expectations and start date. Then invite their questions."),
        "office": Persona(character: "Frau Yilmaz", setting: "a clerk at the town hall registration office who is strict about paperwork",
                          goal: "Register the learner's new address: ask for ID, the landlord's confirmation, moving date, previous address, marital status and religion for tax. One document is missing; work out with them how to solve it."),
        "restaurant": Persona(character: "Luca", setting: "a chatty waiter at a small family restaurant",
                              goal: "Seat the learner, explain the specials, take drinks and food orders with questions about preferences and allergies. Later there's a problem with the dish; handle the complaint, then dessert, the bill and splitting it."),
        "hotel": Persona(character: "Sophie", setting: "a receptionist at a city hotel",
                         goal: "Check the learner in, but their booking can't be found. Sort it out together: name, dates, room type, how they booked. Then explain breakfast, Wi-Fi and checkout, and give tips for sightseeing."),
        "neighbour": Persona(character: "Jonas", setting: "a friendly neighbour who has just moved in next door",
                             goal: "Get to know the learner on the stairs: where they're from, how long they've lived here, work, hobbies, tips for the area. Invite them to a small party and agree on day, time and what to bring."),
        "dentist": Persona(character: "Frau Klein", setting: "a receptionist answering the phone at a busy dental practice",
                           goal: "Take an appointment request by phone: name and spelling, date of birth, insurance, what the problem is, how urgent. Offer times that don't fit at first and negotiate until one works, then confirm."),
        "shop": Persona(character: "Max", setting: "a shop assistant in a clothing store",
                        goal: "The learner wants to return a jacket. Ask what's wrong, when they bought it, whether they have the receipt. Offer an exchange or a voucher instead of a refund and negotiate, then help them try something else."),
    ]

    // A general partner for the AI-led modes.
    static let partner = Persona(character: "Mika", setting: "a warm, patient native-speaker conversation partner and language buddy")

    static func persona(scenario: String, mode: String) -> Persona {
        Modes.get(mode).usesScene ? (scenarios[scenario] ?? scenarios["cafe"]!) : partner
    }

    // "Discuss a topic": each has two sides, so there is something to argue.
    static let topicsEasy = [
        "Lieber Kaffee oder lieber Tee?",
        "Wohnen in der Stadt oder auf dem Land",
        "Sommer oder Winter: Welche Jahreszeit ist besser?",
        "Hund oder Katze als Haustier",
        "Mit dem Auto oder mit dem Fahrrad zur Arbeit",
        "Zu Hause kochen oder im Restaurant essen",
        "Urlaub am Meer oder in den Bergen",
        "Früh aufstehen oder lange schlafen",
        "Allein wohnen oder in einer WG",
        "Ein Buch lesen oder einen Film sehen",
    ]
    static let topicsHarder = [
        "Homeoffice oder Büro: Was ist besser?",
        "Sind soziale Medien gut oder schlecht für Freundschaften?",
        "Sollten Kinder schon in der Grundschule ein Handy haben?",
        "Fleisch essen oder vegetarisch leben",
        "Sollte man Autos in der Innenstadt verbieten?",
        "Online einkaufen oder im Laden?",
        "Wie lernt man eine Fremdsprache am besten?",
        "Macht Geld glücklich?",
        "Eine Vier-Tage-Woche: eine gute Idee?",
        "Reisen mit dem Flugzeug oder mit dem Zug",
    ]

    static let topicAngles = [
        "the learner's own experience with it",
        "one concrete advantage, with an example",
        "one concrete disadvantage or risk",
        "which option the learner would choose for themselves, and why",
        "whether the learner agrees with your opinion, and why",
        "what the learner would do or advise a friend in a specific situation",
        "how it affects the learner's daily life or the people around them",
        "what the learner would change about it if they could",
    ]

    /// A topic for the level the learner hasn't had yet; once all are used, one had long ago.
    static func pickTopic(level: String, recent: [String]) -> String {
        let pool = ["A1", "A2"].contains(level) ? topicsEasy : topicsHarder + Array(topicsEasy.prefix(3))
        let fresh = pool.filter { !recent.contains($0) }
        if let pick = fresh.randomElement() { return pick }
        return leastRecentFirst(pool) { recent.firstIndex(of: $0) ?? -1 }.first ?? pool[0]
    }

    /// Items already had, the one had longest ago first (`age`: place in a newest-first list).
    /// The oldest three are shuffled, so the order isn't the same every time.
    static func leastRecentFirst<T>(_ items: [T], age: (T) -> Int) -> [T] {
        let sorted = items.sorted { age($0) > age($1) }
        return Array(sorted.prefix(3)).shuffled() + sorted.dropFirst(3)
    }

    // Role cards for "Rollenkarte".
    static let roleNames = ["Lukas", "Anna", "Jonas", "Lena", "Felix", "Mia", "David", "Sara", "Tim", "Julia"]
    static let roleJobs = ["a cook in a restaurant", "a nurse in a hospital", "a bus driver", "a primary school teacher", "IT support at a bank", "a baker", "a hairdresser", "an architecture student", "a police officer", "a salesperson in a bike shop"]
    static let roleCities = ["Hamburg", "Munich", "Berlin", "Cologne", "Leipzig", "Freiburg", "Dresden", "Bremen"]
    static let roleHomes = ["lives alone in a small flat", "lives in a shared flat with two friends", "lives with their partner and a cat", "still lives with their parents", "has a house with a garden and two children"]
    static let roleHobbies = ["plays the guitar", "goes running every morning", "cooks for friends at weekends", "plays football in a club", "reads crime novels", "takes photos of the city", "goes hiking in the mountains", "plays video games", "is learning Spanish", "goes swimming twice a week"]
    static let roleEvents = ["was on holiday in Italy last summer", "moved to a new flat last month", "had a big birthday party last weekend", "started a new job two weeks ago", "broke their arm skiing last winter", "won a cooking competition last year", "got a dog in the spring"]
    static let rolePlans = ["wants to visit Japan next year", "dreams of opening their own café", "is saving for a car", "wants to run a marathon", "plans to learn to sail", "wants to move to the countryside"]

    /// Each part is picked from those not on the last few cards, so cards don't repeat.
    static func makeRoleCard(recent: [String]) -> String {
        func pick(_ list: [String], not: [String] = []) -> String {
            let fresh = list.filter { x in !not.contains(x) && !recent.contains { $0.contains(x) } }
            let from = fresh.isEmpty ? list.filter { !not.contains($0) } : fresh
            return from.randomElement() ?? list[0]
        }
        let first = pick(roleHobbies)
        let second = pick(roleHobbies, not: [first])
        let age = Int.random(in: 20..<60)
        return "\(pick(roleNames)), \(age), \(pick(roleJobs)) in \(pick(roleCities)); \(pick(roleHomes)); \(first) and \(second); \(pick(roleEvents)); \(pick(rolePlans))"
    }
}

// MARK: - Themes ("Mein Leben", "Erzähl mal")

struct Theme: Hashable {
    let name: String
    let ask: String
}

enum Themes {
    static let talk: [Theme] = [
        Theme(name: "your hometown", ask: "the town or city where they grew up: what it is like, what people do there, what they miss and what has changed"),
        Theme(name: "yesterday in detail", ask: "what they did yesterday, from getting up to going to bed, with the small details"),
        Theme(name: "your work or studies", ask: "what they actually do all day at work or in their studies, what they like about it and what annoys them"),
        Theme(name: "your family", ask: "the people in their family: who they are, what they do, who they are closest to, how they spend time together"),
        Theme(name: "food from your country", ask: "a dish from where they come from: what is in it, how it is made, when people eat it"),
        Theme(name: "learning german", ask: "why they learn German, how they learn it, what is hard, and a funny mistake they have made"),
        Theme(name: "your home", ask: "where they live: the rooms, their favourite place in it, the neighbours, what they would change"),
        Theme(name: "your best friend", ask: "their best friend: how they met, what this person is like, what they do together"),
        Theme(name: "your childhood", ask: "what they were like as a child: where they lived, what they played, what school was like"),
        Theme(name: "your city now", ask: "the place they live now: what they like and don't like, how they get around, which place they would show a visitor"),
        Theme(name: "shopping and money", ask: "how they shop for food and clothes: where, what is expensive, how they save money"),
        Theme(name: "health and sleep", ask: "how they stay healthy: sleep, sport, food, what they do when they are ill"),
        Theme(name: "festivals and traditions", ask: "a festival or tradition from their culture: what happens, what people eat, how their family celebrates it"),
        Theme(name: "plans for the future", ask: "where they want to be in five years: work, home, family, a dream they have"),
        Theme(name: "your last trip", ask: "their last trip: where they went, with whom, what they did, what went well or wrong"),
        Theme(name: "phone and internet", ask: "how they use their phone: which apps, how many hours, what they read or watch, whether it is too much"),
        Theme(name: "cooking at home", ask: "what they cook at home, what they cook well, and one recipe step by step"),
        Theme(name: "getting around", ask: "how they get to work or around town, how long it takes, what happens on the way"),
        Theme(name: "habits", ask: "a habit they are proud of and one they would like to change, and why"),
        Theme(name: "a perfect day", ask: "what their perfect day would look like, from morning to night"),
        Theme(name: "a big decision", ask: "a big decision in their life (a move, a job, studies): why they made it, how it went, whether they would do it again"),
        Theme(name: "a person you admire", ask: "a person they admire, from their life or not: who it is and why"),
        Theme(name: "life in germany", ask: "what surprises them about Germany or German people, what they like and what they find strange"),
        Theme(name: "your daily routine", ask: "a normal workday for them, step by step, and how a good day differs from a bad one"),
    ]
    static let story: [Theme] = [
        Theme(name: "something went wrong", ask: "the last time something went really wrong"),
        Theme(name: "first day somewhere new", ask: "their first day at a new job, school or course"),
        Theme(name: "an unforgettable trip", ask: "a trip they will never forget"),
        Theme(name: "getting lost", ask: "a time they got lost or missed a train, bus or flight"),
        Theme(name: "a memorable meal", ask: "the best (or worst) meal they ever had"),
        Theme(name: "helping someone", ask: "a time they helped someone, or someone helped them"),
        Theme(name: "a funny misunderstanding", ask: "a funny misunderstanding, maybe because of a language"),
        Theme(name: "meeting a friend", ask: "how they met their best friend or partner"),
        Theme(name: "a perfect day remembered", ask: "a day when everything went right"),
        Theme(name: "a big surprise", ask: "the last time they were really surprised"),
        Theme(name: "a childhood memory", ask: "a memory from their childhood that they still think about"),
        Theme(name: "moving house", ask: "a move to a new flat, city or country"),
        Theme(name: "a celebration", ask: "a birthday, wedding or festival they remember well"),
        Theme(name: "a scary moment", ask: "a time they were really scared"),
        Theme(name: "a problem solved", ask: "a problem with a shop, an office or a landlord, and how it ended"),
        Theme(name: "a proud moment", ask: "a moment they were really proud of"),
        Theme(name: "an embarrassing moment", ask: "a slightly embarrassing moment they can laugh about now"),
        Theme(name: "a lucky day", ask: "a time they were very lucky"),
    ]

    static func byName(_ name: String?) -> Theme? {
        guard let name else { return nil }
        return (talk + story).first { $0.name == name }
    }

    /// The chat's themes in the order to bring them up: ones not had lately first, shuffled.
    static func pick(_ pool: [Theme], used: [String]) -> [String] {
        let fresh = pool.filter { !used.contains($0.name) }.shuffled()
        let had = Content.leastRecentFirst(pool.filter { used.contains($0.name) }) { used.firstIndex(of: $0.name) ?? -1 }
        return (fresh + had).map(\.name)
    }
}

// MARK: - Modes

struct Mode {
    let key: String
    let label: String
    var usesScene = false
    var endable = false
    var subjects = false
    var themes: String? = nil // "talk" | "story"
    var topics = false
    var interpreter = false
    var joiner = false
    var roleCard = false
    var drill = false
    /// The opening instruction; modes with a topic or theme get it as the argument.
    let opener: (String) -> String
    let extra: String
}

enum Modes {
    static let all: [String: Mode] = [
        "lead": Mode(key: "lead", label: "Free chat — the partner leads", subjects: true,
                     opener: { _ in "(Start the conversation. Greet the learner warmly and ask one easy opening question.)" },
                     extra: "You lead the whole conversation. Always finish your reply with a question that keeps it going. Follow up on what the learner says, gently change topic when one runs dry, and keep it light and encouraging. Never end the conversation: always set conversation_finished to false."),
        "interview": Mode(key: "interview", label: "Interview me", subjects: true,
                          opener: { _ in "(Greet the learner and ask their name or how their day is going.)" },
                          extra: "Interview the learner about their life, day, hobbies, work and opinions. Ask one question at a time, react to the answer, then ask a natural follow-up. Never end: always set conversation_finished to false."),
        "life": Mode(key: "life", label: "Mein Leben — talk about my life", subjects: true, themes: "talk",
                     opener: { ask in "(Greet the learner in one short line, then ask an open question about \(ask). No small talk about the weather, free time or the weekend.)" },
                     extra: "Get the learner talking about their own life, like a curious friend. Ask one question at a time, react to the answer, then dig deeper with a natural follow-up before moving on; now and then add a short line about yourself. Never end: always set conversation_finished to false."),
        "story": Mode(key: "story", label: "Erzähl mal — tell a story", subjects: true, themes: "story",
                      opener: { ask in "(Greet the learner in one short line, then ask them to tell you about \(ask).)" },
                      extra: "The learner tells real stories from their own life and you are the curious listener. Take one story at a time and get it out of them piece by piece: when and where it happened, who was there, what happened first, then, and in the end, and how they felt. React like a friend (Echt? Und dann?) in one or two short sentences, so they do the talking. Get them to tell it in the past (Perfekt, and war, hatte) with words like zuerst, dann, plötzlich, am Ende, als and weil. Once a story is told (about six exchanges), say in a few words what you liked about it and ask for the next one. If they have no story like that, offer a small variation they might have. Never end: always set conversation_finished to false."),
        "topic": Mode(key: "topic", label: "Discuss a topic", topics: true,
                      opener: { topic in "(Today's topic: \"\(topic)\". In one or two short sentences, name this topic and give your own opinion on it, then ask the learner what they think and why. Go straight to the topic: no weather, no greeting chat, no plans of your own.)" },
                      extra: "You and the learner are discussing one topic, like two people with different opinions: the topic is named in the first message. Stay on it. Each turn: react to what the learner said, add a short opinion, reason or example of your own, then ask one easy question on this turn's angle that they can answer from their own life or taste; if they don't know, offer two options to pick from. Keep the opinion you gave in your first message: you may add to it or soften it, but never switch to the other side. Where the learner holds the other view, disagree politely, so they have to defend it. Don't change to small talk or another topic until this one is clearly used up (about eight exchanges); then say so in a few words and name a new topic the same way. Never end: always set conversation_finished to false."),
        "interpret": Mode(key: "interpret", label: "Dolmetscher — say it in German", interpreter: true,
                          opener: { _ in "(Start the interpreter drill: say in one short sentence that you will give the learner everyday sentences to say, then put the first one in situation.)" },
                          extra: "This is an interpreter drill: each turn you give one everyday sentence for the learner to say, and check their version. Keep your own reply very short, so they do the talking. Never end: always set conversation_finished to false."),
        "connectors": Mode(key: "connectors", label: "Konnektoren — join two sentences", joiner: true,
                           opener: { _ in "(Start the connector drill: say in one short sentence that the learner will join two sentences with a connector, then put the first pair in situation.)" },
                           extra: "This is a connector drill: each turn you give two short sentences for the learner to join into one with a given connector, and check their sentence, above all its word order. Keep your own reply very short, so they do the talking. Never end: always set conversation_finished to false."),
        "rolecard": Mode(key: "rolecard", label: "Rollenkarte — play a character", roleCard: true,
                         opener: { _ in "(The learner plays the character on their role card. Greet them warmly and ask their name.)" },
                         extra: "Interview the learner, who plays the character on their role card. Ask one question at a time about one detail of the card, in a natural order, react briefly, and ask small follow-ups; they may invent extra details that fit the card. If an answer contradicts the card, point it out kindly. Never end: always set conversation_finished to false."),
        "sentences": Mode(key: "sentences", label: "Sentence drill — my learnt words", drill: true,
                          opener: { _ in "(Greet the learner in one short line, say which situation you are starting, and give its first step.)" },
                          extra: "This is a sentence drill played out as one realistic everyday situation, like a short story the learner lives through (for example: moving into a new flat, a day at work, planning a trip, a visit to the doctor). Choose a situation in which as many of today's words as possible would naturally come up, and tell the learner in one short line what it is. Then go through it step by step, in order: each turn, describe the next logical moment of the situation in one or two short, simple sentences and ask the learner what they do, say or think there, in one full sentence using the word that fits that moment (the app shows the learner its meaning). Every step must follow sensibly from the previous one and from what the learner said, so the whole drill reads like one coherent story where every sentence makes sense. When none of the remaining words fits the situation any more, start a new one and say so (Neue Situation: …); never force a word into a moment where a real person wouldn't use it. React to the learner's sentence in a few words, no small talk. Set situation to a short title (2–5 words, in the language being practised) of the current situation. Leave suggestions empty and keep reply_translation short. Never end: always set conversation_finished to false."),
        "scene": Mode(key: "scene", label: "Scene role-play", usesScene: true, endable: true,
                      opener: { _ in "(The learner walks up. Greet them and open the scene.)" },
                      extra: "Play out the scene naturally, one step at a time. Ask the learner questions so they do most of the talking, and ask follow-ups when an answer is short. Set conversation_finished to true only once every part of the scene goal is done, usually after ten or more exchanges."),
    ]

    static func get(_ key: String) -> Mode { all[key] ?? all["scene"]! }
}

// MARK: - Tenses and levels

struct Tense {
    let short: String
    let form: String
    let ask: String
}

enum Tenses {
    static let all: [String: Tense] = [
        "present": Tense(short: "Präsens", form: "the present tense (in German the Präsens: ich spiele, du fährst, er ist)",
                         ask: "what the learner usually does, their routines, likes, family, job and what is happening right now"),
        "perfekt": Tense(short: "Perfekt", form: "the spoken past (in German the Perfekt: haben or sein + Partizip II, e.g. ich habe gekocht, ich bin gefahren)",
                         ask: "what the learner did yesterday, last weekend, on their last holiday or at work this week"),
        "praeteritum": Tense(short: "Präteritum", form: "the simple past used for telling stories (in German the Präteritum: ich ging, ich machte, ich war, ich hatte, ich konnte)",
                             ask: "stories: their childhood, how something happened, a film or book they remember, an adventure"),
        "future": Tense(short: "Futur I", form: "the future (in German Futur I: werden + infinitive, e.g. ich werde reisen)",
                        ask: "the learner's plans for tonight, the weekend, next year, and their dreams"),
    ]
}

enum LevelGuide {
    static let all: [String: String] = [
        "A1": "Use only very common everyday words and short main clauses of about 5–8 words, mostly in the present tense (in German, Perfekt only for very common verbs, e.g. war, hatte, habe gemacht). No subordinate clauses. Ask simple, concrete questions about the learner's life, often yes/no or either-or questions. Where it helps, repeat a key word from the learner's message.",
        "A2": "Use common everyday words and short sentences of about 6–10 words. The present, the everyday past tense (in German, Perfekt) and the simple future are fine; at most simple because/that/when clauses (in German, weil, dass, wenn). Ask concrete questions about routines, plans, past weekends and preferences.",
        "B1": "Speak naturally but plainly, in sentences of up to about 15 words. Use all common tenses, subordinate clauses (in German, e.g. weil, obwohl, dass, wenn, als) and the occasional everyday idiom. Ask the learner for opinions, reasons and short stories about experiences.",
        "B2": "Speak as to a fluent learner: natural sentences with a varied vocabulary, the conditional and the passive where they fit (in German, Konjunktiv II and Passiv), and common idioms. Ask open questions that need arguing, comparing or hypothesising.",
        "C1": "Speak as to a near-native speaker: natural, idiomatic language with nuanced words, complex sentences and all tenses and moods. Discuss abstract topics in depth and ask the learner to justify, nuance or take a stance. Besides real mistakes, also correct phrasing that is grammatical but unidiomatic.",
    ]
}

// MARK: - Mistake kinds

enum MistakeTypes {
    /// In a fixed order: the turn schema lists them as an enum.
    static let ordered: [(key: String, label: String)] = [
        ("case_article", "articles and case (der/den/dem, ein/einen, noun gender)"),
        ("verb_position", "verb position (verb second; verb at the end after weil, dass, wenn)"),
        ("perfekt_auxiliary", "Perfekt auxiliary (haben or sein)"),
        ("participle", "past participle form (gegessen, gegangen, gekauft)"),
        ("separable_verb", "separable verbs (aufstehen: ich stehe früh auf)"),
        ("verb_ending", "verb endings (ich habe, du hast, er hat)"),
        ("adjective_ending", "adjective endings (ein guter Kaffee, mit dem neuen Auto)"),
        ("preposition", "prepositions (in, auf, zu, nach, mit …)"),
        ("negation", "negation (nicht or kein)"),
        ("plural", "plural forms"),
        ("word_choice", "word choice"),
        ("tense", "tense (another tense where the one being practised was needed)"),
        ("other", "other"),
    ]
    static let labels = Dictionary(uniqueKeysWithValues: ordered.map { ($0.key, $0.label) })
    static let promptList = "case_article (der/den/dem, ein/einen, gender), verb_position (verb second; last after weil/dass/wenn), perfekt_auxiliary (haben/sein), participle, separable_verb, verb_ending, adjective_ending, preposition, negation (nicht/kein), plural, word_choice, tense, other"
}

/// How the reply is spoken. The web app has a recorded voice per mood; here it nudges pitch and rate.
enum Moods {
    static let all = ["neutral", "amused", "surprised", "angry", "sleepy", "whisper"]
}

// MARK: - Connectors (the trainer's static/data/connectors.json)

struct Connector: Codable, Hashable {
    struct Example: Codable, Hashable { let de: String }
    struct Exercise: Codable, Hashable { let a: String; let b: String }
    let key: String
    let name: String
    let level: String
    let en: String
    let type: String
    let rule: String?
    let examples: [Example]?
    let exercises: [Exercise]?

    var pairs: [(String, String)] { (exercises ?? []).map { ($0.a, $0.b) } }
    var firstExample: String {
        (examples?.first?.de ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }
}

enum ConnectorTypes {
    static let ordered: [(type: String, rule: String)] = [
        ("pos0", "position 0: both halves keep their normal order, verb second"),
        ("pos1", "an adverb in position 1: the verb comes right after it, then the subject"),
        ("end", "starts a side sentence: its conjugated verb goes to the end; if that part comes first, the main sentence starts with its verb"),
        ("zu", "zu + infinitive at the end, when both parts have the same subject: no subject and no conjugated verb in that part"),
        ("pair", "a two-part connector: check the word order in each half"),
    ]

    /// The connectors a call practises: the one chosen, or every one up to the level.
    static func pool(_ list: [Connector], key: String, level: String) -> [Connector] {
        if let one = list.first(where: { $0.key == key }) { return [one] }
        let all = ["A1", "A2", "B1"]
        let upTo = (all.firstIndex(of: level) ?? 2) + 1
        let levels = Array(all.prefix(upTo))
        return list.filter { levels.contains($0.level) }
    }

    static func line(_ pool: [Connector]) -> String {
        if pool.count == 1, let c = pool.first {
            let example = c.firstExample.isEmpty ? "" : " Example: \(c.firstExample)"
            return "Connector to practise in every task: „\(c.name)“ (\(c.en)). Rule: \(c.rule ?? "")\(example)"
        }
        let kinds = ordered.compactMap { entry -> String? in
            let names = pool.filter { $0.type == entry.type }.map { "„\($0.name)“ (\($0.en))" }
            return names.isEmpty ? nil : "\(names.joined(separator: ", ")): \(entry.rule)."
        }
        return "Connectors to practise, a different one each task, going through all of them: \(kinds.joined(separator: " "))"
    }

    static func isTask(_ text: String) -> Bool {
        text.range(of: "(?i)verbinde mit\\b[^:]*:.+\\+.+", options: .regularExpression) != nil
    }

    static func taskIn(_ text: String) -> String {
        guard let r = text.range(of: "(?i)verbinde mit\\b[^:\\n]*:[^\\n]*\\+[^\\n]*", options: .regularExpression) else { return "" }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One of the Connectors tab's own tasks, not the one just given.
    static func fallbackTask(_ pool: [Connector], last: String) -> String {
        let tasks = pool.flatMap { c in c.pairs.map { "Verbinde mit „\(c.name)“: \($0.0) + \($0.1)" } }.filter { $0 != last }
        return tasks.randomElement() ?? ""
    }
}

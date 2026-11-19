import SwiftUI

/// Talkloop's screens: keys, setup, or the call.
struct TalkloopView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            switch engine.screen {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(engine.keyStatus.isEmpty ? "Connecting…" : engine.keyStatus).foregroundStyle(.secondary)
                }
            case .keys:
                NavigationStack { KeyGateView() }
            case .setup:
                NavigationStack { SetupView() }
            case .call:
                CallView()
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .background { engine.flushSyncs() }
        }
    }
}

// MARK: - Keys

struct KeyGateView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    @State private var provider = ""
    @State private var typed: [String: String] = [:]
    @State private var model = ""

    private static let fieldInfo: [String: (label: String, placeholder: String, secret: Bool)] = [
        "openai": ("OpenAI API key", "sk-…", true),
        "groq": ("Groq API key", "gsk_…", true),
        "mistral": ("Mistral API key (optional — used when Groq is busy)", "Mistral key", true),
        "groq2": ("Backup Groq key (optional — another account's)", "gsk_…", true),
        "groq3": ("Second backup Groq key (optional)", "gsk_…", true),
        "cfAccount": ("Cloudflare account ID", "32 characters", false),
        "cfToken": ("Cloudflare API token (Workers AI)", "token", true),
        "gemini": ("Gemini API key", "AIza… or AQ.…", true),
        "gemini2": ("Backup Gemini key (optional)", "AIza… or AQ.…", true),
        "geminiLive": ("Gemini Live key (optional — for the live voice call; blank uses the Gemini key above)", "AIza… or AQ.…", true),
    ]

    var body: some View {
        Form {
            Section {
                Text(engine.keys.keys.isEmpty
                     ? "Paste your AI key once: it is saved in your Vocab Trainer account and loads every time you log in."
                     : "Your AI keys are saved in your Vocab Trainer account. Pick the AI to talk to (✓ = key saved).")
                    .foregroundStyle(.secondary)
                Picker("Conversation AI", selection: $provider) {
                    ForEach(Options.providers) { p in
                        Text(p.label + (engine.keys.ready(p.value) ? " ✓" : "")).tag(p.value)
                    }
                }
                Toggle("Double-check my grammar with LanguageTool (free, no key)", isOn: $engine.grammarCheck)
            }
            Section("Keys") {
                ForEach(engine.keyFields(for: provider), id: \.self) { service in
                    let info = Self.fieldInfo[service] ?? (service, "", true)
                    let placeholder = engine.keys.key(service).isEmpty ? info.placeholder : "Saved — leave blank to keep"
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.label).font(.footnote).foregroundStyle(.secondary)
                        Group {
                            if info.secret {
                                SecureField(placeholder, text: binding(service))
                            } else {
                                TextField(placeholder, text: binding(service))
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                if provider == "openai" {
                    TextField("Model (blank for gpt-6-luna)", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            Section {
                Button(engine.keys.ready(provider) ? "Connect" : "Save to my account") {
                    Task {
                        if await engine.saveKeys(provider: provider, typed: typed, openaiModel: model) { typed = [:] }
                    }
                }
                if !engine.keys.keys.isEmpty && !engine.editingSavedKeys {
                    Button("Change my saved keys") { engine.editingSavedKeys = true }
                }
                if engine.keys.ready(engine.keys.provider) {
                    Button("Back to the start screen") { engine.refreshKeyGate(); engine.screen = .setup }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !engine.keyStatus.isEmpty { Text(engine.keyStatus) }
                    Text("Free keys: console.groq.com/keys · aistudio.google.com/apikey · console.mistral.ai")
                }
            }
        }
        .navigationTitle("Connect an AI")
        .onAppear { if provider.isEmpty { provider = engine.keys.provider } }
    }

    private func binding(_ service: String) -> Binding<String> {
        Binding(get: { typed[service] ?? "" }, set: { typed[service] = $0 })
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    @EnvironmentObject private var app: AppModel
    @State private var starting = false
    @State private var showMistakes = false

    var body: some View {
        let mode = Modes.get(engine.form.mode)
        Form {
            Section {
                Picker("Talk with", selection: Binding(get: { engine.keys.provider }, set: { engine.chooseAi($0) })) {
                    ForEach(engine.aiChoices) { Text($0.label).tag($0.value) }
                }
                Text(engine.keys.summary).font(.footnote).foregroundStyle(.secondary)
                Button("Add or change keys") { engine.changeKeys() }
            }

            if let recap = engine.recap {
                Section("Last call") {
                    if !recap.said.isEmpty { LabeledLine(label: "Said ✓", text: recap.said.joined(separator: ", ")) }
                    if !recap.tried.isEmpty { LabeledLine(label: "Practise again", text: recap.tried.joined(separator: ", ")) }
                    if !recap.missed.isEmpty { LabeledLine(label: "Not reached", text: recap.missed.joined(separator: ", ")) }
                    Text("\(recap.automatic) word\(recap.automatic == 1 ? "" : "s") automatic so far. Words come back after 1, 3, 7 and 21 days.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Start a conversation") {
                Picker("Practise", selection: $engine.form.language) {
                    ForEach(Options.languages.map { $0.value }, id: \.self) { Text($0).tag($0) }
                }
                Picker("I speak", selection: $engine.form.native) {
                    ForEach(Options.nativeLanguages, id: \.self) { Text($0).tag($0) }
                }
                Picker("Level", selection: $engine.form.level) {
                    ForEach(Options.levels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Mode", selection: $engine.form.mode) {
                    ForEach(Options.modes) { Text($0.label).tag($0.value) }
                }
                Picker("Tense to practise", selection: $engine.form.tense) {
                    ForEach(Options.tenses) { Text($0.label).tag($0.value) }
                }
                if mode.usesScene {
                    Picker("Scene", selection: $engine.form.scenario) {
                        ForEach(Options.scenes) { group in
                            Section(group.label) {
                                ForEach(group.options) { Text($0.label).tag($0.value) }
                            }
                        }
                    }
                }
                if mode.joiner {
                    Picker("Connector", selection: $engine.form.connector) {
                        Text("Mix — all up to my level").tag("mix")
                        ForEach(engine.connectorGroups) { group in
                            Section(group.label) {
                                ForEach(group.options) { Text($0.label).tag($0.value) }
                            }
                        }
                    }
                }
            }

            Section("My vocabulary") {
                Text(engine.trainerStatus).font(.footnote).foregroundStyle(.secondary)
                if !engine.vocabStatus.isEmpty {
                    Text(engine.vocabStatus).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Weave my vocab into the conversation (words up to my level)", isOn: $engine.form.useVocab)
                Toggle("Repeat each corrected sentence before moving on", isOn: $engine.form.sayAgain)
                Toggle(isOn: $engine.liveVoice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live voice call")
                        Text("Gemini Live: replies in about a second and you can interrupt. Not for the sentence drill.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button {
                    starting = true
                    Task {
                        await engine.startConversation()
                        starting = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        Text(starting ? "Starting…" : "Start conversation").bold()
                        Spacer()
                    }
                }
                .disabled(starting)
            }
        }
        .navigationTitle("Speaking practice")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("🔥 \(engine.streak)").accessibilityLabel("Streak: \(engine.streak) days")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("My mistakes") { showMistakes = true }
                    Button("Log out (\(app.email))", role: .destructive) { app.logout() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showMistakes) { MistakesView() }
    }
}

struct LabeledLine: View {
    let label: String
    let text: String
    var body: some View {
        (Text("\(label): ").bold() + Text(text))
    }
}

// MARK: - Mistakes

struct MistakesView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                let spots = engine.mistakes()
                if spots.isEmpty {
                    Text("No mistakes recorded in \(engine.form.language) yet.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(spots, id: \.type) { spot in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(MistakeTypes.labels[spot.type] ?? spot.type) · \(spot.count)×").bold()
                                Text("You said: \(spot.example.said)").font(.footnote)
                                Text("Better: \(spot.example.fix)").font(.footnote).foregroundStyle(.green)
                            }
                        }
                    } footer: {
                        Text("The ones that keep coming back are worked into your next calls. Synced with your Vocab Trainer account.")
                    }
                    Section {
                        Button("Start over", role: .destructive) { confirmReset = true }
                    }
                }
            }
            .id(engine.mistakesVersion)
            .navigationTitle("My mistakes")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Clear the mistake log for \(engine.form.language)?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { engine.resetMistakes() }
            }
        }
    }
}

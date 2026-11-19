import SwiftUI

/// The call: the partner's header, the transcript, the coach, and the dock to talk or type.
struct CallView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    @FocusState private var typing: Bool
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            dock
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showLog) { DebugLogView() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor.gradient)
                .frame(width: 44, height: 44)
                .overlay(Text(String(engine.callName.split(separator: " ").last?.prefix(1) ?? "?")).font(.title3.bold()).foregroundStyle(.white))
                .overlay(Circle().stroke(Color.green, lineWidth: engine.micOn ? 3 : 0))
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.callName).font(.headline)
                Text(engine.callMode).font(.caption).foregroundStyle(.secondary)
                if !engine.callTopic.isEmpty {
                    Text(engine.callTopic).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Button("🐞") { showLog = true }.font(.caption).accessibilityLabel("Debug log")
                    Text(engine.timerText).font(.caption.monospacedDigit())
                }
                Text(engine.paused ? "On hold"
                     : engine.isLiveCall ? (!engine.liveConnected ? "Connecting…" : engine.liveSpeaking ? "Speaking" : engine.micOn ? "Live" : "Muted")
                     : engine.busy ? "Thinking…" : engine.micOn ? "Listening" : "")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.transcript) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if let coach = engine.coach { CoachView(coach: coach) }
                    if let drill = engine.drill { DrillView(drill: drill) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: engine.transcript.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            .onChange(of: engine.drill?.target) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
        }
    }

    // MARK: Dock

    private var dock: some View {
        VStack(spacing: 8) {
            if let sayThis = engine.sayThis {
                (Text(sayThis.label).foregroundStyle(.secondary) + Text(sayThis.text).bold())
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !engine.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text(engine.chipsLabel).font(.caption).foregroundStyle(.secondary)
                        ForEach(engine.chips) { chip in
                            Button(chip.text) { if chip.peekable { engine.peekWord(chip.id) } }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(chipColor(chip).opacity(0.18), in: Capsule())
                                .overlay(Capsule().stroke(chip.current ? Color.accentColor : .clear, lineWidth: 1.5))
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !engine.heard.isEmpty {
                HStack(alignment: .top) {
                    Text("🎙️ \(engine.heard)").font(.callout).italic()
                    Spacer()
                    Button("✎ Edit") { engine.heardEdit(); typing = true }.font(.caption)
                    Button("✕ Delete") { engine.heardDelete() }.font(.caption)
                }
            }
            if !engine.suggestions.isEmpty && engine.drill == nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(engine.suggestions, id: \.self) { s in
                            Button(s) { engine.useSuggestion(s) }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            if !engine.status.isEmpty {
                Text(engine.status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Type your answer…", text: $engine.composer, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .onSubmit { engine.submitComposer() }
                    .disabled(engine.busy && engine.drill == nil)
                Button("Send") { engine.submitComposer() }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.composer.trimmingCharacters(in: .whitespaces).isEmpty && engine.heard.isEmpty)
            }
            if !typing {
                HStack(spacing: 18) {
                    Toggle(isOn: Binding(get: { engine.autoSend }, set: { engine.setAutoSend($0) })) {
                        Text("Auto-send").font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    Spacer()
                    roundButton(engine.paused ? "play.fill" : "pause.fill", tint: .orange, label: engine.paused ? "Resume" : "Pause") {
                        engine.togglePause()
                    }
                    roundButton(engine.micOn ? "mic.fill" : (engine.isLiveCall ? "mic.slash" : "mic"), tint: engine.micOn ? .green : .accentColor, size: 64,
                                label: engine.isLiveCall ? (engine.micOn ? "Mute" : "Unmute") : (engine.micOn ? "Stop hands-free" : "Talk hands-free")) {
                        engine.micTap()
                    }
                    .disabled(engine.paused)
                    roundButton("phone.down.fill", tint: .red, label: "End the conversation") {
                        engine.endCall()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func chipColor(_ chip: WordChip) -> Color {
        switch chip.state {
        case .said: return .green
        case .tried: return .orange
        case .plain: return .accentColor
        }
    }

    private func roundButton(_ symbol: String, tint: Color, size: CGFloat = 48, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(.white)
                .background(tint, in: Circle())
        }
        .accessibilityLabel(label)
    }
}

struct MessageBubble: View {
    @EnvironmentObject private var engine: TalkloopEngine
    let message: ChatMessage

    var body: some View {
        let mine = message.kind == .learner
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(message.who).font(.caption2).foregroundStyle(.secondary)
            highlighted
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            if message.kind == .character {
                if message.showTranslation && !message.translation.isEmpty {
                    Text(message.translation).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Button("▶ Replay") { engine.replay(message.id) }
                    if !message.translation.isEmpty {
                        Button(message.showTranslation ? "Hide translation" : "Translate") { engine.toggleTranslation(message.id) }
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// The word being spoken stands out.
    private var highlighted: Text {
        let ns = message.text as NSString
        guard let r = message.speaking, r.location != NSNotFound, NSMaxRange(r) <= ns.length else {
            return Text(message.text)
        }
        let before = ns.substring(to: r.location)
        let word = ns.substring(with: r)
        let after = ns.substring(from: NSMaxRange(r))
        return Text(before) + Text(word).bold().foregroundColor(.accentColor) + Text(after)
    }
}

struct CoachView: View {
    let coach: CoachCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coach.understood {
                Text("That didn't quite land. Try one of the suggestions below.").font(.callout)
            }
            if !coach.correction.isEmpty {
                (Text("More natural: ").bold() + Text(coach.correction)).font(.callout)
            }
            if !coach.tip.isEmpty {
                Text("💡 \(coach.tip)").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DrillView: View {
    @EnvironmentObject private var engine: TalkloopEngine
    let drill: DrillCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say the corrected sentence").font(.caption).foregroundStyle(.secondary)
            Text(drill.target).font(.title3.weight(.semibold))
            if !drill.feedback.isEmpty {
                Text(drill.feedback).font(.callout).foregroundStyle(drill.ok ? .green : .orange)
            }
            HStack {
                Button("🎤 Say it") { engine.drillSay() }.buttonStyle(.borderedProminent)
                Button("▶ Hear it") { engine.drillHear() }.buttonStyle(.bordered)
                Spacer()
                Button("Skip") { engine.skipDrill() }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

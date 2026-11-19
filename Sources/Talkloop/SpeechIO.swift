// Speech in and out. Apple's speech recognition replaces the browser's, and AVSpeechSynthesizer
// replaces the web app's Piper and Gemini voices (it reports each word as it is spoken, which
// drives the highlighting).
import AVFoundation
import Speech

enum AudioSession {
    /// One session for the whole call: the mic and the voice take turns on it.
    static func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? s.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }
}

/// Listens until the learner pauses, then hands over what it heard.
@MainActor
final class Listener {
    /// How long a pause ends the learner's turn.
    static let silence: Duration = .milliseconds(1500)

    var onHeard: (String) -> Void = { _ in }
    /// Called once per listen with the final text (empty if nothing was heard), unless cancelled.
    var onEnd: (String) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var heard = ""

    var isListening: Bool { request != nil }

    func start(locale: String) {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            onError("Speech recognition isn't available for \(locale) on this device. You can still type.")
            return
        }
        AudioSession.activate()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req
        heard = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            onError("The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if let text {
                    self.heard = text
                    self.onHeard(text)
                    // Count the pause from the last words heard, final or not.
                    if !text.isEmpty { self.armSilence() }
                }
                if isFinal || (failed && text == nil) { self.finish() }
            }
        }
    }

    private func armSilence() {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: Listener.silence)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// Stops and hands over what was heard (as the pause would).
    func finish() {
        guard request != nil else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        onEnd(text)
    }

    /// Stops without handing anything over.
    func cancel() {
        teardown()
    }

    private func teardown() {
        silenceTimer?.cancel()
        silenceTimer = nil
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// Speaks a reply and reports which characters are being spoken.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var onRange: (NSRange?) -> Void = { _ in }
    private var onDone: () -> Void = {}
    private var current: AVSpeechUtterance?

    var isSpeaking: Bool { current != nil }

    override init() {
        super.init()
        synth.delegate = self
    }

    // Apple's novelty voices sound synthetic; they are never picked.
    private static let novelty = try? NSRegularExpression(
        pattern: "^(eddy|flo|grandma|grandpa|reed|rocko|sandy|shelley|albert|bad news|bahh|bells|boing|bubbles|cellos|good news|jester|organ|superstar|trinoids|whisper|wobble|zarvox|fred|junior|ralph|kathy)\\b",
        options: [.caseInsensitive])

    /// The best installed voice for a locale: premium, then enhanced, then any.
    static func voice(for locale: String) -> AVSpeechSynthesisVoice? {
        let lang = String(locale.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix(lang)
                && novelty?.firstMatch(in: v.name, range: NSRange(location: 0, length: (v.name as NSString).length)) == nil
        }
        let ranked = voices.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return (a.language == locale ? 0 : 1) < (b.language == locale ? 0 : 1)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: locale)
    }

    func speak(_ text: String, locale: String, slow: Bool, mood: String = "neutral",
               onRange: @escaping (NSRange?) -> Void = { _ in }, onDone: @escaping () -> Void = {}) {
        stop()
        AudioSession.activate()
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.voice(for: locale)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * (slow ? 0.9 : 1)
        switch mood {
        case "amused", "surprised": u.pitchMultiplier = 1.1
        case "sleepy": u.rate *= 0.9; u.pitchMultiplier = 0.95
        case "whisper": u.volume = 0.6
        case "angry": u.rate *= 1.05; u.pitchMultiplier = 0.95
        default: break
        }
        self.onRange = onRange
        self.onDone = onDone
        current = u
        synth.speak(u)
    }

    func stop() {
        // A stopped voice doesn't continue the call: its onDone is dropped.
        guard current != nil else { return }
        current = nil
        onRange = { _ in }
        onDone = {}
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.onRange(characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard utterance === self.current else { return }
            self.current = nil
            self.onRange(nil)
            let done = self.onDone
            self.onDone = {}
            done()
        }
    }
}

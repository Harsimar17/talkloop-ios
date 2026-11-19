// Live voice (Gemini Live), ported from the "live voice" part of engine.js. With it the call is
// a real one: Gemini hears the learner's voice and answers in its own over one WebSocket, so a
// reply starts in about a second and the learner can interrupt it. Nothing waits for a JSON
// turn: the engine checks each sentence on the side (liveCoach).
//
// This class is the connection and the audio. The mic goes out as 16 kHz 16-bit PCM in 100 ms
// chunks, only while the learner is talking (the Live API bills every second it is sent);
// Gemini's voice is played gap-free as its chunks arrive, through the same audio engine with
// Apple's voice processing on, so the phone's echo cancellation keeps Gemini from hearing itself.
import AVFoundation
import Foundation

@MainActor
final class LiveCall {
    struct Events {
        /// Connected and set up; the opening line has been asked for.
        var ready: () -> Void = {}
        /// The learner's turn is over: what Gemini heard them say.
        var learnerTurn: (String) -> Void = { _ in }
        /// The partner's words so far, while it speaks.
        var replyText: (String) -> Void = { _ in }
        /// The partner's turn is over (empty if it said nothing).
        var replyDone: (String) -> Void = { _ in }
        /// Gemini's voice started or stopped.
        var speaking: (Bool) -> Void = { _ in }
        /// The connection closed by itself (not by stop()).
        var closed: (_ beforeReady: Bool, _ resumed: Bool, _ goingAway: Bool, _ reason: String) -> Void = { _, _, _, _ in }
    }

    static let url = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    private static let inRate = 16000.0 // what the Live API wants from the mic
    private static let chunk = 1600 // 100 ms of mic audio per message
    private static let preroll = 3 // chunks sent from just before speech starts
    private static let hangover = 15 // chunks still sent after the last loud one (a short thinking pause)
    private static let minLevel = 0.006 // RMS below which nothing counts as speech, however quiet the room
    private static let bargeInLevel = 0.04 // the same while Gemini speaks: only a clearly raised voice cuts in
    private static let voice = "Puck"

    var events = Events()
    private(set) var ready = false
    private(set) var isSpeaking = false
    /// Muted (or paused): the mic sends nothing, the call stays up.
    var muted = false {
        didSet {
            if muted && talking {
                talking = false
                send(["realtimeInput": ["audioStreamEnd": true]])
            }
        }
    }

    private let resumed: Bool
    private var socket: URLSessionWebSocketTask?
    private var ending = false
    private var goingAway = false
    private var heard = ""
    private var reply = ""

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playFormat: AVAudioFormat?
    private var micTask: Task<Void, Never>?
    private var micBuf: [Int16] = []
    private var micPos = 0.0
    private var floor: Double?
    private var talking = false
    private var quiet = 0
    private var prerollChunks: [[Int16]] = []
    private var pending = 0 // voice buffers scheduled and not played yet
    private var generation = 0 // bumped when the voice is cut off, so late completions are ignored

    init(resumed: Bool) {
        self.resumed = resumed
    }

    // MARK: - Model and resumption handle

    /// The Live model this key can use: Gemini 3.8 Live if the key has it, else the newest one
    /// that takes a live session. Looked up rather than written here, kept for a day.
    static func model(key: String) async throws -> String {
        struct Saved: Codable { var name: String; var at: Double; var key: String }
        let suffix = String(key.suffix(6))
        if let saved = Store.get("live_model", Saved?.none), saved.key == suffix, nowMs() - saved.at < 86_400_000 {
            return saved.name
        }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&key=\(encoded)")!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIError.message("Gemini didn't list its models (\(status)): check the Gemini Live key.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let names = (json["models"] as? [[String: Any]] ?? [])
            .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("bidiGenerateContent") }
            .compactMap { $0["name"] as? String }
        func version(_ name: String) -> Double {
            guard let r = name.range(of: "gemini-(\\d+(\\.\\d+)?)", options: .regularExpression) else { return 0 }
            return Double(name[r].dropFirst("gemini-".count)) ?? 0
        }
        func rank(_ name: String) -> Double {
            (name.range(of: "gemini-3\\.8[^/]*live", options: .regularExpression) != nil ? 1000 : 0)
                + version(name) * 10
                + (name.range(of: "native-audio|live", options: .regularExpression) != nil ? 1 : 0)
        }
        guard let best = names.max(by: { rank($0) < rank($1) }) else { throw AIError.message("This Gemini key has no live voice model.") }
        Store.set("live_model", Saved(name: best, at: nowMs(), key: suffix))
        return best
    }

    static func forgetModel() { Store.remove("live_model") }

    // Gemini keeps a live call's conversation on its side and hands out a resumption handle: a
    // dropped connection carries on the same conversation. Google keeps one about two hours.
    private struct Handle: Codable { var handle: String; var at: Double }
    static var savedHandle: String? {
        guard let h = Store.get("live_handle", Handle?.none), nowMs() - h.at < 2 * 60 * 60 * 1000 else { return nil }
        return h.handle
    }
    static func clearHandle() { Store.remove("live_handle") }

    // MARK: - Starting and stopping

    func start(key: String, model: String, systemPrompt: String, handle: String?) throws {
        // The mic and Gemini's voice share one engine with voice processing (echo cancellation).
        debug("live: model \(model)\(handle != nil ? " (resuming)" : "")")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        // The loudspeaker, unless headphones are plugged in (voice chat otherwise may pick the earpiece).
        let headphonePorts: [AVAudioSession.Port] = [.headphones, .bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        let headphones = session.currentRoute.outputs.contains { headphonePorts.contains($0.portType) }
        if !headphones { try? session.overrideOutputAudioPort(.speaker) }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Voice processing ducks playback by default, which can make Gemini's voice nearly silent.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        playFormat = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1

        let inFormat = input.outputFormat(forBus: 0)
        let rate = inFormat.sampleRate
        debug("live: mic format \(Int(rate)) Hz, \(inFormat.channelCount) ch; output \(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz")
        if rate <= 0 { throw AIError.message("the microphone gave no audio format") }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(50))
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            continuation.yield(Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength))))
        }
        engine.prepare()
        try engine.start()
        player.play()
        DebugLog.shared.logRoute("live: audio started (engine running \(engine.isRunning), player \(player.isPlaying))")
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DebugLog.shared.logRoute("live: route changed") }
        }
        micTask = Task { [weak self] in
            for await samples in stream {
                self?.micSamples(samples, rate: rate)
            }
        }

        var url = URLComponents(string: Self.url)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let task = URLSession.shared.webSocketTask(with: url.url!)
        socket = task
        task.resume()
        let voice: [String: Any] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.voice]]]
        let genConfig: [String: Any] = ["responseModalities": ["AUDIO"], "speechConfig": voice]
        var resumption: [String: Any] = [:]
        if let handle { resumption["handle"] = handle }
        let setup: [String: Any] = [
            "model": model,
            "generationConfig": genConfig,
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            // Handles to carry the call on after a dropped connection, and no 15-minute limit.
            "sessionResumption": resumption,
            "contextWindowCompression": ["slidingWindow": [String: Any]()],
        ]
        send(["setup": setup])
        debug("live: connecting, setup sent")
        Task { [weak self] in await self?.receiveLoop(task) }
    }

    private var routeObserver: NSObjectProtocol?
    private var received = 0
    private var voiceChunks = 0
    private var voiceSeconds = 0.0
    private var micChunks = 0
    private var micSent = 0
    private var micPeak = 0.0

    /// Ends the call: what was said so far is handed over first.
    func stop() {
        guard !ending else { return }
        ending = true
        debug("live: stopped (received \(received) messages, played \(voiceChunks) voice chunks = \(String(format: "%.1f", voiceSeconds)) s, mic sent \(micSent) of \(micChunks) chunks)")
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        flushLearner()
        flushReply()
        stopVoice()
        micTask?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    // MARK: - Sending

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            guard let error else { return }
            Task { @MainActor in debug("live: send failed: \(error.localizedDescription)") }
        }
    }

    private func sendTurn(_ text: String) {
        let turn: [String: Any] = ["role": "user", "parts": [["text": text]]]
        let content: [String: Any] = ["turns": [turn], "turnComplete": true]
        send(["clientContent": content])
    }

    /// Typed by the learner: sent as text (the engine shows and checks it).
    func sendText(_ text: String) {
        flushReply()
        stopVoice()
        sendTurn(text)
    }

    /// A note to Gemini from the app (not the learner): it cuts off what it was saying.
    func note(_ text: String) {
        flushReply()
        stopVoice()
        sendTurn("(Coach, not the learner: \(text))")
    }

    // MARK: - The mic

    /// The mic's samples, at the hardware rate, down to 16 kHz 16-bit PCM in 100 ms chunks.
    private func micSamples(_ samples: [Float], rate: Double) {
        guard !ending, !muted, ready else { return }
        let step = rate / Self.inRate
        var pos = micPos
        while pos < Double(samples.count) {
            let v = max(-1, min(1, samples[Int(pos)]))
            micBuf.append(Int16(v < 0 ? v * 32768 : v * 32767))
            if micBuf.count == Self.chunk {
                gate(micBuf)
                micBuf.removeAll(keepingCapacity: true)
            }
            pos += step
        }
        micPos = pos - Double(samples.count) // where the next block's first sample falls
    }

    /// Only speech goes to Gemini: a chunk counts as speech when it is clearly louder than the
    /// room's noise floor. The 300 ms before it go too, and 1.5 s after it (so Gemini hears the
    /// pause and answers); then audioStreamEnd tells Gemini the stream has stopped.
    private func gate(_ chunk: [Int16]) {
        var sum = 0.0
        for v in chunk { sum += Double(v) * Double(v) }
        let rms = (sum / Double(chunk.count)).squareRoot() / 32768
        micChunks += 1
        micPeak = max(micPeak, rms)
        if micChunks % 50 == 0 { // every 5 s
            debug("live: mic loudest \(String(format: "%.3f", micPeak)), noise floor \(String(format: "%.3f", floor ?? 0)), sent \(micSent)/\(micChunks) chunks")
            micPeak = 0
        }
        // The noise floor follows quiet stretches quickly and loud ones slowly, and stays put
        // while Gemini speaks (what's left of its voice would raise it).
        if !isSpeaking {
            if let f = floor { floor = rms < f ? f * 0.7 + rms * 0.3 : f * 0.995 + rms * 0.005 } else { floor = rms }
        }
        let level = isSpeaking ? Self.bargeInLevel : Self.minLevel
        if rms > max(level, (floor ?? 0) * 2.5) {
            if !talking {
                talking = true
                prerollChunks.forEach(sendAudio)
                prerollChunks = []
            }
            quiet = 0
            sendAudio(chunk)
        } else if talking {
            sendAudio(chunk)
            quiet += 1
            if quiet >= Self.hangover {
                talking = false
                send(["realtimeInput": ["audioStreamEnd": true]])
            }
        } else {
            prerollChunks.append(chunk)
            if prerollChunks.count > Self.preroll { prerollChunks.removeFirst() }
        }
    }

    private func sendAudio(_ chunk: [Int16]) {
        micSent += 1
        let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) } // little-endian on iOS
        send(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    // MARK: - Gemini's voice

    private func play(_ b64: String) {
        guard let format = playFormat, let data = Data(base64Encoded: b64), data.count >= 2 else { return }
        let count = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            let pcm = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: pcm[i])) / 32768 }
        }
        voiceChunks += 1
        voiceSeconds += Double(count) / format.sampleRate
        if voiceChunks == 1 || voiceChunks % 25 == 0 {
            debug("live: voice chunk \(voiceChunks) (\(String(format: "%.1f", voiceSeconds)) s so far); engine running \(engine.isRunning), player playing \(player.isPlaying)")
        }
        if !engine.isRunning {
            do { try engine.start(); debug("live: audio engine restarted") } catch { debug("live: audio engine won't start: \(error.localizedDescription)") }
        }
        pending += 1
        setSpeaking(true)
        let gen = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.pending -= 1
                if self.pending <= 0 { self.pending = 0; self.setSpeaking(false) }
            }
        }
        if !player.isPlaying { player.play() }
    }

    func stopVoice() {
        generation += 1
        pending = 0
        player.stop()
        if engine.isRunning { player.play() } // ready for the next reply
        setSpeaking(false)
    }

    private func setSpeaking(_ on: Bool) {
        guard on != isSpeaking else { return }
        isSpeaking = on
        events.speaking(on)
    }

    // MARK: - Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while socket === task {
            do {
                let message = try await task.receive()
                let data: Data?
                switch message {
                case let .string(text): data = text.data(using: .utf8)
                case let .data(d): data = d
                @unknown default: data = nil
                }
                received += 1
                if let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    if received <= 3 || json["error"] != nil {
                        debug("live: message \(received): \(json.keys.sorted().joined(separator: ", "))\(json["error"].map { " \($0)" } ?? "")")
                    }
                    handle(json)
                } else {
                    debug("live: message \(received) unreadable (\(data?.count ?? 0) bytes)")
                }
            } catch {
                guard socket === task, !ending else { return }
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? error.localizedDescription
                debug("live: connection closed (code \(task.closeCode.rawValue)): \(reason)")
                let wasReady = ready
                stop()
                events.closed(!wasReady, resumed, goingAway, reason)
                return
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        if msg["setupComplete"] != nil {
            debug("live: setup complete, asking for the opening line")
            ready = true
            events.ready()
            return
        }
        if let update = msg["sessionResumptionUpdate"] as? [String: Any],
           update["resumable"] as? Bool == true, let newHandle = update["newHandle"] as? String {
            Store.set("live_handle", Handle(handle: newHandle, at: nowMs()))
        }
        if msg["goAway"] != nil { goingAway = true } // Google is about to close: reconnect with the handle
        guard let c = msg["serverContent"] as? [String: Any] else { return }
        if let t = (c["inputTranscription"] as? [String: Any])?["text"] as? String { heard += t }
        let parts = (c["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let said = (c["outputTranscription"] as? [String: Any])?["text"] as? String
        if said != nil || !parts.isEmpty { flushLearner() } // the learner's turn is over
        for p in parts {
            if let inline = p["inlineData"] as? [String: Any], let b64 = inline["data"] as? String { play(b64) }
        }
        if let said {
            reply += said
            events.replyText(reply)
        }
        if c["interrupted"] as? Bool == true { stopVoice() } // the learner talked over it
        if c["turnComplete"] as? Bool == true {
            flushLearner()
            flushReply()
        }
    }

    /// The opening line (or carrying on after a reconnect): the partner speaks first.
    func open(with instruction: String) {
        sendTurn(instruction)
    }

    private func flushLearner() {
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        if !said.isEmpty { events.learnerTurn(said) }
    }

    private func flushReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        reply = ""
        events.replyDone(text)
    }
}

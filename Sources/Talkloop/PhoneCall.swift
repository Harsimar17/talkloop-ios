// The live voice call as a phone call, through CallKit, like WhatsApp: with the phone locked the
// iOS call screen shows the partner's name and the call time, with End and Mute; unlocked, the green
// pill (or the Dynamic Island) shows it is running and leads back to the app. Ending or muting there
// ends or mutes the call in the app, and a real phone call coming in puts this one on hold.
//
// CallKit owns the audio session during the call: it activates it (provider(_:didActivate:)) after
// the call starts, and the live audio starts once it has (waitForAudio).
import AVFoundation
import CallKit
import UIKit

@MainActor
final class PhoneCall: NSObject, CXProviderDelegate {
    /// Ended from the iOS call screen (or by iOS).
    var onEnd: () -> Void = {}
    /// Muted or unmuted from the iOS call screen.
    var onMute: (Bool) -> Void = { _ in }
    /// Put on hold by iOS (another call came in), or taken off hold.
    var onHold: (Bool) -> Void = { _ in }
    /// CallKit (re)activated the audio session: the live audio may need starting again.
    var onAudioActive: () -> Void = {}

    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuid: UUID?
    private var partner = ""
    private var connected = false
    private var muted = false
    private var held = false
    private(set) var audioActive = false

    var active: Bool { uuid != nil }

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false // practice calls stay out of the Phone app's Recents
        if let icon = UIImage(systemName: "bubble.left.and.bubble.right.fill",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)) {
            config.iconTemplateImageData = icon.pngData()
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // MARK: - From the app

    /// Starts the phone call for a live call with this partner.
    func start(partner: String) {
        guard uuid == nil else { return }
        let id = UUID()
        uuid = id
        self.partner = partner
        connected = false
        muted = false
        held = false
        // CallKit expects the call's audio set up before it activates the session.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: partner))
        action.isVideo = false
        debug("phone call: starting")
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                debug("phone call: couldn't start (\(error.localizedDescription)); the call goes on in the app only")
                if self?.uuid == id { self?.uuid = nil }
            }
        }
    }

    /// Waits (up to 2 s) until CallKit has activated the audio session, so the live audio starts on it.
    func waitForAudio() async {
        for _ in 0..<20 {
            guard uuid != nil, !audioActive else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        debug("phone call: audio not activated after 2 s, starting anyway")
    }

    /// The live call is connected: the call time starts on the iOS call screen.
    func reportConnected() {
        guard let uuid, !connected else { return }
        connected = true
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    /// Muted or unmuted in the app: the iOS call screen shows the same.
    func setMuted(_ on: Bool) {
        guard let uuid, on != muted else { return }
        muted = on
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: on))) { _ in }
    }

    /// Carried on in the app after iOS put the call on hold: CallKit gives the audio back.
    func resume() {
        guard let uuid, held else { return }
        held = false
        controller.request(CXTransaction(action: CXSetHeldCallAction(call: uuid, onHold: false))) { _ in }
    }

    /// Ended in the app: the iOS call screen goes away.
    func end() {
        guard let id = uuid else { return }
        uuid = nil // so ending it here isn't reported back as ended from iOS
        debug("phone call: ending")
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded) }
        }
    }

    // MARK: - From iOS (CXProviderDelegate, called on the main queue)

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            debug("phone call: reset by iOS")
            audioActive = false
            if uuid != nil {
                uuid = nil
                onEnd()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            guard action.callUUID == uuid else { action.fail(); return }
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: partner)
            update.localizedCallerName = partner
            update.hasVideo = false
            update.supportsHolding = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            provider.reportCall(with: action.callUUID, updated: update)
            provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let fromIOS = action.callUUID == uuid
            if fromIOS {
                debug("phone call: ended from the iOS call screen")
                uuid = nil
            }
            action.fulfill()
            if fromIOS { onEnd() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            let changed = action.callUUID == uuid && action.isMuted != muted
            if changed { muted = action.isMuted }
            action.fulfill()
            if changed { onMute(action.isMuted) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        MainActor.assumeIsolated {
            guard action.callUUID == uuid else { action.fulfill(); return }
            debug("phone call: \(action.isOnHold ? "put on hold" : "taken off hold") by iOS")
            held = action.isOnHold
            action.fulfill()
            onHold(action.isOnHold)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            debug("phone call: audio session activated")
            audioActive = true
            onAudioActive()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            debug("phone call: audio session deactivated")
            audioActive = false
        }
    }
}

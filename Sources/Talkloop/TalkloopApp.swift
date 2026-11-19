// Talkloop for iPhone: the Vocab Trainer's speaking practice as a native app.
import SwiftUI

@main
struct TalkloopApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

/// The Vocab Trainer login. Talkloop only opens for a logged-in learner, as on the web.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var token: String?
    @Published private(set) var email = Store.get("email", "")
    @Published var loginError = ""
    @Published var loggingIn = false
    @Published private(set) var engine: TalkloopEngine?

    init() {
        if let saved = Keychain.get("session"), Backend.tokenValid(saved) { token = saved }
        if token != nil { makeEngine() }
    }

    private func makeEngine() {
        engine = TalkloopEngine(
            sessionToken: { [weak self] in self?.token },
            onRenewedToken: { [weak self] renewed in
                self?.token = renewed
                Keychain.set("session", renewed)
            },
            onLoggedOut: { [weak self] in self?.logout() }
        )
    }

    func login(email: String, password: String) async {
        loggingIn = true
        loginError = ""
        defer { loggingIn = false }
        do {
            let result = try await Backend.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            Keychain.set("session", result.token)
            Store.set("email", result.email)
            self.email = result.email
            token = result.token
            makeEngine()
        } catch {
            loginError = error.localizedDescription
        }
    }

    func logout() {
        engine?.endCall()
        engine = nil
        token = nil
        Keychain.set("session", nil)
        Store.remove("trainer_link")
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        if let engine = app.engine {
            TalkloopView()
                .environmentObject(engine)
                .task { await engine.start() }
                .id(ObjectIdentifier(engine))
        } else {
            LoginView()
        }
    }
}

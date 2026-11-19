import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var email = Store.get("email", "")
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Talkloop").font(.largeTitle.bold())
                        Text("Speaking practice with an AI partner, in German.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section("Your Vocab Trainer account") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(login)
                }
                Section {
                    Button(action: login) {
                        HStack {
                            Text(app.loggingIn ? "Logging in…" : "Log in")
                            if app.loggingIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(app.loggingIn || email.isEmpty || password.isEmpty)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !app.loginError.isEmpty {
                            Text(app.loginError).foregroundStyle(.red)
                        }
                        Text("The server sleeps when nobody uses it, so the first login of the day can take up to a minute.")
                    }
                }
            }
        }
    }

    private func login() {
        Task { await app.login(email: email, password: password) }
    }
}

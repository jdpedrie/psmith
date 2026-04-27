import SwiftUI
import ClarkKit

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var username = ""
    @State private var password = ""
    @State private var inFlight = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Clark")
                .font(.title2)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disableAutocorrection(true)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { Task { await submit() } }
            }
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button {
                Task { await submit() }
            } label: {
                if inFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign in").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: 320)
            .disabled(username.isEmpty || password.isEmpty || inFlight)
        }
        .padding(40)
    }

    private func submit() async {
        guard !inFlight else { return }
        inFlight = true
        errorMessage = nil
        do {
            _ = try await app.client.auth.login(
                username: username,
                password: password,
                clientLabel: "macOS"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        inFlight = false
    }
}

import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Social Login") {
                    ForEach(SupabaseOAuthProvider.allCases) { provider in
                        Button("Use \(provider.title)") {
                            Task { await appModel.signInWithOAuth(provider: provider) }
                        }
                        .disabled(appModel.isBusy)
                    }
                }

                Section("Email Login") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)

                    Button("Login") {
                        Task { await appModel.signIn(email: email, password: password) }
                    }
                    .disabled(appModel.isBusy || email.isEmpty || password.isEmpty)

                    Button("Create Account") {
                        Task { await appModel.signUp(email: email, password: password) }
                    }
                    .disabled(appModel.isBusy || email.isEmpty || password.count < 6)
                }

                Section("Status") {
                    if appModel.isBusy {
                        ProgressView()
                    }
                    Text(appModel.statusMessage.isEmpty ? "Log in to test Supabase memory." : appModel.statusMessage)
                        .font(.footnote)
                }
            }
            .navigationTitle("Memory Login")
        }
    }
}

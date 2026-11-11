import SwiftUI

/// Shows a question from ssh, such as a password, key passphrase, or verification code.
struct SSHPromptSheet: View {
    let prompt: SpeechController.SSHPrompt
    let host: String
    let answer: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("SSH · \(host)", size: 12)
            Text(prompt.text)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if prompt.isSecret {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.ui(13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.bgTertiary, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(focused ? Theme.green : Theme.borderSubtle))
            .focused($focused)
            .onSubmit { answer(text) }
            Text("Sent only to ssh for this connection. Not saved.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.textMuted)
            HStack {
                Spacer()
                Button("Cancel") { answer(nil) }
                    .buttonStyle(.editor(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { answer(text) }
                    .buttonStyle(.editor(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.bgSecondary)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }
}

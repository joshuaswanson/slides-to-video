import SwiftUI

struct PlaybackBar: View {
    let talk: TalkPlayer

    var body: some View {
        HStack(spacing: 12) {
            if let error = talk.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer()
            } else {
                Text(format(talk.currentTime)).monospacedDigit()
                ProgressView(value: talk.duration > 0 ? min(talk.currentTime / talk.duration, 1) : 0)
                    .tint(.green)
                Text(format(talk.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

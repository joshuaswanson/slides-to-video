import SwiftUI

@MainActor
@Observable
final class Toasts {
    enum Kind { case info, success, error }

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let kind: Kind
    }

    private(set) var items: [Toast] = []

    func show(_ message: String, _ kind: Kind = .info) {
        let toast = Toast(message: message, kind: kind)
        withAnimation(.easeOut(duration: 0.2)) { items.append(toast) }
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 3))
            withAnimation(.easeIn(duration: 0.2)) { items.removeAll { $0.id == toast.id } }
        }
    }
}

struct ToastOverlay: View {
    let toasts: Toasts

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts.items) { toast in
                Text(toast.message)
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusMedium))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium).strokeBorder(border(toast.kind)))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .frame(maxWidth: 520)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.bottom, 100)
        .allowsHitTesting(false)
    }

    private func border(_ kind: Toasts.Kind) -> Color {
        switch kind {
        case .info: Theme.borderSubtle
        case .success: Theme.greenDim
        case .error: Theme.red
        }
    }
}

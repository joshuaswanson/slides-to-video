import AppKit
import SwiftUI

/// Centers the window's close, minimize, and zoom buttons vertically in the custom top bar.
struct TrafficLightPositioner: NSViewRepresentable {
    var barHeight: CGFloat = 48
    var leading: CGFloat = 18

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(view.window, barHeight: barHeight, leading: leading) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(view.window, barHeight: barHeight, leading: leading) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var barHeight: CGFloat = 48
        private var leading: CGFloat = 18

        func attach(_ window: NSWindow?, barHeight: CGFloat, leading: CGFloat) {
            self.barHeight = barHeight
            self.leading = leading
            guard let window else { return }
            if window !== self.window {
                self.window = window
                observers.forEach(NotificationCenter.default.removeObserver)
                let names: [Notification.Name] = [
                    NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                    NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                    NSWindow.didExitFullScreenNotification,
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.position() }
                    }
                }
            }
            position()
        }

        private func position() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            var frame = container.frame
            frame.size.height = barHeight
            frame.origin.y = window.frame.height - barHeight
            container.frame = frame
            titlebar.frame = NSRect(x: 0, y: 0, width: frame.width, height: barHeight)
            var x = leading
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                button.setFrameOrigin(NSPoint(x: x, y: ((barHeight - button.frame.height) / 2).rounded()))
                x += 20
            }
        }
    }
}

import AppKit
import SwiftUI

/// Watches the MenuBarExtra panel window from inside its content.
///
/// - Visibility: `onDisappear` is not reliably called when the panel closes, so
///   the window's occlusion state decides whether the panel is visible.
/// - Size and position: MenuBarExtra grows its window when the content gets
///   taller ("All" list, technician mode) but never shrinks it, and it resizes
///   from the bottom edge. The content is then centred in a too-tall window and
///   looks detached from the menu bar. This view sits behind the content, so its
///   height is the content height: the window is fitted to it with the top edge
///   kept where the panel opened.
@available(macOS 14.0, *)
struct PanelWindowObserver: NSViewRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onVisibilityChange: onVisibilityChange)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let onVisibilityChange: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var anchoredTop: CGFloat?

        init(onVisibilityChange: @escaping @MainActor (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            })
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepTopEdge() }
            })
            visibilityChanged()
        }

        private func visibilityChanged() {
            guard let window else { return }
            let visible = window.isVisible && window.occlusionState.contains(.visible)
            // Remember where the system placed the panel; forget it when hidden so
            // the next opening can be placed afresh (e.g. on another screen).
            anchoredTop = visible ? window.frame.maxY : nil
            onVisibilityChange(visible)
            // The content may have changed size while the panel was closed (e.g.
            // technician mode switched in Settings); fit the window on opening.
            if visible { keepTopEdge() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            keepTopEdge()
        }

        /// Fits the window to the content height and keeps its top edge.
        private func keepTopEdge() {
            guard let window, let top = anchoredTop, bounds.height > 0 else { return }
            let contentRect = NSRect(x: 0, y: 0, width: window.contentLayoutRect.width, height: bounds.height)
            let height = window.frameRect(forContentRect: contentRect).height
            let target = NSRect(x: window.frame.minX, y: top - height, width: window.frame.width, height: height)
            guard abs(window.frame.height - height) > 0.5 || abs(window.frame.maxY - top) > 0.5 else { return }
            window.setFrame(target, display: true)
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

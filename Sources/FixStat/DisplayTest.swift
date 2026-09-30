import AppKit
import MacSensors
import SwiftUI
import FixStatCore

@available(macOS 14.0, *)
struct DisplayTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var shown: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let screen = DisplayInfo.builtInScreen() {
                Text(verbatim: DisplayInfo.describe(screen))
                    .font(.headline)
            }
            HStack(spacing: 6) {
                ForEach(DisplayPattern.allCases, id: \.self) { pattern in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pattern.swatch)
                        .frame(width: 30, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                        .overlay {
                            if shown.contains(pattern.rawValue) {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.gray)
                            }
                        }
                }
            }
            Button("Start full-screen test") {
                DisplayTestWindow.show { index in
                    shown.insert(index)
                    if let screen = DisplayInfo.builtInScreen() {
                        monitor.recordCheck(.display, detail: DisplayInfo.describe(screen)
                            + " · " + DisplayInfo.patternsShown(shown.count))
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

@available(macOS 14.0, *)
enum DisplayPattern: Int, CaseIterable {
    case black, white, red, green, blue, gray, gradient

    var swatch: AnyShapeStyle {
        switch self {
        case .black: AnyShapeStyle(Color.black)
        case .white: AnyShapeStyle(Color.white)
        case .red: AnyShapeStyle(Color(red: 1, green: 0, blue: 0))
        case .green: AnyShapeStyle(Color(red: 0, green: 1, blue: 0))
        case .blue: AnyShapeStyle(Color(red: 0, green: 0, blue: 1))
        case .gray: AnyShapeStyle(Color(white: 0.5))
        case .gradient: AnyShapeStyle(LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// Borderless full-screen window on the built-in display cycling through the patterns.
@available(macOS 14.0, *)
@MainActor
final class DisplayTestWindow: NSWindow {
    private static var current: DisplayTestWindow?
    private var index = 0
    private var onShow: ((Int) -> Void)?
    private var host: NSHostingView<PatternView>?

    static func show(onShow: @escaping (Int) -> Void) {
        guard current == nil, let screen = DisplayInfo.builtInScreen() else { return }
        let window = DisplayTestWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered,
                                       defer: false, screen: screen)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onShow = onShow
        window.setFrame(screen.frame, display: true)
        window.showPattern(0, hint: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSCursor.hide()
        current = window
    }

    override var canBecomeKey: Bool { true }

    private func showPattern(_ i: Int, hint: Bool = false) {
        index = i
        let view = PatternView(pattern: DisplayPattern.allCases[i], hint: hint)
        if let host { host.rootView = view } else {
            let host = NSHostingView(rootView: view)
            contentView = host
            self.host = host
        }
        onShow?(i)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next >= DisplayPattern.allCases.count { finish() }
        else if next >= 0 { showPattern(next) }
    }

    private func finish() {
        NSCursor.unhide()
        orderOut(nil)
        Self.current = nil
        NSApp.windows.first { $0.identifier?.rawValue.contains(HardwareCheckView.windowID) == true }?
            .makeKeyAndOrderFront(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: finish() // esc
        case 123: step(-1) // ←
        default: step(1)
        }
    }

    override func mouseDown(with event: NSEvent) { step(1) }
    override func rightMouseDown(with event: NSEvent) { step(-1) }
}

@available(macOS 14.0, *)
private struct PatternView: View {
    let pattern: DisplayPattern
    let hint: Bool
    @State private var hintVisible = true

    var body: some View {
        Rectangle()
            .fill(pattern.swatch)
            .ignoresSafeArea()
            .overlay {
                if hint && hintVisible {
                    Text("Click or → next colour · ← back · esc ends")
                        .font(.title3)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .task(id: pattern) {
                guard hint else { return }
                try? await Task.sleep(for: .seconds(3))
                hintVisible = false
            }
    }
}

import AppKit
import SwiftUI

/// A menu key equivalent cannot distinguish a tap from holding C while
/// clicking. Monitor only this editor's window, leaving text input alone.
struct PartOrderKeyMonitor: NSViewRepresentable {
    var enabled: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) {
        view.onPress = onPress
        view.onRelease = onRelease
        view.onCancel = onCancel
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var enabled = false {
            didSet { if !enabled { cancel() } }
        }
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var pressed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(lostFocus),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            cancel()
        }

        @objc private func lostFocus() { cancel() }

        private func cancel() {
            guard pressed else { return }
            pressed = false
            onCancel?()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard enabled, let window, window.isKeyWindow, event.window === window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if !modifiers.isEmpty || window.firstResponder is NSTextView || window.attachedSheet != nil {
                cancel()
                return event
            }
            guard event.type == .keyDown || event.type == .keyUp else { return event }
            // Physical C also works with the Russian keyboard layout.
            guard event.keyCode == 8 || ["c", "с"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
            else { return event }
            if event.type == .keyDown {
                if !pressed {
                    pressed = true
                    onPress?()
                }
                return nil
            }
            if event.type == .keyUp, pressed {
                pressed = false
                onRelease?()
                return nil
            }
            return event
        }
    }
}

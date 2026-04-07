import AppKit
import SwiftUI

// MARK: - Floating tooltip window

/// A borderless floating NSPanel that renders above all app content.
/// Positioned near the mouse cursor when shown.
final class TooltipWindowController {
    static let shared = TooltipWindowController()

    private let panel: NSPanel
    private let hostingView: NSHostingView<TooltipWindowContent>

    private init() {
        let hosting = NSHostingView(rootView: TooltipWindowContent(text: ""))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hostingView = hosting

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.contentView = hosting
        panel = p
    }

    func show(text: String) {
        hostingView.rootView = TooltipWindowContent(text: text)
        hostingView.layout()

        let size = hostingView.fittingSize
        let mouse = NSEvent.mouseLocation

        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(
            x: mouse.x - size.width / 2,
            y: mouse.y + 14
        ))
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct TooltipWindowContent: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .padding(6) // keep shadow from clipping
            .fixedSize()
    }
}

// MARK: - View modifier

struct QuickTooltipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    TooltipWindowController.shared.show(text: text)
                } else {
                    TooltipWindowController.shared.hide()
                }
            }
    }
}

extension View {
    func quickTooltip(_ text: String) -> some View {
        modifier(QuickTooltipModifier(text: text))
    }
}

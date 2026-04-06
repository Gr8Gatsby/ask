import SwiftUI

struct NotificationBellButton: View {
    @Environment(ActionInboxStore.self) private var inbox

    @State private var scale: CGFloat = 1.0
    @State private var rotation: Double = 0.0
    @State private var animationTask: Task<Void, Never>? = nil

    var body: some View {
        if inbox.hasItems {
            Menu {
                ForEach(inbox.groups) { group in
                    Button {
                        NotificationCenter.default.post(
                            name: .askNavigateToScript,
                            object: nil,
                            userInfo: ["scriptID": group.scriptID]
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.scriptName)
                                Text(group.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if group.count > 1 {
                                    Text("\(group.count) actions")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        } icon: {
                            ScriptIconView(
                                svgString: nil,
                                iconData: group.scriptIconData,
                                sfSymbol: group.scriptIcon ?? "bell"
                            )
                            .frame(width: 18, height: 18)
                        }
                    }
                }
            } label: {
                Image(systemName: "bell.fill")
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(rotation))
            }
            .accessibilityLabel("Notifications")
            .buttonStyle(.plain)
            .onChange(of: inbox.groups.count) { old, new in
                if new > old { triggerAnimation() }
            }
            .onAppear { triggerAnimation() }
        }
    }

    private func triggerAnimation() {
        animationTask?.cancel()
        animationTask = Task {
            guard !Task.isCancelled else { return }
            // Swing 1 — biggest
            withAnimation(.easeInOut(duration: 0.6)) { rotation = -9; scale = 1.13 }
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { rotation = 7; scale = 1.06 }
            try? await Task.sleep(for: .seconds(0.6))
            // Swing 2 — settling
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.55)) { rotation = -4; scale = 1.03 }
            try? await Task.sleep(for: .seconds(0.55))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.55)) { rotation = 2; scale = 1.0 }
            try? await Task.sleep(for: .seconds(0.55))
            // Return to rest
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { rotation = 0 }
        }
    }
}

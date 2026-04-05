import SwiftUI

struct NotificationBellButton: View {
    @Environment(ActionInboxStore.self) private var inbox

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
                Image(systemName: "bell")
            }
            .accessibilityLabel("Notifications")
            .buttonStyle(.plain)
        }
    }
}

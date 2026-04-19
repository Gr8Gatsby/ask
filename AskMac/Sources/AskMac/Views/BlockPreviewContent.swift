import SwiftUI

// MARK: - List

struct ListPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var selectedID: String? = nil

    private var items: [(id: String, label: String, subtitle: String?)] {
        guard let raw = payload["items"] as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let id = d["id"] as? String, let label = d["label"] as? String else { return nil }
            return (id, label, d["subtitle"] as? String)
        }
    }

    private var actions: [String] { payload["actions"] as? [String] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
                Divider()
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                Button {
                    selectedID = item.id
                    onRespond?(item.id)
                } label: {
                    HStack {
                        let isSelected = selectedID == item.id
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                                .font(.caption)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                .lineLimit(2)
                            if let sub = item.subtitle {
                                Text(sub).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(selectedID == item.id ? Color.accentColor.opacity(0.07) : Color.clear)
                }
                .buttonStyle(.plain)
                .disabled(onRespond == nil)
                if idx < items.count - 1 {
                    Divider().padding(.leading, 8)
                }
            }
            if !actions.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button(action) { onRespond?(action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(onRespond == nil)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Detail

struct DetailPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var responded: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
                Divider()
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let actions = payload["actions"] as? [String], !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            responded = action
                            onRespond?(action)
                        } label: {
                            Text(action)
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(
                                    responded == action
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.accentColor.opacity(0.1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .disabled(onRespond == nil)
                    }
                    Spacer()
                }
            }
        }
        .blockCard()
    }
}

// MARK: - Icon Card

struct IconCardPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(spacing: 10) {
            if let iconName = payload["icon"] as? String {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = payload["title"] as? String, !title.isEmpty {
                    Text(title).font(.subheadline).fontWeight(.medium)
                }
                if let subtitle = payload["subtitle"] as? String, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .blockCard()
    }
}

// MARK: - Feed Item

struct FeedItemPreview: View {
    let payload: [String: Any]

    private var itemColor: Color {
        switch payload["color"] as? String {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "blue":   return .blue
        default:       return .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = payload["icon"] as? String {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(itemColor)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = payload["title"] as? String, !title.isEmpty {
                    Text(title).font(.caption).fontWeight(.medium)
                }
                if let body = payload["body"] as? String, !body.isEmpty {
                    Text(body).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                }
                if let ts = payload["timestamp"] as? String,
                   let date = ISO8601DateFormatter().date(from: ts) {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .blockCard()
    }
}

// MARK: - Claude Message

struct ClaudeMessagePreview: View {
    let payload: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClaudeBrandHeader()
            Divider()
            if let text = payload["text"] as? String, !text.isEmpty {
                markdownText(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .blockCard()
    }
}

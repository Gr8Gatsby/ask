import SwiftUI

/// Mac-side rendering of a single LiveBlock.
/// Confirmation and prompt blocks are interactive when `onRespond` is provided.
struct BlockPreviewView: View {
    let block: LiveBlock
    var onRespond: ((String) -> Void)? = nil

    private var payload: [String: Any] {
        guard let data = block.payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    var body: some View {
        Group {
            switch block.blockType {
            case "confirmation": ConfirmationPreview(payload: payload, onRespond: onRespond)
            case "status":       StatusPreview(payload: payload)
            case "info_card":    InfoCardPreview(payload: payload)
            case "alert":        AlertPreview(payload: payload)
            case "prompt", "chat_prompt": PromptPreview(payload: payload, onRespond: onRespond)
            case "countdown":    CountdownPreview(payload: payload)
            case "list":         ListPreview(payload: payload, onRespond: onRespond)
            case "detail":       DetailPreview(payload: payload, onRespond: onRespond)
            case "picker":       PickerPreview(payload: payload, onRespond: onRespond)
            case "icon_card":    IconCardPreview(payload: payload)
            case "claude_message": ClaudeMessagePreview(payload: payload)
            case "claude_session": ClaudeSessionPreview(payload: payload)
            case "tile":         EmptyView() // drives home-screen tile only
            default:             EmptyView()
            }
        }
    }
}

// MARK: - Confirmation

private struct ConfirmationPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let options = payload["options"] as? [String], !options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { opt in
                        if let respond = onRespond {
                            Button(opt) { respond(opt) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Text(opt)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Status

private struct StatusPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(spacing: 6) {
            if let icon = payload["icon"] as? String {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String {
                    Text(label).font(.caption).foregroundStyle(statusColor)
                }
                if let detail = payload["detail"] as? String {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var statusColor: Color {
        switch payload["color"] as? String {
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        case "yellow": return .yellow
        default:       return .blue
        }
    }
}

// MARK: - Info Card

private struct InfoCardPreview: View {
    let payload: [String: Any]

    private var pairs: [(key: String, value: String)] {
        guard let raw = payload["pairs"] as? [[String: String]] else { return [] }
        return raw.compactMap { dict in
            guard let k = dict["key"], let v = dict["value"] else { return nil }
            return (k, v)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            ForEach(pairs, id: \.key) { pair in
                HStack(alignment: .top) {
                    Text(pair.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(pair.value)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Alert

private struct AlertPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: (payload["icon"] as? String) ?? "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                if let title = payload["title"] as? String, !title.isEmpty {
                    Text(title).font(.caption).fontWeight(.medium)
                }
                if let body = payload["body"] as? String, !body.isEmpty {
                    Text(body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Countdown

private struct CountdownPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String, let time = payload["time"] as? String {
                    Text("\(label) in …").font(.caption)
                    Text(time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Prompt / Chat Prompt

private struct PromptPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if let context = payload["context"] as? String, !context.isEmpty {
                Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let respond = onRespond {
                HStack(spacing: 6) {
                    TextField(
                        (payload["placeholder"] as? String) ?? "Type a response…",
                        text: $text
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    Button("Send") {
                        guard !text.isEmpty else { return }
                        respond(text)
                        text = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(text.isEmpty)
                }
            } else {
                Text((payload["placeholder"] as? String) ?? "Type a response…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - List

private struct ListPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    private var items: [(id: String, label: String, subtitle: String?)] {
        guard let raw = payload["items"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict in
            guard let id = dict["id"] as? String, let label = dict["label"] as? String else { return nil }
            return (id, label, dict["subtitle"] as? String)
        }
    }

    private var actions: [String] {
        payload["actions"] as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.caption).fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 5)
            }
            ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { idx, item in
                Button {
                    onRespond?(item.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.caption).lineLimit(2)
                                .foregroundStyle(.primary)
                            if let sub = item.subtitle {
                                Text(sub).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onRespond == nil)
                if idx < min(items.count, 5) - 1 {
                    Divider().padding(.leading, 8)
                }
            }
            if items.count > 5 {
                Text("+ \(items.count - 5) more")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            if !actions.isEmpty {
                if !items.isEmpty { Divider() }
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

private struct DetailPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(5)
            }
            if let actions = payload["actions"] as? [String], !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions, id: \.self) { action in
                        Button {
                            onRespond?(action)
                        } label: {
                            Text(action)
                                .font(.caption2)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .disabled(onRespond == nil)
                    }
                    Spacer()
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Picker

private struct PickerPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var selected: String = ""
    @State private var responded = false

    private var options: [String] {
        payload["options"] as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selected)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Picker("", selection: $selected) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(onRespond == nil)
                    Spacer()
                    if let respond = onRespond {
                        Button("Select") {
                            guard !selected.isEmpty else { return }
                            respond(selected)
                            responded = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onAppear {
            if selected.isEmpty {
                selected = (payload["selected"] as? String) ?? options.first ?? ""
            }
        }
    }
}

// MARK: - Icon Card

private struct IconCardPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
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
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - ClaudeSession

private struct ClaudeSessionPreview: View {
    let payload: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(payload["project"] as? String ?? "Claude Code")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            if let msg = payload["last_message"] as? String, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            } else {
                Text("Waiting for Claude…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Text(payload["placeholder"] as? String ?? "Reply to Claude…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .italic()
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - ClaudeMessage

private struct ClaudeMessagePreview: View {
    let payload: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude Code")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if let text = payload["text"] as? String, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

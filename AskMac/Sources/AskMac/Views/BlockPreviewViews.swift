import SwiftUI

// MARK: - Block preview dispatcher

/// Mac-side rendering of a single LiveBlock.
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
            case "confirmation":  ConfirmationPreview(payload: payload, onRespond: onRespond)
            case "status":        StatusPreview(payload: payload)
            case "info_card":     InfoCardPreview(payload: payload)
            case "alert":         AlertPreview(payload: payload)
            case "prompt":        PromptPreview(payload: payload, onRespond: onRespond)
            case "chat_prompt":   ChatPromptPreview(payload: payload, onRespond: onRespond)
            case "countdown":     CountdownPreview(payload: payload)
            case "list":          ListPreview(payload: payload, onRespond: onRespond)
            case "detail":        DetailPreview(payload: payload, onRespond: onRespond)
            case "picker":        PickerPreview(payload: payload, onRespond: onRespond)
            case "icon_card":     IconCardPreview(payload: payload)
            case "claude_message": ClaudeMessagePreview(payload: payload)
            case "agent_session": AgentSessionPreview(payload: payload, onRespond: onRespond)
            case "start_session": StartSessionPreview(payload: payload, onRespond: onRespond)
            case "feed_item":     FeedItemPreview(payload: payload)
            case "diagnostics":   DiagnosticsPreview(payload: payload, onRespond: onRespond)
            case "tile":          EmptyView() // drives home-screen tile only
            default:              EmptyView()
            }
        }
    }
}

// MARK: - Shared helpers

/// Parse a hex string like "#CA7C5E" or "CA7C5E" into a Color.
private func hexColor(_ hex: String?) -> Color? {
    guard let hex else { return nil }
    let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
    guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
    return Color(
        red:   Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8)  & 0xFF) / 255,
        blue:  Double(value         & 0xFF) / 255
    )
}

/// Render markdown inline formatting via AttributedString (bold, italic, code, links).
private func markdownText(_ string: String) -> Text {
    if let attr = try? AttributedString(markdown: string) {
        return Text(attr)
    }
    return Text(string)
}

/// Status color from the "color" payload field.
private func statusColor(_ payload: [String: Any]) -> Color {
    switch payload["color"] as? String {
    case "green":  return .green
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "blue":   return .blue
    default:       return .secondary
    }
}

/// Claude Code branding header — small dot + "Claude Code" label.
private struct ClaudeBrandHeader: View {
    var label: String = "Claude Code"
    var color: Color = Color(red: 0.79, green: 0.49, blue: 0.37)

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(
                    Text("C")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                )
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Card container modifier

private extension View {
    func blockCard(background: Color = Color.secondary.opacity(0.07)) -> some View {
        self
            .padding(8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Confirmation

private struct ConfirmationPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var responded: String? = nil

    private var options: [String] {
        payload["options"] as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let r = responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            } else if options.count <= 2 {
                // Horizontal buttons — first option is accent-colored
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Button(opt) {
                            responded = opt
                            onRespond?(opt)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(idx == 0 ? .accentColor : Color(.tertiaryLabelColor))
                        .disabled(onRespond == nil)
                        .accessibilityIdentifier("confirm-option-\(opt)")
                    }
                    Spacer()
                }
            } else {
                // Radio list for 3+ options
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Button {
                            responded = opt
                            onRespond?(opt)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(opt).font(.caption).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onRespond == nil)
                        .accessibilityIdentifier("confirm-option-\(opt)")
                        if idx < options.count - 1 {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .blockCard()
    }
}

// MARK: - Status

private struct StatusPreview: View {
    let payload: [String: Any]

    var body: some View {
        let color = statusColor(payload)
        HStack(spacing: 8) {
            if let icon = payload["icon"] as? String {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String {
                    Text(label).font(.caption).foregroundStyle(color)
                }
                if let detail = payload["detail"] as? String {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Alert

private struct AlertPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: (payload["icon"] as? String) ?? "bell.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                if let title = payload["title"] as? String, !title.isEmpty {
                    Text(title).font(.caption).fontWeight(.medium)
                        .accessibilityIdentifier("alert-title")
                }
                if let body = payload["body"] as? String, !body.isEmpty {
                    Text(body).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                        .accessibilityIdentifier("alert-body")
                }
            }
            Spacer()
        }
        .blockCard(background: Color.orange.opacity(0.08))
    }
}

// MARK: - Info Card

private struct InfoCardPreview: View {
    let payload: [String: Any]

    private var pairs: [(key: String, value: String)] {
        guard let raw = payload["pairs"] as? [[String: String]] else { return [] }
        return raw.compactMap { d in
            guard let k = d["key"], let v = d["value"] else { return nil }
            return (k, v)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
                Divider()
            }
            ForEach(pairs, id: \.key) { pair in
                HStack(alignment: .top) {
                    Text(pair.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(pair.value)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .blockCard()
    }
}

// MARK: - Countdown

private struct CountdownPreview: View {
    let payload: [String: Any]

    private var targetDate: Date? {
        guard let str = payload["time"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String {
                    Text(label).font(.caption).fontWeight(.medium)
                }
                if let date = targetDate {
                    if date > Date() {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Overdue")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .blockCard()
    }
}

// MARK: - Prompt

private struct PromptPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var text = ""
    @State private var responded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            } else if let respond = onRespond {
                let isMultiline = payload["multiline"] as? Bool ?? false
                if isMultiline {
                    TextEditor(text: $text)
                        .font(.caption)
                        .frame(minHeight: 60, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    TextField(
                        (payload["placeholder"] as? String) ?? "Type a response…",
                        text: $text
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                HStack {
                    Spacer()
                    Button {
                        guard !text.isEmpty else { return }
                        respond(text)
                        responded = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            } else {
                Text((payload["placeholder"] as? String) ?? "Type a response…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .blockCard()
    }
}

// MARK: - Chat Prompt

private struct ChatPromptPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var text = ""
    @State private var responded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Agent context bubble
            if let context = payload["context"] as? String, !context.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ClaudeBrandHeader()
                    markdownText(context)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            } else if let respond = onRespond {
                HStack(spacing: 6) {
                    TextField(
                        (payload["placeholder"] as? String) ?? "Reply to Claude…",
                        text: $text
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        guard !text.isEmpty else { return }
                        respond(text); responded = true
                    }
                    Button {
                        guard !text.isEmpty else { return }
                        respond(text); responded = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            } else {
                Text((payload["placeholder"] as? String) ?? "Reply to Claude…")
                    .font(.caption2).foregroundStyle(.tertiary).italic()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .blockCard()
    }
}

// MARK: - Claude Message

private struct ClaudeMessagePreview: View {
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

// MARK: - Agent Session

private struct AgentSessionPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var replyText = ""
    @State private var respondedText: String? = nil
    @State private var confirmationResponse: String? = nil

    private var agentName: String { payload["agent_name"] as? String ?? "Agent" }
    private var isWorking: Bool   { payload["is_working"] as? Bool ?? false }
    private var lastMessage: String? { payload["last_message"] as? String }
    private var placeholder: String { payload["placeholder"] as? String ?? "Reply to \(agentName)…" }
    private var project: String?  { payload["project"] as? String }
    private var currentPreview: String? { payload["current_preview"] as? String ?? payload["preview"] as? String }
    private var statusText: String? { payload["status_text"] as? String }

    private var pendingConfirmation: (title: String, options: [String])? {
        guard let pending = payload["pending_confirmation"] as? [String: Any],
              let title = pending["title"] as? String
        else { return nil }
        let options = pending["options"] as? [String] ?? []
        return (title, options)
    }

    private var brandColor: Color {
        hexColor(payload["brand_color"] as? String) ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Agent + project header
            HStack(spacing: 6) {
                ClaudeBrandHeader(label: agentName, color: brandColor)
                if let proj = project, !proj.isEmpty {
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                    Text(proj)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.mini).tint(brandColor)
                }
            }

            // Message / working state
            Group {
                if let pending = pendingConfirmation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pending.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let preview = currentPreview, !preview.isEmpty {
                            markdownText(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        } else if let status = statusText, !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if isWorking, let msg = lastMessage, !msg.isEmpty {
                    markdownText(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .lineLimit(4)
                } else if isWorking {
                    HStack(spacing: 4) {
                        Text(statusText ?? "Working…").font(.caption).foregroundStyle(.secondary).italic()
                    }
                } else if let msg = lastMessage, !msg.isEmpty {
                    markdownText(msg)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                } else if let preview = currentPreview, !preview.isEmpty {
                    markdownText(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                } else {
                    Text("Waiting for input…")
                        .font(.caption).foregroundStyle(.secondary).italic()
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let pending = pendingConfirmation, let respond = onRespond {
                VStack(alignment: .leading, spacing: 8) {
                    if let confirmationResponse {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(confirmationResponse)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 8) {
                            ForEach(pending.options, id: \.self) { option in
                                Button(option) {
                                    confirmationResponse = option
                                    respond(option)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(option.lowercased().contains("deny") ? .red : brandColor)
                                .controlSize(.small)
                                .accessibilityIdentifier("agent-session-option-\(option)")
                            }
                        }
                    }
                }
            }

            // Reply row
            if let respondedText {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(respondedText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let respond = onRespond {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $replyText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .accessibilityIdentifier("agent-session-reply")
                        .onSubmit {
                            guard !replyText.isEmpty else { return }
                            let value = replyText
                            respond(value)
                            respondedText = value
                        }
                    Button {
                        guard !replyText.isEmpty else { return }
                        let value = replyText
                        respond(value)
                        respondedText = value
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(replyText.isEmpty ? Color.secondary : brandColor)
                    }
                    .accessibilityIdentifier("agent-session-send")
                    .buttonStyle(.plain)
                    .disabled(replyText.isEmpty)
                }
            } else {
                Text(placeholder)
                    .font(.caption2).foregroundStyle(.tertiary).italic()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .blockCard()
    }
}

// MARK: - Repo row (extracted to help the type checker)

private struct RepoRowView: View {
    let name: String
    let path: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Start Session

private struct StartSessionPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var expanded = false

    private var repos: [(name: String, path: String, value: String)] {
        guard let raw = payload["repos"] as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let n = d["name"] as? String, let p = d["path"] as? String else { return nil }
            return (n, p, (d["value"] as? String) ?? p)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header button
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                    Text("Start Session")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Spacer()
                    if !repos.isEmpty {
                        Text("\(repos.count) repo\(repos.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)

            if expanded && !repos.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(repos.enumerated()), id: \.offset) { idx, repo in
                        RepoRowView(name: repo.name, path: repo.path) {
                            onRespond?(repo.value)
                            expanded = false
                        }
                        .disabled(onRespond == nil)
                        if idx < repos.count - 1 {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - List

private struct ListPreview: View {
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

private struct DetailPreview: View {
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

// MARK: - Picker

private struct PickerPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var selected: String = ""
    @State private var responded = false

    private var options: [String] { payload["options"] as? [String] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(selected).font(.caption).foregroundStyle(.secondary)
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
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .blockCard()
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

private struct FeedItemPreview: View {
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

// MARK: - Diagnostics

private struct DiagnosticsPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)? = nil

    @State private var collectingLogs = false

    private var version: String { payload["version"] as? String ?? "?" }
    private var hooksOk: Bool { payload["hooks_ok"] as? Bool ?? false }
    private var socketOk: Bool { payload["socket_ok"] as? Bool ?? false }
    private var logLines: [String] { payload["log_lines"] as? [String] ?? [] }
    private var hooks: [[String: Any]] { payload["hooks"] as? [[String: Any]] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                ClaudeBrandHeader(label: "Diagnostics")
                Spacer()
                Text("v\(version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)
            }

            Divider()

            // Status row
            HStack(spacing: 16) {
                statusIndicator(ok: hooksOk, label: "Hooks")
                statusIndicator(ok: socketOk, label: "Socket")
                Spacer()
            }

            // Hooks detail
            if !hooks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(hooks.enumerated()), id: \.offset) { _, hook in
                        let event = hook["event"] as? String ?? ""
                        let path = hook["path"] as? String ?? ""
                        let ok = hook["ok"] as? Bool ?? false
                        HStack(spacing: 6) {
                            Circle()
                                .fill(ok ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(event)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            // Recent log lines
            if !logLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Logs")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                    .padding(6)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    onRespond?("refresh")
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    collectingLogs = true
                    onRespond?("collect_logs")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        collectingLogs = false
                    }
                } label: {
                    if collectingLogs {
                        Label("Collecting…", systemImage: "archivebox")
                            .font(.caption)
                    } else {
                        Label("Collect Logs", systemImage: "archivebox")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(collectingLogs)
            }
        }
        .blockCard()
    }

    private func statusIndicator(ok: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

import SwiftUI

// MARK: - Agent Session

struct AgentSessionPreview: View {
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

            // Last assistant message — shown above the status indicator
            if let msg = lastMessage, !msg.isEmpty {
                markdownText(msg)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            // Status indicator
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
                } else if isWorking {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini).tint(brandColor)
                        if let tool = payload["current_tool"] as? String, !tool.isEmpty {
                            Text(tool)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(statusText ?? "Working…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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

struct RepoRowView: View {
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

struct StartSessionPreview: View {
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

// MARK: - Diagnostics

struct DiagnosticsPreview: View {
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

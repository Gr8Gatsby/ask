import SwiftUI

// MARK: - Block dispatcher

struct BlockView: View {
    let block: RKBlock
    let onRespond: (String) async -> Void

    var body: some View {
        switch block.blockType {
        case .confirmation:
            if let p = block.confirmationPayload {
                ConfirmationBlockView(payload: p, onRespond: onRespond)
            }
        case .alert:
            if let p = block.alertPayload {
                AlertBlockView(payload: p)
            }
        case .status:
            if let p = block.statusPayload {
                StatusBlockView(payload: p)
            }
        case .prompt:
            if let p = block.promptPayload {
                PromptBlockView(payload: p, onRespond: onRespond)
            }
        case .infoCard:
            if let p = block.infoCardPayload {
                InfoCardBlockView(payload: p)
            }
        case .chatPrompt:
            if let p = block.chatPromptPayload {
                ChatPromptBlockView(payload: p, onRespond: onRespond)
            }
        }
    }
}

// MARK: - Confirmation

struct ConfirmationBlockView: View {
    let payload: RKConfirmationPayload
    let onRespond: (String) async -> Void

    @State private var responding = false
    @State private var selectedOption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if !payload.body.isEmpty {
                    Text(payload.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                }
            }
            if payload.options.count <= 2 {
                HStack(spacing: 8) {
                    ForEach(payload.options, id: \.self) { option in
                        optionButton(option)
                    }
                }
            } else {
                optionList
            }
        }
        .padding(.vertical, 4)
        .overlay {
            if responding {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func optionButton(_ option: String) -> some View {
        Button {
            Task {
                responding = true
                await onRespond(option)
                responding = false
            }
        } label: {
            Text(option)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(responding)
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(payload.options.enumerated()), id: \.element) { idx, option in
                Button {
                    selectedOption = option
                    Task {
                        responding = true
                        await onRespond(option)
                        responding = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .stroke(selectedOption == option ? Color.accentColor : Color.secondary.opacity(0.4),
                                        lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                            if selectedOption == option {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 11, height: 11)
                            }
                        }
                        Text(option)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(selectedOption == option
                        ? Color.accentColor.opacity(0.08)
                        : Color(.secondarySystemGroupedBackground))
                }
                .buttonStyle(.plain)
                .disabled(responding)

                if idx < payload.options.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Alert

struct AlertBlockView: View {
    let payload: RKAlertPayload

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: payload.icon ?? "bell.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if !payload.body.isEmpty {
                    Text(payload.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status

struct StatusBlockView: View {
    let payload: RKStatusPayload

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.label)
                    .font(.subheadline)
                if let detail = payload.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let icon = payload.icon {
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch payload.color {
        case "green": .green
        case "blue": .blue
        case "orange": .orange
        case "red": .red
        case "yellow": .yellow
        default: .secondary
        }
    }
}

// MARK: - Prompt

struct PromptBlockView: View {
    let payload: RKPromptPayload
    let onRespond: (String) async -> Void

    @State private var text = ""
    @State private var responding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(payload.title)
                .font(.subheadline)
                .fontWeight(.medium)
            HStack(spacing: 8) {
                if payload.multiline == true {
                    TextField(payload.placeholder ?? "Enter response…", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(responding)
                } else {
                    TextField(payload.placeholder ?? "Enter response…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .disabled(responding)
                }
                Button {
                    let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !answer.isEmpty else { return }
                    Task {
                        responding = true
                        await onRespond(answer)
                        responding = false
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary : Color.accentColor
                        )
                }
                .disabled(responding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ChatPrompt

struct ChatPromptBlockView: View {
    let payload: RKChatPromptPayload
    let onRespond: (String) async -> Void

    @State private var text = ""
    @State private var responding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Claude's last message shown as context
            if let context = payload.context, !context.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text("Claude Code")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                    Text(context)
                        .font(.subheadline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            // Input area
            VStack(alignment: .leading, spacing: 6) {
                Text(payload.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(payload.placeholder ?? "Reply to Claude…", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...6)
                        .disabled(responding)

                    Button {
                        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !answer.isEmpty else { return }
                        Task {
                            responding = true
                            await onRespond(answer)
                            responding = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(
                                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary : Color.accentColor
                            )
                    }
                    .disabled(responding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
        .overlay {
            if responding {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - InfoCard

struct InfoCardBlockView: View {
    let payload: RKInfoCardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(payload.title)
                .font(.subheadline)
                .fontWeight(.medium)
            ForEach(payload.pairs, id: \.key) { pair in
                HStack {
                    Text(pair.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pair.value)
                        .font(.caption)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

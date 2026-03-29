import SwiftUI
import UIKit
import CoreText

// MARK: - Emoji-safe text

/// UITextView-backed text view with an explicit CoreText emoji cascade.
///
/// iOS 26 beta broke the automatic Apple Color Emoji fallback in the San Francisco
/// font cascade for both UILabel and UITextView. The fix: build a UIFontDescriptor
/// that explicitly lists Apple Color Emoji as the first cascade font via
/// kCTFontCascadeListAttribute. CoreText then finds emoji glyphs correctly.
private struct EmojiText: UIViewRepresentable {
    let text: String
    var uiFont: UIFont = .preferredFont(forTextStyle: .body)
    var color: UIColor = .label
    var alignment: NSTextAlignment = .left
    var numberOfLines: Int = 0

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = false  // let SwiftUI gesture recognizers through
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if numberOfLines > 0 {
            tv.textContainer.maximumNumberOfLines = numberOfLines
            tv.textContainer.lineBreakMode = .byTruncatingTail
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = NSAttributedString(string: text, attributes: [
            .font: fontWithEmojiCascade,
            .foregroundColor: color,
        ])
        uiView.textAlignment = alignment
    }

    /// Returns `uiFont` with Apple Color Emoji injected as the first cascade font.
    /// Uses kCTFontCascadeListAttribute so CoreText resolves emoji glyphs directly,
    /// bypassing whatever broke the automatic cascade on iOS 26 beta.
    private var fontWithEmojiCascade: UIFont {
        let emojiDescriptor = UIFontDescriptor(name: "Apple Color Emoji", size: uiFont.pointSize)
        let descriptor = uiFont.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String): [emojiDescriptor]
        ])
        return UIFont(descriptor: descriptor, size: uiFont.pointSize)
    }
}

// MARK: - Block dispatcher

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

struct BlockView: View {
    let block: RKBlock
    let onRespond: (String) async -> Void

    @State private var showDebug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDebug.toggle() }
                } label: {
                    Image(systemName: showDebug ? "xmark.circle" : "info.circle")
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }

            if showDebug {
                debugView
            } else {
                blockContent
            }
        }
    }

    @ViewBuilder
    private var blockContent: some View {
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

    private var debugView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(block.blockType.rawValue)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(block.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ScrollView {
                Text(block.payloadJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        .padding(.vertical, 4)
        .padding(.trailing, 20)
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
                EmojiText(text: payload.title,
                          uiFont: .preferredFont(forTextStyle: .subheadline).withWeight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !payload.body.isEmpty {
                    EmojiText(text: payload.body,
                              uiFont: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                              color: .secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
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
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option
        return Button {
            guard !responding else { return }
            selectedOption = option
            Task {
                responding = true
                await onRespond(option)
                responding = false
            }
        } label: {
            ZStack {
                if responding && isSelected {
                    ProgressView().tint(Color.accentColor)
                } else {
                    EmojiText(text: option,
                              uiFont: .preferredFont(forTextStyle: .body).withWeight(.semibold),
                              color: UIColor(Color.accentColor),
                              alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 36)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(responding)
        .opacity(responding && !isSelected ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: responding)
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(payload.options.enumerated()), id: \.element) { idx, option in
                let isSelected = selectedOption == option
                Button {
                    guard !responding else { return }
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
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                        lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                            if responding && isSelected {
                                ProgressView().scaleEffect(0.55).tint(Color.accentColor)
                            } else if isSelected {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 11, height: 11)
                            }
                        }
                        EmojiText(text: option,
                                  uiFont: .preferredFont(forTextStyle: .body))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemGroupedBackground))
                }
                .buttonStyle(.plain)
                .disabled(responding)
                .opacity(responding && !isSelected ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.15), value: responding)

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
    @State private var sentMessage = ""

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

            // Sent message bubble — visible from submit until Claude replies with new context
            if !sentMessage.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack {
                        Spacer(minLength: 40)
                        Text(sentMessage)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    HStack(spacing: 4) {
                        Spacer()
                        if responding {
                            ProgressView().scaleEffect(0.6)
                            Text("Sending…")
                        } else {
                            Image(systemName: "checkmark")
                            Text("Sent to Claude")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity)
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
                        .onSubmit { submit() }

                    Button { submit() } label: {
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
        .onChange(of: payload.context) { _, _ in
            // Claude responded with new context — clear the sent bubble
            withAnimation { sentMessage = "" }
        }
    }

    private func submit() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !responding else { return }
        withAnimation { sentMessage = answer }
        text = ""
        Task {
            responding = true
            await onRespond(answer)
            responding = false
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

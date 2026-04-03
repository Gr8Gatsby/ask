import SwiftUI
import UIKit
import CoreText
import Combine

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

// MARK: - Design tokens

private enum BlockStyle {
    static let blockVerticalPadding: CGFloat = 2
    static let innerSpacing: CGFloat = 4
    static let buttonVerticalPadding: CGFloat = 4
    static let buttonMinHeight: CGFloat = 28
    static let listRowVerticalPadding: CGFloat = 6
    static let listRowHorizontalPadding: CGFloat = 10
    static let buttonCornerRadius: CGFloat = 6
    static let listCornerRadius: CGFloat = 8

    static let titleFont = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
    static let detailFont = UIFont.preferredFont(forTextStyle: .caption2)
    static let buttonFont = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
    static let listItemFont = UIFont.preferredFont(forTextStyle: .subheadline)
    static let listSubtitleFont = UIFont.preferredFont(forTextStyle: .caption2)
    static let monoFont: UIFont = {
        let size = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }()
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
    var isWaiting: Bool = false

    @AppStorage("showBlockDebugInfo") private var showDebugInfo: Bool = false
    @State private var showDebug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showDebugInfo {
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
            }

            if showDebugInfo && showDebug {
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
        case .claudeMessage:
            if let p = block.claudeMessagePayload {
                ClaudeMessageBlockView(payload: p)
            }
        case .agentSession:
            if let p = block.agentSessionPayload {
                AgentSessionBlockView(payload: p, onRespond: onRespond)
            }
        case .iconCard:
            if let p = block.iconCardPayload {
                IconCardBlockView(payload: p, iconData: block.scriptIconData, icon: block.scriptIcon)
            }
        case .picker:
            if let p = block.pickerPayload {
                PickerBlockView(payload: p, onRespond: onRespond)
            }
        case .tile:
            EmptyView() // tile blocks drive the home-screen tile; not rendered in detail view
        case .countdown:
            if let p = block.countdownPayload {
                CountdownBlockView(payload: p)
            }
        case .list:
            if let p = block.listPayload {
                ListBlockView(payload: p, isWaiting: isWaiting, onRespond: onRespond)
            }
        case .detail:
            EmptyView() // detail blocks are surfaced as navigation pushes in ScriptDetailView
        case .feedItem:
            EmptyView() // feed_item blocks are shown in FeedView, not in block detail
        case .startSession:
            if let p = block.startSessionPayload {
                StartSessionBlockView(payload: p, onRespond: onRespond)
            }
        case .activityFeed:
            if let p = block.activityFeedPayload {
                ActivityFeedBlockView(payload: p)
            }
        case .compactSummary:
            if let p = block.compactSummaryPayload {
                CompactSummaryBlockView(payload: p)
            }
        case .sessionEvent:
            if let p = block.sessionEventPayload {
                SessionEventBlockView(payload: p)
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
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                EmojiText(text: payload.title, uiFont: BlockStyle.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                if !payload.body.isEmpty {
                    EmojiText(text: payload.body, uiFont: BlockStyle.monoFont, color: .secondaryLabel)
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
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }

    private func optionButton(_ option: String) -> some View {
        let isSelected = selectedOption == option
        return Button {
            guard !responding else { return }
            selectedOption = option
            Task {
                responding = true
                await onRespond(option)
            }
        } label: {
            ZStack {
                if responding && isSelected {
                    ProgressView().tint(Color.accentColor)
                } else {
                    EmojiText(text: option, uiFont: BlockStyle.buttonFont,
                              color: UIColor(Color.accentColor), alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BlockStyle.buttonMinHeight)
            .padding(.vertical, BlockStyle.buttonVerticalPadding)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: BlockStyle.buttonCornerRadius))
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
                    }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                                        lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                            if responding && isSelected {
                                ProgressView().scaleEffect(0.5).tint(Color.accentColor)
                            } else if isSelected {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 9, height: 9)
                            }
                        }
                        EmojiText(text: option, uiFont: BlockStyle.listItemFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, BlockStyle.listRowHorizontalPadding)
                    .padding(.vertical, BlockStyle.listRowVerticalPadding)
                    .background(isSelected ? Color.accentColor.opacity(0.08) : Color(.secondarySystemGroupedBackground))
                }
                .buttonStyle(.plain)
                .disabled(responding)
                .opacity(responding && !isSelected ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.15), value: responding)

                if idx < payload.options.count - 1 {
                    Divider().padding(.leading, 36)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BlockStyle.listCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BlockStyle.listCornerRadius)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Alert

struct AlertBlockView: View {
    let payload: RKAlertPayload

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: payload.icon ?? "bell.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title)
                    .font(.footnote)
                    .fontWeight(.medium)
                if !payload.body.isEmpty {
                    Text(payload.body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }
}

// MARK: - Status

struct StatusBlockView: View {
    let payload: RKStatusPayload

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.label)
                    .font(.footnote)
                if let detail = payload.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let icon = payload.icon {
                Image(systemName: icon)
                    .foregroundStyle(statusColor)
                    .font(.caption2)
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
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
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
            Text(payload.title)
                .font(.footnote)
                .fontWeight(.medium)
            HStack(spacing: 8) {
                if payload.multiline == true {
                    TextField(payload.placeholder ?? "Enter response…", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
                        .lineLimit(1...4)
                        .disabled(responding)
                } else {
                    TextField(payload.placeholder ?? "Enter response…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.subheadline)
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
                        .font(.title3)
                        .foregroundStyle(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary : Color.accentColor
                        )
                }
                .disabled(responding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }
}

// MARK: - ChatPrompt

struct ChatPromptBlockView: View {
    let payload: RKChatPromptPayload
    var claudeMessage: String? = nil
    let onRespond: (String) async -> Void

    @State private var text = ""
    @State private var responding = false
    @State private var sentMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing + 2) {
            // Inline claude_message block — shown on top without redundant header
            if let msg = claudeMessage, !msg.isEmpty {
                ClaudeMarkdownView(text: msg)
                Divider()
            }
            // Claude's last message shown as context — rendered as markdown
            if let context = payload.context, !context.isEmpty {
                VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
                    HStack(spacing: 4) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                        Text("Claude Code")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                    ClaudeMarkdownView(text: context)
                        .padding(8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Sent message bubble — visible from submit until Claude replies with new context
            if !sentMessage.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack {
                        Spacer(minLength: 40)
                        Text(sentMessage)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    HStack(spacing: 4) {
                        Spacer()
                        if responding {
                            ProgressView().scaleEffect(0.5)
                            Text("Sending…")
                        } else {
                            Image(systemName: "checkmark")
                            Text("Sent")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }

            // Input area
            HStack(alignment: .bottom, spacing: 8) {
                TextField(payload.placeholder ?? "Reply to Claude…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .lineLimit(1...6)
                    .disabled(responding)
                    .onSubmit { submit() }

                Button { submit() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary : Color.accentColor
                        )
                }
                .disabled(responding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
        .onChange(of: payload.context) { _, _ in
            // Claude responded with new context — clear the sent bubble
            withAnimation(.default) { sentMessage = "" }
        }
    }

    private func submit() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !responding else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.default) { sentMessage = answer }
        text = ""
        Task {
            responding = true
            await onRespond(answer)
            responding = false
        }
    }
}

// MARK: - IconCard

struct IconCardBlockView: View {
    let payload: RKIconCardPayload
    let iconData: String?   // base64 PNG from Mac's SVG→PNG conversion
    let icon: String?       // SF Symbol fallback

    var body: some View {
        HStack(spacing: 10) {
            scriptIcon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title)
                    .font(.footnote)
                    .fontWeight(.medium)
                if let subtitle = payload.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }

    @ViewBuilder
    private var scriptIcon: some View {
        if let data = iconData,
           let imageData = Data(base64Encoded: data),
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: icon ?? "app.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Picker

struct PickerBlockView: View {
    let payload: RKPickerPayload
    let onRespond: (String) async -> Void

    @State private var selected: String
    @State private var responding = false

    init(payload: RKPickerPayload, onRespond: @escaping (String) async -> Void) {
        self.payload = payload
        self.onRespond = onRespond
        _selected = State(initialValue: payload.selected ?? payload.options.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
            Text(payload.title)
                .font(.footnote)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Picker(payload.title, selection: $selected) {
                    ForEach(payload.options, id: \.self) { option in
                        Text(option).font(.subheadline).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(responding)

                Spacer()

                Button {
                    guard !responding else { return }
                    responding = true
                    Task {
                        await onRespond(selected)
                    }
                } label: {
                    if responding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Select")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(responding || payload.options.isEmpty)
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }
}

// MARK: - List

struct ListBlockView: View {
    let payload: RKListPayload
    var isWaiting: Bool = false
    let onRespond: (String) async -> Void

    @State private var tappedID: String?
    @State private var tappedAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = payload.title, !title.isEmpty {
                EmojiText(text: title, uiFont: BlockStyle.titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BlockStyle.listRowHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }

            if payload.items.isEmpty && (payload.actions == nil || payload.actions!.isEmpty) {
                // Truly empty — nothing to show
            } else {
                ForEach(Array(payload.items.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        guard tappedID == nil && tappedAction == nil else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        tappedID = item.id
                        Task {
                            await onRespond(item.id)
                            // Keep spinner alive while burst-polling for the detail block.
                            // isWaiting going false (detail arrived or error) clears it via
                            // onChange below. This timeout is a safety fallback only.
                            try? await Task.sleep(for: .seconds(10))
                            tappedID = nil
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                EmojiText(text: item.label, uiFont: BlockStyle.listItemFont)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    EmojiText(text: subtitle, uiFont: BlockStyle.listSubtitleFont,
                                              color: .secondaryLabel)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if tappedID == item.id {
                                ProgressView().scaleEffect(0.6).tint(Color.accentColor)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(Color(.tertiaryLabel))
                            }
                        }
                        .padding(.vertical, BlockStyle.listRowVerticalPadding)
                        .padding(.horizontal, BlockStyle.listRowHorizontalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tappedID == item.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color(.secondarySystemGroupedBackground))
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: tappedID)
                    .disabled(tappedAction != nil)

                    if idx < payload.items.count - 1 {
                        Divider().padding(.leading, BlockStyle.listRowHorizontalPadding)
                    }
                }

                if let actions = payload.actions, !actions.isEmpty {
                    if !payload.items.isEmpty {
                        Divider()
                    }
                    VStack(spacing: BlockStyle.innerSpacing) {
                        ForEach(actions, id: \.self) { action in
                            Button {
                                guard tappedAction == nil && tappedID == nil else { return }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                tappedAction = action
                                Task {
                                    await onRespond(action)
                                    tappedAction = nil
                                }
                            } label: {
                                ZStack {
                                    if tappedAction == action {
                                        ProgressView().scaleEffect(0.6).tint(Color.accentColor)
                                    } else {
                                        EmojiText(text: action, uiFont: BlockStyle.buttonFont,
                                                  color: UIColor(Color.accentColor), alignment: .center)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: BlockStyle.buttonMinHeight)
                                .padding(.vertical, BlockStyle.buttonVerticalPadding)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: BlockStyle.buttonCornerRadius))
                            }
                            .buttonStyle(.plain)
                            .disabled(tappedAction != nil || tappedID != nil)
                            .opacity(tappedAction != nil && tappedAction != action ? 0.4 : 1)
                            .animation(.easeInOut(duration: 0.15), value: tappedAction)
                        }
                    }
                    .padding(.horizontal, BlockStyle.listRowHorizontalPadding)
                    .padding(.vertical, BlockStyle.listRowVerticalPadding)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BlockStyle.listCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: BlockStyle.listCornerRadius)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .padding(.vertical, BlockStyle.blockVerticalPadding)
        .onChange(of: isWaiting) { _, waiting in
            // Clear the in-row spinner as soon as burst polling ends —
            // either because the detail block arrived (nav pushed) or an error occurred.
            if !waiting { tappedID = nil }
        }
    }
}

// MARK: - Detail

struct DetailBlockView: View {
    let payload: RKDetailPayload
    let onRespond: (String) async -> Void

    @State private var responding = false
    @State private var selectedAction: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
            EmojiText(text: payload.title, uiFont: BlockStyle.titleFont)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(payload.body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 2)
            }
            .frame(maxHeight: 280)

            if let actions = payload.actions, !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions, id: \.self) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }

    private func actionButton(_ action: String) -> some View {
        let isSelected = selectedAction == action
        return Button {
            guard !responding else { return }
            selectedAction = action
            Task {
                responding = true
                await onRespond(action)
                responding = false
            }
        } label: {
            ZStack {
                if responding && isSelected {
                    ProgressView().tint(Color.accentColor)
                } else {
                    EmojiText(text: action, uiFont: BlockStyle.buttonFont,
                              color: UIColor(Color.accentColor), alignment: .center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: BlockStyle.buttonMinHeight)
            .padding(.vertical, BlockStyle.buttonVerticalPadding)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: BlockStyle.buttonCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(responding)
        .opacity(responding && !isSelected ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.15), value: responding)
    }
}

// MARK: - Countdown

struct CountdownBlockView: View {
    let payload: RKCountdownPayload

    @State private var displayText: String = ""
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption2)
            Text(displayText)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
        .onAppear { displayText = formatted() }
        .onReceive(timer) { _ in displayText = formatted() }
    }

    private func formatted() -> String {
        guard let target = ISO8601DateFormatter().date(from: payload.time) else {
            return payload.label
        }
        let seconds = target.timeIntervalSinceNow
        let relative: String
        if seconds <= 0 {
            return "\(payload.label) overdue"
        } else if seconds < 60 {
            relative = "less than a minute"
        } else if seconds < 5 * 60 {
            let mins = Int(seconds / 60)
            relative = "about \(mins) minute\(mins == 1 ? "" : "s")"
        } else if seconds < 60 * 60 {
            let mins = Int((seconds / 60).rounded())
            relative = "about \(mins) minutes"
        } else {
            let hours = Int((seconds / 3600).rounded())
            relative = "about \(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(payload.label) in \(relative)"
    }
}

// MARK: - InfoCard

struct InfoCardBlockView: View {
    let payload: RKInfoCardPayload

    var body: some View {
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing) {
            Text(payload.title)
                .font(.footnote)
                .fontWeight(.medium)
            ForEach(payload.pairs, id: \.key) { pair in
                HStack {
                    Text(pair.key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pair.value)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
    }
}

// MARK: - ClaudeMarkdownView

/// Renders a markdown string using a simple block parser.
/// Handles fenced code blocks and ATX headings natively; delegates inline
/// formatting (bold, italic, inline code, links) to AttributedString.
struct ClaudeMarkdownView: View {
    let text: String

    private enum Segment {
        case paragraph(String)
        case heading(level: Int, text: String)
        case codeBlock(lang: String, code: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .paragraph(let s):
                    paragraphView(s)
                case .heading(let level, let s):
                    headingView(level: level, text: s)
                case .codeBlock(_, let code):
                    codeBlockView(code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Segment views

    @ViewBuilder
    private func paragraphView(_ s: String) -> some View {
        if let attr = try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(s)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let font: Font = level == 1 ? .subheadline.bold() : level == 2 ? .footnote.bold() : .caption.bold()
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Parser

    private var segments: [Segment] {
        var result: [Segment] = []
        let lines = text.components(separatedBy: "\n")
        var paraLines: [String] = []
        var codeLines: [String] = []
        var codeLang = ""
        var inCode = false

        func flushParagraph() {
            let joined = paraLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paraLines = []
        }

        func flushCode() {
            let joined = codeLines.joined(separator: "\n")
            result.append(.codeBlock(lang: codeLang, code: joined))
            codeLines = []
            codeLang = ""
        }

        for line in lines {
            if inCode {
                if line.hasPrefix("```") {
                    flushCode()
                    inCode = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inCode = true
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(level: 3, text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                result.append(.heading(level: 2, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(level: 1, text: String(line.dropFirst(2))))
            } else {
                paraLines.append(line)
            }
        }

        // Flush any trailing content
        if inCode { flushCode() }
        flushParagraph()

        return result
    }
}

// MARK: - ClaudeMessage

struct ClaudeMessageBlockView: View {
    let payload: RKClaudeMessagePayload

    var body: some View {
        ClaudeMarkdownView(text: payload.text)
            .padding(.vertical, BlockStyle.blockVerticalPadding)
    }
}

// MARK: - AgentSession

struct AgentSessionBlockView: View {
    let payload: RKAgentSessionPayload
    let onRespond: (String) async -> Void

    @State private var text = ""
    @State private var responding = false
    @State private var sentMessage = ""
    @State private var isCollapsed = false
    @State private var showCloseConfirmation = false
    @State private var isClosing = false
    @State private var closeTimedOut = false
    /// Holds the last non-empty message we received. Never cleared when status
    /// transitions to "working" or "waiting" so the user retains context.
    @State private var lastSeenMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BlockStyle.innerSpacing + 2) {
            // Session header with collapse toggle
            HStack(alignment: .center, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
                } label: {
                    HStack(alignment: .center, spacing: 6) {
                        Text(payload.project)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isCollapsed, !lastSeenMessage.isEmpty {
                            Text(lastSeenMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else if isCollapsed, payload.isWorking == true {
                            if let tool = payload.currentTool {
                                HStack(spacing: 4) {
                                    Image(systemName: toolIcon(tool))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(toolActivityText(tool, payload.currentPreview))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text("\(payload.agentName ?? "Claude") is working…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    showCloseConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(isClosing ? .clear : .secondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
                .disabled(isClosing)
                .confirmationDialog(
                    "Close \(payload.agentName ?? "Session")?",
                    isPresented: $showCloseConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Close Session", role: .destructive) {
                        isClosing = true
                        closeTimedOut = false
                        Task {
                            await onRespond("__close_session__")
                            // 30-second timeout: if block hasn't been cleared, show error
                            try? await Task.sleep(for: .seconds(30))
                            if isClosing {
                                closeTimedOut = true
                                isClosing = false
                            }
                        }
                    }
                } message: {
                    Text("This will send Ctrl+C to the terminal and end the \(payload.project) session.")
                }
            }
            .padding(.bottom, isCollapsed ? 0 : -4)

            if !isCollapsed {
                // Status area
                Group {
                    if isClosing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Closing session…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if closeTimedOut {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Session may not have closed — check the terminal.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if !lastSeenMessage.isEmpty {
                        ClaudeMarkdownView(text: lastSeenMessage)
                    } else if payload.isWorking == true {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(payload.brandColorValue)
                            if let tool = payload.currentTool {
                                Image(systemName: toolIcon(tool))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(toolActivityText(tool, payload.currentPreview))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("\(payload.agentName ?? "Claude") is working…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        // No context yet — session waiting for first input
                        Text("Session started")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Tool history — collapsible activity card
                if let history = payload.toolHistory, !history.isEmpty {
                    ActivityHistoryCard(history: history, maxCollapsed: 5)
                        .padding(.top, 2)
                }

                // Sent message bubble
                if !sentMessage.isEmpty && !isClosing && !closeTimedOut {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack {
                            Spacer(minLength: 40)
                            Text(sentMessage)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        HStack(spacing: 4) {
                            Spacer()
                            if responding {
                                ProgressView().scaleEffect(0.5)
                                Text("Sending…")
                            } else {
                                Image(systemName: "checkmark")
                                Text("Sent")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                // Chat input — hidden while closing
                if !isClosing && !closeTimedOut {
                    HStack(alignment: .bottom, spacing: 8) {
                        let inputPlaceholder = payload.isWorking == true
                            ? "\(payload.agentName ?? "Claude") is working…"
                            : (payload.placeholder ?? "Reply to \(payload.agentName ?? "Claude")…")
                        TextField(inputPlaceholder, text: $text, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)
                            .lineLimit(1...6)
                            .disabled(responding)
                            .onSubmit { submit() }

                        Button { submit() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                                .foregroundStyle(
                                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color.secondary : Color.accentColor
                                )
                        }
                        .disabled(responding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(.vertical, BlockStyle.blockVerticalPadding)
        .onAppear {
            if let msg = payload.lastMessage, !msg.isEmpty {
                lastSeenMessage = msg
            }
        }
        .onChange(of: payload.lastMessage) { _, newMsg in
            if let msg = newMsg, !msg.isEmpty {
                lastSeenMessage = msg
            }
            withAnimation { sentMessage = "" }
        }
    }

    private func submit() {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !responding else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { sentMessage = answer }
        text = ""
        Task {
            responding = true
            await onRespond(answer)
            responding = false
        }
    }
}

// MARK: - StartSession

struct StartSessionBlockView: View {
    let payload: RKStartSessionPayload
    let onRespond: (String) async -> Void

    @State private var showPicker = false
    @State private var launching = false

    var body: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                Text("Start Session")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if launching {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.vertical, 4)
        .sheet(isPresented: $showPicker) {
            RepoPickerSheet(repos: payload.repos) { repo in
                showPicker = false
                launching = true
                Task {
                    await onRespond(repo.path)
                    try? await Task.sleep(for: .seconds(2))
                    launching = false
                }
            }
        }
    }
}

struct RepoPickerSheet: View {
    let repos: [RKRepo]
    let onSelect: (RKRepo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [RKRepo] {
        guard !search.isEmpty else { return repos }
        return repos.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { repo in
                Button {
                    onSelect(repo)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        Text(repo.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }
            }
            .searchable(text: $search, prompt: "Filter repos")
            .navigationTitle("Choose a Repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Relative time helper

func relativeTime(_ ts: Double) -> String {
    let date = Date(timeIntervalSince1970: ts)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - Activity History Card (reused in session card + chat)

struct ActivityHistoryCard: View {
    let history: [ToolHistoryEntry]
    var maxCollapsed: Int = 5

    @State private var isExpanded = false

    private var sorted: [ToolHistoryEntry] { history.sorted { $0.ts > $1.ts } }

    /// Total time span in seconds between oldest and newest entry.
    private var spanSeconds: Double {
        guard let first = history.map(\.ts).min(),
              let last  = history.map(\.ts).max() else { return 0 }
        return last - first
    }

    private var spanLabel: String {
        let secs = Int(spanSeconds)
        if secs < 60 { return secs == 0 ? "" : "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(history.count) action\(history.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !spanLabel.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(spanLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(sorted.prefix(maxCollapsed), id: \.ts) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: toolIcon(entry.tool))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .center)
                            Text(toolActivityText(entry.tool, entry.preview))
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(relativeTime(entry.ts))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ActivityFeed

struct ActivityFeedBlockView: View {
    let payload: RKActivityFeedPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(payload.project)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Activity")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            Divider()

            if payload.entries.isEmpty {
                Text("No activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(payload.entries.reversed().prefix(15), id: \.ts) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: toolIcon(entry.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .center)
                            Text(toolActivityText(entry.tool, entry.preview))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(relativeTime(entry.ts))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - CompactSummary

struct CompactSummaryBlockView: View {
    let payload: RKCompactSummaryPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Context Summary")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(payload.project)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(payload.trigger == "manual" ? "Manual" : "Auto")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            if !payload.summary.isEmpty {
                Divider()
                Text(payload.summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let ts = payload.ts {
                HStack {
                    Spacer()
                    Text(relativeTime(ts))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - SessionEvent

struct SessionEventBlockView: View {
    let payload: RKSessionEventPayload

    private var isStarted: Bool { payload.event == "started" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isStarted ? "play.circle.fill" : "stop.circle.fill")
                .font(.title2)
                .foregroundStyle(isStarted ? Color.green : Color.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(isStarted ? "Session started" : "Session ended")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(payload.project)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let ts = payload.ts {
                Text(relativeTime(ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }
}

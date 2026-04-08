import SwiftUI
import SwiftData
import CloudKit

// MARK: - Session Row (in ScriptDetailView session list)

struct SessionRowView: View {
    let payload: RKAgentSessionPayload
    let confirmationCount: Int

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(payload.isWorking == true ? Color.blue : Color(.systemGray4))
                        .frame(width: 8, height: 8)
                    Text(payload.project)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                Group {
                    if let msg = payload.lastMessage, !msg.isEmpty {
                        Text(msg.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? msg)
                            .foregroundStyle(.secondary)
                    } else if payload.isWorking == true {
                        if let tool = payload.currentTool {
                            HStack(spacing: 4) {
                                Image(systemName: toolIcon(tool))
                                    .foregroundStyle(.secondary)
                                Text(toolActivityText(tool, payload.currentPreview))
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("\(payload.agentName ?? "Agent") is working…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let tty = payload.tty, !tty.isEmpty {
                        Text(tty)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Session started")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                if payload.isHeadless == true {
                    Image(systemName: "rectangle.slash")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if confirmationCount > 0 || payload.pendingConfirmation != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Message send status

/// Ephemeral status of an outgoing user message — lives only in SessionChatView state.
enum MessageSendStatus {
    case sending    // CloudKit write in-flight
    case sent       // CloudKit write succeeded
    case delivered  // Mac daemon received and routed to script
    case failed     // CloudKit write threw
}

// MARK: - Session Chat View

struct SessionChatView: View {
    let sessionBlockID: String
    let allBlocks: [RKBlock]
    let scriptID: String
    let machineID: String
    let onRespond: (RKBlock, String) async -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Query private var entries: [ChatEntry]

    @State private var draft = ""
    @State private var isSending = false
    @State private var showStopConfirm = false
    /// Tracks per-entry send status for outgoing messages while this view is open.
    @State private var sendStatuses: [String: MessageSendStatus] = [:]
    /// Maps entryID → messageID for messages pending Mac delivery confirmation.
    @State private var pendingDelivery: [String: String] = [:]
    /// Timestamp of the most recent tool history entry we've already captured into the chat.
    @State private var lastCapturedActivityTs: Double = 0
    /// In-memory dedup for assistant messages — guards against race where SwiftData
    /// @Query hasn't updated yet when a second onChange fires.
    @State private var lastAppendedAssistantText: String = ""

    private let sessionId: String
    private let initialProject: String

    init(
        sessionBlockID: String,
        sessionID: String,
        project: String,
        livePayload: RKAgentSessionPayload?,
        allBlocks: [RKBlock],
        scriptID: String,
        machineID: String,
        onRespond: @escaping (RKBlock, String) async -> Void
    ) {
        self.sessionBlockID = sessionBlockID
        self.allBlocks = allBlocks
        self.scriptID = scriptID
        self.machineID = machineID
        self.onRespond = onRespond
        self.sessionId = sessionID
        self.initialProject = project
        _entries = Query(
            filter: #Predicate<ChatEntry> { $0.sessionId == sessionID },
            sort: \.timestamp,
            order: .forward
        )
    }

    // MARK: - Derived live state

    private var liveBlock: RKBlock? {
        allBlocks.first { $0.id == sessionBlockID }
    }

    private var livePayload: RKAgentSessionPayload? {
        liveBlock?.agentSessionPayload
    }

    private var linkedConfirmations: [RKBlock] {
        allBlocks.filter {
            $0.blockType == .confirmation &&
            $0.confirmationPayload?.sessionId == sessionId
        }
    }

    /// True while the session block is present in allBlocks.
    private var isActive: Bool { liveBlock != nil }

    private var displayProject: String {
        livePayload?.project ?? initialProject
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Reconnecting banner — shown when block is temporarily absent (script restart)
            if !isActive {
                reconnectingBanner
            }
            chatThread
            if isActive, let pc = livePayload?.pendingConfirmation, let block = liveBlock {
                pendingConfirmationBar(pc: pc, block: block)
            }
            Divider()
            composeBar
            if isActive, scriptID == "codex-controller", let block = liveBlock {
                modeToggle(block: block)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(displayProject)
                        .font(.headline)
                    statusLabel
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isActive, livePayload?.isHeadless == true, let block = liveBlock {
                    Button {
                        Task { await onRespond(block, "__go_interactive__") }
                    } label: {
                        Image(systemName: "rectangle.slash")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isActive, let block = liveBlock {
                    Button {
                        showStopConfirm = true
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                    .confirmationDialog("Stop Session?", isPresented: $showStopConfirm) {
                        Button("Stop Session", role: .destructive) {
                            Task { await onRespond(block, "__close_session__") }
                        }
                    } message: {
                        Text("Sends Ctrl+C to the running Codex session.")
                    }
                }
            }
        }
        .onAppear {
            seedInitialEntries()
            // Catch any message that arrived while the view was closed
            if let msg = livePayload?.lastMessage, !msg.isEmpty {
                appendAssistantEntry(msg)
            }
        }
        .onChange(of: livePayload?.lastMessage) { _, newMsg in
            guard let msg = newMsg, !msg.isEmpty else { return }
            captureActivityGroup()
            appendAssistantEntry(msg)
        }
        .onChange(of: linkedConfirmations.map(\.id)) { _, currentIDs in
            for blockID in currentIDs {
                guard let block = linkedConfirmations.first(where: { $0.id == blockID }) else { continue }
                appendInlineBlockEntry(block)
            }
        }
        .onChange(of: isActive) { wasActive, nowActive in
            if wasActive && !nowActive {
                modelContext.insert(ChatEntry(
                    sessionId: sessionId, role: "system", entryKind: "event", text: "Session ended"
                ))
                try? modelContext.save()
                // Auto-pop back to script screen after a brief moment
                Task {
                    try? await Task.sleep(for: .milliseconds(800))
                    dismiss()
                }
            }
        }
        // Reconnecting banner handles the disconnected UI state.
        // History is preserved through script restarts.
    }

    // MARK: - Reconnecting banner

    private var reconnectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.75).tint(.secondary)
            Text("Reconnecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }

    // MARK: - Chat thread

    private var chatThread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(entries, id: \.entryID) { entry in
                        chatEntryView(for: entry)
                            .id(entry.entryID)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func chatEntryView(for entry: ChatEntry) -> some View {
        switch entry.entryKind {
        case "message":
            ChatBubbleView(
                entry: entry,
                sendStatus: sendStatuses[entry.entryID]
            )
        case "inlineBlock":
            InlineBlockCard(
                entry: entry,
                liveBlock: allBlocks.first { $0.id == entry.blockID },
                onRespond: { block, value in
                    await onRespond(block, value)
                    markBlockResolved(entry: entry, value: value)
                }
            )
        case "blockResponse":
            EmptyView() // Reply is now shown inside the InlineBlockCard
        case "activityGroup":
            ActivityGroupCard(entry: entry)
        case "event":
            SystemEventLabel(text: entry.text)
        default:
            EmptyView()
        }
    }

    // MARK: - Compose bar

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composeBar: some View {
        HStack(alignment: .center, spacing: 0) {
            TextField(
                isActive ? (livePayload?.placeholder ?? "Reply…") : "Reconnecting…",
                text: $draft,
                axis: .vertical
            )
            .padding(.leading, 16)
            .padding(.vertical, 12)
            .lineLimit(1...5)
            .font(.body)
            .disabled(!isActive)
            .onSubmit { if !isSending && isActive { Task { await send() } } }

            if hasText || isSending {
                Button { Task { await send() } } label: {
                    ZStack {
                        if isSending {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(isSending ? Color.accentColor.opacity(0.6) : Color.accentColor)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSending || !isActive)
                .padding(.trailing, 8)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 4)
        .animation(.spring(duration: 0.25), value: hasText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.bottom, 8)
        .opacity(isActive ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func pendingConfirmationBar(pc: RKPendingConfirmation, block: RKBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pc.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(pc.options, id: \.self) { option in
                        Button(option) {
                            Task { await onRespond(block, option) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .font(.footnote)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func modeToggle(block: RKBlock) -> some View {
        let isFullAuto = livePayload?.permissionMode == "full-auto"
        Button {
            Task { await onRespond(block, "__permissions__") }
        } label: {
            Text(isFullAuto ? "Full Access" : "Default")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.primary.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if !isActive {
            HStack(spacing: 3) {
                ProgressView().scaleEffect(0.45).tint(.secondary)
                Text("Reconnecting…")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else if let payload = livePayload {
            if payload.isWorking == true {
                HStack(spacing: 3) {
                    ProgressView().scaleEffect(0.45).tint(.secondary)
                    if let tool = payload.currentTool {
                        Text(toolActivityText(tool, payload.currentPreview))
                    } else {
                        Text("Working…")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - History helpers

    private func seedInitialEntries() {
        guard entries.isEmpty else {
            for block in linkedConfirmations { appendInlineBlockEntry(block) }
            return
        }
        modelContext.insert(ChatEntry(
            sessionId: sessionId, role: "system", entryKind: "event", text: "Session started"
        ))
        if let msg = livePayload?.lastMessage, !msg.isEmpty {
            modelContext.insert(ChatEntry(
                sessionId: sessionId, role: "assistant", entryKind: "message", text: msg
            ))
        }
        for block in linkedConfirmations { appendInlineBlockEntry(block) }
        try? modelContext.save()
    }

    private func captureActivityGroup() {
        guard let history = livePayload?.toolHistory, !history.isEmpty else { return }
        // Only capture entries newer than what we've already snapshotted
        let newEntries = history.filter { $0.ts > lastCapturedActivityTs }
        guard !newEntries.isEmpty else { return }
        if let newest = newEntries.map(\.ts).max() {
            lastCapturedActivityTs = newest
        }
        guard let data = try? JSONEncoder().encode(newEntries),
              let json = String(data: data, encoding: .utf8) else { return }
        modelContext.insert(ChatEntry(
            sessionId: sessionId,
            role: "system",
            entryKind: "activityGroup",
            text: "\(newEntries.count) actions",
            blockJSON: json
        ))
        try? modelContext.save()
    }

    private func appendAssistantEntry(_ text: String) {
        // In-memory dedup: guards against the race where SwiftData @Query hasn't
        // updated yet when a second onChange fires with the same text.
        guard text != lastAppendedAssistantText else { return }
        let last = entries.last(where: { $0.role == "assistant" && $0.entryKind == "message" })
        guard text != last?.text else { return }
        lastAppendedAssistantText = text
        modelContext.insert(ChatEntry(
            sessionId: sessionId, role: "assistant", entryKind: "message", text: text
        ))
        try? modelContext.save()
    }

    private func appendInlineBlockEntry(_ block: RKBlock) {
        guard !entries.contains(where: { $0.blockID == block.id }) else { return }
        let title = block.confirmationPayload?.title
            ?? block.promptPayload?.title
            ?? "Request"
        modelContext.insert(ChatEntry(
            sessionId: sessionId,
            role: "system",
            entryKind: "inlineBlock",
            text: title,
            blockID: block.id,
            blockJSON: block.payloadJSON
        ))
        try? modelContext.save()
    }

    private func markBlockResolved(entry: ChatEntry, value: String) {
        entry.resolvedValue = value
        modelContext.insert(ChatEntry(
            sessionId: sessionId,
            role: "user",
            entryKind: "blockResponse",
            text: "Chose: \(value)",
            resolvedValue: value
        ))
        try? modelContext.save()
    }

    private func send() async {
        guard isActive else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isSending = true
        draft = ""

        // Insert entry immediately; use entryID as the CloudKit record name
        // so we can poll for the Mac's readAt delivery receipt later.
        let entry = ChatEntry(
            sessionId: sessionId, role: "user", entryKind: "message", text: text
        )
        modelContext.insert(entry)
        try? modelContext.save()
        sendStatuses[entry.entryID] = .sending

        do {
            try await cloudKit.sendMessage(
                machineID: machineID,
                text: text,
                messageID: entry.entryID,
                sessionID: sessionId,
                scriptID: scriptID
            )
            sendStatuses[entry.entryID] = .sent
            // Watch for Mac delivery confirmation
            pendingDelivery[entry.entryID] = entry.entryID
            Task { await pollDelivery(entryID: entry.entryID) }
        } catch {
            sendStatuses[entry.entryID] = .failed
        }
        isSending = false
    }

    /// Polls the AskMessage record until Mac writes `readAt`, then marks as delivered.
    private func pollDelivery(entryID: String) async {
        let maxAttempts = 30   // ~60s at 2s intervals
        for _ in 0..<maxAttempts {
            try? await Task.sleep(for: .seconds(2))
            guard pendingDelivery[entryID] != nil else { return }  // cancelled externally
            let readAt = await cloudKit.fetchMessageReadAt(messageID: entryID)
            if readAt != nil {
                sendStatuses[entryID] = .delivered
                pendingDelivery.removeValue(forKey: entryID)
                await cloudKit.deleteMessage(messageID: entryID)
                // Clear "delivered" label after a few seconds
                try? await Task.sleep(for: .seconds(4))
                sendStatuses.removeValue(forKey: entryID)
                return
            }
        }
        // Timed out — clear status without marking failed (message may still arrive)
        pendingDelivery.removeValue(forKey: entryID)
        try? await Task.sleep(for: .seconds(4))
        sendStatuses.removeValue(forKey: entryID)
    }
}

// MARK: - Markdown renderer (code-block aware)

private struct MarkdownTextView: View {
    let text: String

    private struct Segment: Identifiable {
        let id = UUID()
        let isCode: Bool
        let lang: String
        let content: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, seg in
                if seg.isCode {
                    codeBlock(seg.content)
                } else {
                    textBlock(seg.content)
                }
            }
        }
    }

    @ViewBuilder
    private func textBlock(_ content: String) -> some View {
        let trimmed = content.trimmingCharacters(in: .newlines)
        if !trimmed.isEmpty {
            Text(.init(trimmed))
                .font(.caption)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func codeBlock(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code.trimmingCharacters(in: .newlines))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var rest = text
        while !rest.isEmpty {
            guard let fenceStart = rest.range(of: "```") else {
                result.append(Segment(isCode: false, lang: "", content: rest))
                break
            }
            let before = String(rest[..<fenceStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Segment(isCode: false, lang: "", content: before))
            }
            rest = String(rest[fenceStart.upperBound...])
            // Optional language tag on first line
            let langEnd = rest.firstIndex(of: "\n") ?? rest.endIndex
            let lang = String(rest[..<langEnd]).trimmingCharacters(in: .whitespaces)
            rest = langEnd < rest.endIndex ? String(rest[rest.index(after: langEnd)...]) : ""
            // Find closing fence
            if let fenceEnd = rest.range(of: "```") {
                result.append(Segment(isCode: true, lang: lang, content: String(rest[..<fenceEnd.lowerBound])))
                rest = String(rest[fenceEnd.upperBound...])
                if rest.hasPrefix("\n") { rest = String(rest.dropFirst()) }
            } else {
                result.append(Segment(isCode: true, lang: lang, content: rest))
                break
            }
        }
        return result
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let entry: ChatEntry
    var sendStatus: MessageSendStatus?

    var body: some View {
        Group {
            if entry.role == "assistant" {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownTextView(text: entry.text)
                }
            } else {
                // Right-aligned user bubble
                HStack {
                    Spacer(minLength: 60)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(entry.text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                sendStatus == .failed ? Color.red.opacity(0.8) : Color.accentColor
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .opacity(sendStatus == .sending ? 0.7 : 1.0)
                        if let status = sendStatus {
                            deliveryLabel(status)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func deliveryLabel(_ status: MessageSendStatus) -> some View {
        HStack(spacing: 3) {
            switch status {
            case .sending:
                ProgressView().scaleEffect(0.5).tint(.secondary)
                Text("Sending…")
            case .sent:
                Image(systemName: "checkmark")
                Text("Sent")
            case .delivered:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Delivered")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Failed").foregroundStyle(.red)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Inline Block Card

private struct InlineBlockCard: View {
    let entry: ChatEntry
    let liveBlock: RKBlock?
    let onRespond: (RKBlock, String) async -> Void

    @State private var isExpanded = false
    @State private var isPending = false

    private var isResolved: Bool { entry.resolvedValue != nil }
    private var isLive: Bool { liveBlock != nil && !isResolved && !isPending }

    /// Body text from the block JSON captured at resolution time.
    private var storedBody: String? {
        guard let json = entry.blockJSON,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let body = payload["body"] as? String, !body.isEmpty
        else { return nil }
        return body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLive, let block = liveBlock {
                BlockView(block: block, onRespond: { value in
                    isPending = true
                    await onRespond(block, value)
                })
                .padding(12)
            } else if isPending && !isResolved {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75).tint(.secondary)
                    Text(entry.text)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                Button {
                    guard storedBody != nil else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.text)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let resolved = entry.resolvedValue {
                                Text(resolved)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if storedBody != nil {
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if isExpanded, let body = storedBody {
                            Text(body)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    (isLive || isPending) ? Color.orange.opacity(0.4) : Color(.separator).opacity(0.3),
                    lineWidth: 1
                )
        )
        .padding(.vertical, 4)
    }
}

// MARK: - Block Response Label

private struct BlockResponseLabel: View {
    let entry: ChatEntry

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(entry.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Activity Group Card (injected into chat after each work burst)

private struct ActivityGroupCard: View {
    let entry: ChatEntry
    @State private var isExpanded = false

    private var entries: [ToolHistoryEntry] {
        guard let json = entry.blockJSON,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ToolHistoryEntry].self, from: data)
        else { return [] }
        return decoded.sorted { $0.ts > $1.ts }
    }

    private var spanLabel: String {
        let tss = entries.map(\.ts)
        guard let first = tss.min(), let last = tss.max(), last > first else { return "" }
        let secs = Int(last - first)
        return secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(entry.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !spanLabel.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(spanLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries, id: \.ts) { e in
                        HStack(spacing: 8) {
                            Image(systemName: toolIcon(e.tool))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .center)
                            Text(toolActivityText(e.tool, e.preview))
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(relativeTime(e.ts))
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                                .fixedSize()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
        .padding(.vertical, 3)
    }
}

// MARK: - System Event Label

private struct SystemEventLabel: View {
    let text: String

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

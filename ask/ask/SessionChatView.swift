import SwiftUI
import SwiftData

// MARK: - Session Row (in ScriptDetailView session list)

struct SessionRowView: View {
    let payload: RKAgentSessionPayload
    let confirmationCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(payload.isWorking == true ? Color.blue : Color(.systemGray4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.project)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Group {
                    if let msg = payload.lastMessage, !msg.isEmpty {
                        Text(msg.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? msg)
                            .foregroundStyle(.secondary)
                    } else if payload.isWorking == true {
                        Text("\(payload.agentName ?? "Agent") is working…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Session started")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer()
            if confirmationCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
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
    @Query private var entries: [ChatEntry]

    @State private var draft = ""
    @State private var isSending = false
    @State private var sessionEndedTask: Task<Void, Never>?

    private let sessionId: String
    private let initialProject: String

    init(
        sessionBlockID: String,
        sessionPayload: RKAgentSessionPayload,
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
        self.sessionId = sessionPayload.sessionId
        self.initialProject = sessionPayload.project
        let id = sessionPayload.sessionId
        _entries = Query(
            filter: #Predicate<ChatEntry> { $0.sessionId == id },
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

    private var isActive: Bool { liveBlock != nil }

    private var displayProject: String {
        livePayload?.project ?? initialProject
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            chatThread
            Divider()
            if isActive {
                composeBar
            } else {
                endedNotice
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
        }
        .onAppear {
            seedInitialEntries()
        }
        .onChange(of: livePayload?.lastMessage) { _, newMsg in
            guard let msg = newMsg, !msg.isEmpty else { return }
            appendAssistantEntry(msg)
        }
        .onChange(of: linkedConfirmations.map(\.id)) { _, currentIDs in
            for blockID in currentIDs {
                guard let block = linkedConfirmations.first(where: { $0.id == blockID }) else { continue }
                appendInlineBlockEntry(block)
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                sessionEndedTask?.cancel()
                sessionEndedTask = Task {
                    // Grace period: transient block disappearances (script restart) last ~6 s
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        deleteChatData()
                        dismiss()
                    }
                }
            } else {
                sessionEndedTask?.cancel()
                sessionEndedTask = nil
            }
        }
        .onDisappear {
            sessionEndedTask?.cancel()
        }
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
            ChatBubbleView(entry: entry)
        case "inlineBlock":
            InlineBlockCard(
                entry: entry,
                liveBlock: allBlocks.first { $0.id == entry.blockID },
                onRespond: { block, value in
                    markBlockResolved(entry: entry, value: value)
                    await onRespond(block, value)
                }
            )
        case "blockResponse":
            BlockResponseLabel(entry: entry)
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
                livePayload?.placeholder ?? "Reply…",
                text: $draft,
                axis: .vertical
            )
            .padding(.leading, 16)
            .padding(.vertical, 12)
            .lineLimit(1...5)
            .font(.body)
            .onSubmit { if !isSending { Task { await send() } } }

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
                .disabled(isSending)
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
    }

    private var endedNotice: some View {
        Text("Session ended")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let payload = livePayload {
            if payload.isWorking == true {
                HStack(spacing: 3) {
                    ProgressView().scaleEffect(0.45).tint(.secondary)
                    Text("Working…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Ended")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    private func appendAssistantEntry(_ text: String) {
        let last = entries.last(where: { $0.role == "assistant" && $0.entryKind == "message" })
        guard text != last?.text else { return }
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

    private func deleteChatData() {
        let id = sessionId
        let fetch = FetchDescriptor<ChatEntry>(
            predicate: #Predicate { $0.sessionId == id }
        )
        if let toDelete = try? modelContext.fetch(fetch) {
            for entry in toDelete { modelContext.delete(entry) }
        }
        try? modelContext.save()
    }

    private func send() async {
        guard let block = liveBlock else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isSending = true
        draft = ""
        modelContext.insert(ChatEntry(
            sessionId: sessionId, role: "user", entryKind: "message", text: text
        ))
        try? modelContext.save()
        await onRespond(block, text)
        isSending = false
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let entry: ChatEntry
    @State private var isExpanded = false

    private var needsExpansion: Bool {
        entry.role == "assistant" && entry.text.count > 240
    }

    var body: some View {
        HStack(alignment: .top) {
            if entry.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: entry.role == "user" ? .trailing : .leading, spacing: 4) {
                if entry.role == "assistant" {
                    Text(entry.text)
                        .font(.subheadline)
                        .lineLimit(isExpanded ? nil : 4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    if needsExpansion {
                        Button(isExpanded ? "Show less" : "Show more") {
                            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                        }
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text(entry.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            if entry.role != "user" { Spacer(minLength: 60) }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Inline Block Card

private struct InlineBlockCard: View {
    let entry: ChatEntry
    let liveBlock: RKBlock?
    let onRespond: (RKBlock, String) async -> Void

    private var isResolved: Bool { entry.resolvedValue != nil }
    private var isLive: Bool { liveBlock != nil && !isResolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLive, let block = liveBlock {
                BlockView(block: block, onRespond: { value in
                    await onRespond(block, value)
                })
                .padding(12)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(isResolved ? "Chose: \(entry.resolvedValue!)" : entry.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isLive ? Color.orange.opacity(0.4) : Color(.separator).opacity(0.3),
                    lineWidth: 1
                )
        )
        .opacity(isLive ? 1.0 : 0.65)
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

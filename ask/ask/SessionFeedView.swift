import SwiftUI
import SwiftData

struct SessionFeedView: View {
    let sessionBlockID: String
    let allBlocks: [RKBlock]
    let scriptID: String
    let machineID: String
    let onRespond: (RKBlock, String) async -> Void

    @Environment(\.dismiss) private var dismiss

    @Query private var messages: [TaskMessage]
    @Query private var artifacts: [ArtifactRecord]

    @State private var draft = ""
    @State private var isSending = false
    @State private var showStopConfirm = false

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
        let taskID = sessionID
        _messages = Query(
            filter: #Predicate<TaskMessage> { $0.taskID == taskID && $0.machineID == machineID },
            sort: \.sequenceNumber,
            order: .forward
        )
        _artifacts = Query(
            filter: #Predicate<ArtifactRecord> { $0.taskID == taskID && $0.machineID == machineID },
            sort: \.updatedAt,
            order: .forward
        )
    }

    private var liveBlock: RKBlock? {
        allBlocks.first { $0.id == sessionBlockID }
    }

    private var livePayload: RKAgentSessionPayload? {
        liveBlock?.agentSessionPayload
    }

    private var isActive: Bool { liveBlock != nil }

    private var displayProject: String {
        livePayload?.project ?? initialProject
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isActive {
                reconnectingBanner
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages, id: \.messageID) { message in
                            SessionFeedMessageRow(message: message)
                                .id(message.messageID)
                        }
                        ForEach(unattachedArtifacts, id: \.recordName) { artifact in
                            SessionFeedArtifactRow(artifact: artifact)
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            if isActive, let pending = livePayload?.pendingConfirmation, let block = liveBlock {
                pendingConfirmationBar(pending, block: block)
            }
            Divider()
            composeBar
            if isActive, let block = liveBlock {
                permissionModeToggle(block: block)
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
                if isActive, let block = liveBlock {
                    Button {
                        Task { await onRespond(block, "__interrupt__") }
                    } label: {
                        Image(systemName: "stop.circle")
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
                    }
                }
            }
        }
    }

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
    }

    private var composeBar: some View {
        HStack(spacing: 0) {
            TextField(isActive ? "Message Codex…" : "Reconnecting…", text: $draft, axis: .vertical)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .lineLimit(1...5)
                .disabled(!isActive)
                .onSubmit { if isActive { Task { await send() } } }
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending {
                Button {
                    Task { await send() }
                } label: {
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
                    .background(Color.accentColor)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .disabled(!isActive || isSending)
            }
        }
        .glassEffect(in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .padding(.bottom, 8)
        .opacity(isActive ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func pendingConfirmationBar(_ confirmation: RKPendingConfirmation, block: RKBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmation.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(confirmation.options, id: \.self) { option in
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
    private func permissionModeToggle(block: RKBlock) -> some View {
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
                    } else if let preview = payload.lastMessage {
                        Text(preview)
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

    private var unattachedArtifacts: [ArtifactRecord] {
        artifacts.filter { artifact in
            !messages.contains { message in
                message.parts.contains { part in
                    guard case .file(_, let uri) = part else { return false }
                    return uri == artifact.artifactID || uri == artifact.filename
                }
            }
        }
    }

    private func send() async {
        guard let block = liveBlock else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        draft = ""
        await onRespond(block, text)
        isSending = false
    }
}

private struct SessionFeedMessageRow: View {
    let message: TaskMessage

    var body: some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text):
                    if isUser {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 60)
                    } else {
                        SessionFeedMarkdownView(text: text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .file(let mimeType, let uri):
                    Label(uri.isEmpty ? mimeType : uri, systemImage: "doc.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .data(let mimeType, _):
                    Label(mimeType, systemImage: "doc.badge.ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
    }
}

private struct SessionFeedArtifactRow: View {
    let artifact: ArtifactRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                if let desc = artifact.artifactDescription {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SessionFeedMarkdownView: View {
    let text: String

    var body: some View {
        Text(.init(text))
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

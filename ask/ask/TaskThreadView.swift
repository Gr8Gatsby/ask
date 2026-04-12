import SwiftUI
import SwiftData
import QuickLook

// MARK: - Task Thread View

/// Shows the full persistent history for a single A2A task: messages and artifacts.
/// Reads TaskMessage and ArtifactRecord from SwiftData via @Query.
struct TaskThreadView: View {
    let task: TaskRecord

    @Environment(TaskHistoryStore.self) private var taskHistory
    @Environment(\.dismiss) private var dismiss

    @Query private var messages: [TaskMessage]
    @Query private var artifacts: [ArtifactRecord]

    @State private var previewURL: URL?

    init(task: TaskRecord) {
        self.task = task
        let taskID = task.taskID
        let machineID = task.machineID
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(messages, id: \.messageID) { msg in
                        MessageRow(message: msg, artifacts: artifacts(for: msg))
                            .id(msg.messageID)
                    }
                    if !artifacts.filter({ !isReferenced($0) }).isEmpty {
                        unattachedArtifactsSection
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    taskStatusLabel
                }
            }
        }
        .quickLookPreview($previewURL)
        .task {
            await taskHistory.refresh(machineIDs: [task.machineID])
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                await taskHistory.refresh(machineIDs: [task.machineID])
            }
        }
    }

    // MARK: - Status label

    private var taskStatusLabel: some View {
        HStack(spacing: 3) {
            let status = task.statusEnum
            if status == .working {
                ProgressView().scaleEffect(0.45).tint(.secondary)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 8))
                    .foregroundStyle(statusColor(status))
            }
            Text(status.displayName)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .working: .secondary
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    // MARK: - Artifact helpers

    /// Returns artifacts referenced by file parts in this message.
    private func artifacts(for message: TaskMessage) -> [ArtifactRecord] {
        let uris = message.parts.compactMap { part -> String? in
            guard case .file(_, let uri) = part else { return nil }
            return uri
        }
        return artifacts.filter { art in uris.contains(art.artifactID) || uris.contains(art.filename) }
    }

    /// True if an artifact is referenced by any message's file part.
    private func isReferenced(_ artifact: ArtifactRecord) -> Bool {
        messages.contains { msg in
            msg.parts.contains { part in
                guard case .file(_, let uri) = part else { return false }
                return uri == artifact.artifactID || uri == artifact.filename
            }
        }
    }

    // MARK: - Unattached artifacts section

    private var unattachedArtifactsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attachments")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            ForEach(artifacts.filter { !isReferenced($0) }, id: \.recordName) { art in
                ArtifactCard(artifact: art, onPreview: { url in previewURL = url })
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Message Row

private struct MessageRow: View {
    let message: TaskMessage
    let artifacts: [ArtifactRecord]

    @Environment(TaskHistoryStore.self) private var taskHistory
    @State private var previewURL: URL?

    var body: some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                partView(part)
            }
            ForEach(artifacts, id: \.recordName) { art in
                ArtifactCard(artifact: art, onPreview: { url in previewURL = url })
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func partView(_ part: TaskPart) -> some View {
        let isUser = message.role == "user"
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
                TaskMarkdownView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .file(let mimeType, _):
            Label(mimeType, systemImage: "doc.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .data(let mimeType, _):
            Label(mimeType, systemImage: "doc.badge.ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Artifact Card

struct ArtifactCard: View {
    let artifact: ArtifactRecord
    let onPreview: (URL) -> Void

    @Environment(TaskHistoryStore.self) private var taskHistory
    @State private var isDownloading = false
    @State private var showMarkdown = false
    @State private var isSharing = false

    private var isMarkdown: Bool {
        artifact.filename.hasSuffix(".md") || artifact.filename.hasSuffix(".markdown")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)

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
                Text(formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if artifact.isDownloaded {
                // Share / save to Files
                Button {
                    isSharing = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .shareSheet(isPresented: $isSharing, url: artifact.localCacheURL)

                // Preview — rich markdown for .md, QuickLook for everything else
                Button {
                    if isMarkdown {
                        showMarkdown = true
                    } else {
                        onPreview(artifact.localCacheURL)
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                .sheet(isPresented: $showMarkdown) {
                    MarkdownPreviewSheet(artifact: artifact)
                }
            } else {
                Button {
                    Task { await download() }
                } label: {
                    if isDownloading {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isDownloading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    private var fileIcon: String {
        if isMarkdown { return "doc.text" }
        switch artifact.mimeType {
        case "application/pdf": return "doc.richtext"
        case "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp": return "photo"
        case "text/plain": return "doc.text"
        case "application/json": return "curlybraces"
        case let m where m.hasPrefix("video/"): return "video"
        case let m where m.hasPrefix("audio/"): return "waveform"
        default: return "doc"
        }
    }

    private var formattedSize: String {
        let kb = Double(artifact.sizeBytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", max(kb, 1)) }
        return String(format: "%.1f MB", kb / 1024)
    }

    private func download() async {
        isDownloading = true
        await taskHistory.downloadArtifact(artifact)
        isDownloading = false
    }
}

// MARK: - Markdown Preview Sheet

private struct MarkdownPreviewSheet: View {
    let artifact: ArtifactRecord
    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false

    private var markdownText: String {
        (try? String(contentsOf: artifact.localCacheURL, encoding: .utf8)) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ClaudeMarkdownView(text: markdownText)
                    .padding(16)
            }
            .navigationTitle(artifact.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .shareSheet(isPresented: $isSharing, url: artifact.localCacheURL)
                }
            }
        }
    }
}

// MARK: - Share sheet helper

private extension View {
    func shareSheet(isPresented: Binding<Bool>, url: URL) -> some View {
        background(
            ShareSheetPresenter(isPresented: isPresented, url: url)
        )
    }
}

private struct ShareSheetPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let url: URL

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard isPresented, uiViewController.presentedViewController == nil else { return }
        let ac = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ac.completionWithItemsHandler = { _, _, _, _ in isPresented = false }
        uiViewController.present(ac, animated: true)
    }
}

// MARK: - Task Markdown View

/// Simple markdown renderer for task message text (mirrors SessionChatView's MarkdownTextView).
private struct TaskMarkdownView: View {
    let text: String

    private struct Segment: Identifiable {
        let id = UUID()
        let isCode: Bool
        let content: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(segments) { seg in
                if seg.isCode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(seg.content.trimmingCharacters(in: .newlines))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    let trimmed = seg.content.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        Text(.init(trimmed))
                            .font(.caption)
                            .lineSpacing(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var rest = text
        while !rest.isEmpty {
            guard let start = rest.range(of: "```") else {
                result.append(Segment(isCode: false, content: rest)); break
            }
            let before = String(rest[..<start.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(Segment(isCode: false, content: before))
            }
            rest = String(rest[start.upperBound...])
            if let newline = rest.firstIndex(of: "\n") { rest = String(rest[rest.index(after: newline)...]) }
            if let end = rest.range(of: "```") {
                result.append(Segment(isCode: true, content: String(rest[..<end.lowerBound])))
                rest = String(rest[end.upperBound...])
                if rest.hasPrefix("\n") { rest = String(rest.dropFirst()) }
            } else {
                result.append(Segment(isCode: true, content: rest)); break
            }
        }
        return result
    }
}

// MARK: - Task List Row (used in feed / task list)

struct TaskListRow: View {
    let task: TaskRecord

    var body: some View {
        let status = task.statusEnum
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(task.lastActivityAt.briefRelative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            HStack(spacing: 4) {
                Text(task.scriptName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if status == .working {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(.blue)
                } else {
                    Image(systemName: status.systemImage)
                        .font(.system(size: 9))
                        .foregroundStyle(statusColor(status))
                }
                if task.artifactCount > 0 {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label("\(task.artifactCount)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .working:   .blue
        case .completed: .green
        case .failed:    .red
        case .cancelled: .secondary
        }
    }
}

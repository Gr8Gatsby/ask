import SwiftUI

struct JobDetailView: View {
    let initialJob: AskJob

    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var job: AskJob
    @State private var chunks: [AskOutputChunk] = []
    @State private var pollTask: Task<Void, Never>?
    @State private var autoScroll = true
    @State private var isCancelling = false

    init(initialJob: AskJob) {
        self.initialJob = initialJob
        self._job = State(initialValue: initialJob)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            Divider()
            outputView
        }
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: job.status.systemImage)
                .font(.title3)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.status.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                HStack(spacing: 4) {
                    Text(job.createdAt, style: .date)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(job.createdAt, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let duration = durationLabel {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !job.status.isTerminal && !isCancelling {
                Button("Cancel", role: .destructive) {
                    Task { await cancelJob() }
                }
                .font(.subheadline)
                .foregroundStyle(.red)
            } else if isCancelling {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Output

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if chunks.isEmpty {
                        if job.status.isTerminal {
                            Text("No output.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(16)
                        } else {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for output…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                        }
                    } else {
                        Text(combinedOutput)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    // Scroll anchor
                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .background(Color(.systemBackground))
            .simultaneousGesture(
                DragGesture().onChanged { _ in autoScroll = false }
            )
            .onChange(of: chunks.count) { _, _ in
                if autoScroll {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: job.status) { _, _ in
                // Re-enable auto-scroll on status change so final output is visible
                autoScroll = true
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !autoScroll && !chunks.isEmpty {
            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    autoScroll = true
                } label: {
                    Label("Scroll to bottom", systemImage: "arrow.down.to.line")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Polling

    private func startPolling() async {
        // Initial fetch
        await refresh()

        guard !job.status.isTerminal else { return }

        pollTask = Task {
            while !Task.isCancelled && !job.status.isTerminal {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    @MainActor
    private func refresh() async {
        async let freshJob = cloudKit.fetchJob(jobID: job.id)
        async let freshChunks = cloudKit.fetchOutputChunks(jobID: job.id)

        if let updated = try? await freshJob {
            job = updated
        }
        if let updated = try? await freshChunks {
            chunks = updated
        }
    }

    private func cancelJob() async {
        isCancelling = true
        do {
            try await cloudKit.cancelJob(jobID: job.id)
            // Optimistic update
            if let updated = try? await cloudKit.fetchJob(jobID: job.id) {
                job = updated
            }
        } catch {
            // Leave isCancelling = false so button reappears
        }
        isCancelling = false
    }

    // MARK: - Helpers

    private var combinedOutput: String {
        chunks.map(\.text).joined()
    }

    private var statusColor: Color {
        switch job.status {
        case .completed:                              .green
        case .failed:                                 .red
        case .cancelled:                              .secondary
        case .running:                                .blue
        case .queued, .acknowledged, .waiting:        .orange
        }
    }

    private var durationLabel: String? {
        guard let start = job.startedAt else { return nil }
        let end = job.completedAt ?? Date()
        let s = end.timeIntervalSince(start)
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%dm %ds", Int(s) / 60, Int(s) % 60)
    }
}

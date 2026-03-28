import SwiftUI

struct JobDetailView: View {
    let jobID: String
    let initialJob: AskJob

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var job: AskJob
    @State private var chunks: [AskOutputChunk] = []
    @State private var isAutoScrolling = true
    @State private var pollingTask: Task<Void, Never>?

    init(jobID: String, initialJob: AskJob) {
        self.jobID = jobID
        self.initialJob = initialJob
        self._job = State(initialValue: initialJob)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            Divider()
            outputView
        }
        .navigationTitle(job.prompt)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await startPolling() }
        .onDisappear { pollingTask?.cancel() }
    }

    // MARK: - Status banner

    private var statusBanner: some View {
        HStack(spacing: 10) {
            if job.status == .running || job.status == .acknowledged {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: job.status.systemImage)
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(job.status.displayName)
                    .font(.subheadline.weight(.medium))
                if let duration = durationText {
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let exitCode = job.exitCode {
                Text("exit \(exitCode)")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(exitCode == 0 ? .green : .red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Output

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks) { chunk in
                        Text(chunk.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(chunk.isError ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if chunks.isEmpty && !job.status.isTerminal {
                        Text("Waiting for output…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(12)
            }
            .background(Color(uiColor: .systemBackground))
            .onChange(of: chunks.count) {
                if isAutoScrolling {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5).onChanged { value in
                    // Stop auto-scroll if user scrolls up
                    if value.translation.height > 0 { isAutoScrolling = false }
                }
            )
        }
        .onTapGesture { isAutoScrolling = true }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !job.status.isTerminal {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    Task { await cancel() }
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
            }
        }
        if !isAutoScrolling {
            ToolbarItem(placement: .bottomBar) {
                Button("Scroll to bottom") {
                    isAutoScrolling = true
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Polling

    private func startPolling() async {
        // Load any existing output immediately
        await refresh()

        // Poll every 3s while job is active
        pollingTask = Task {
            while !job.status.isTerminal {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
        await pollingTask?.value
    }

    private func refresh() async {
        async let jobFetch = cloudKit.fetchJob(jobID: jobID)
        async let chunksFetch = cloudKit.fetchOutputChunks(jobID: jobID)

        if let updated = try? await jobFetch {
            job = updated
        }
        if let fetched = try? await chunksFetch {
            chunks = fetched
        }
    }

    private func cancel() async {
        try? await cloudKit.cancelJob(jobID: jobID)
        if let updated = try? await cloudKit.fetchJob(jobID: jobID) {
            job = updated
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .running: .blue
        default: .secondary
        }
    }

    private var durationText: String? {
        guard let start = job.startedAt else { return nil }
        let end = job.completedAt ?? Date()
        let secs = Int(end.timeIntervalSince(start))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

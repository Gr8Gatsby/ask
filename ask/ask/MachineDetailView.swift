import SwiftUI

struct MachineDetailView: View {
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var currentMachine: AskMachine
    @State private var agents: [AskAgent] = []
    @State private var recentJobs: [AskJob] = []
    @State private var pendingEvents: [AskEvent] = []
    @State private var sessions: [AskSession] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var selectedAgent: AskAgent?
    @State private var pollTask: Task<Void, Never>?

    init(machine: AskMachine) {
        self.machine = machine
        self._currentMachine = State(initialValue: machine)
    }

    var body: some View {
        List {
            if !sessions.isEmpty {
                sessionsSection
            }
            if !legacyActionableEvents.isEmpty {
                legacyEventsSection
            }
            statusSection
            messagesSection
            agentsSection
            if !recentJobs.isEmpty {
                recentJobsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .sheet(item: $selectedAgent) { agent in
            NewJobView(machine: machine, agent: agent)
                .environment(cloudKit)
        }
        .task {
            await load()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .askRefreshRequired)) { _ in
            Task { await load() }
        }
    }

    // MARK: - Sections

    /// Events not tied to a session (legacy / non-Claude-Code events).
    private var legacyActionableEvents: [AskEvent] {
        pendingEvents.filter { $0.requiresResponse && ($0.sessionID == nil || $0.sessionID!.isEmpty) }
    }

    private var sessionsSection: some View {
        Section {
            ForEach(sortedSessions) { session in
                NavigationLink {
                    SessionDetailView(session: session, machineID: machine.id)
                        .environment(cloudKit)
                } label: {
                    SessionRow(session: session)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await deleteSession(session) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                Label("Claude Sessions", systemImage: "sparkles")
                Spacer()
                if sessions.contains(where: { $0.status == .active }) {
                    Label("Active", systemImage: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var sortedSessions: [AskSession] {
        sessions.sorted {
            if $0.status.isWaiting != $1.status.isWaiting {
                return $0.status.isWaiting
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    private var legacyEventsSection: some View {
        Section {
            ForEach(legacyActionableEvents) { event in
                EventCard(event: event) { choice in
                    await respond(to: event, choice: choice)
                }
            }
        } header: {
            Label("Waiting for Input", systemImage: "person.fill.questionmark")
                .foregroundStyle(.orange)
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: currentMachine.connectionStatus.systemImage)
                    Text(currentMachine.connectionStatus.label)
                }
                .foregroundStyle(statusColor)
            }
            LabeledContent("Last seen") {
                Text(currentMachine.lastHeartbeat.briefRelative)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var messagesSection: some View {
        Section {
            NavigationLink {
                MessagesView(machine: currentMachine)
                    .environment(cloudKit)
            } label: {
                Label("Messages", systemImage: "message")
            }
        }
    }

    private var agentsSection: some View {
        Section {
            if !hasLoaded && isLoading && agents.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if agents.isEmpty {
                Text("No actions configured")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(agents) { agent in
                    Button {
                        selectedAgent = agent
                    } label: {
                        AgentRow(agent: agent)
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            if !agents.isEmpty {
                Text("Tap an action to send a job.")
                    .font(.caption)
            }
        }
    }

    private var recentJobsSection: some View {
        Section("Recent Jobs") {
            ForEach(recentJobs) { job in
                NavigationLink(value: job.id) {
                    JobRow(job: job, agentName: agentName(for: job))
                }
            }
        }
        .navigationDestination(for: String.self) { jobID in
            if let job = recentJobs.first(where: { $0.id == jobID }) {
                JobDetailView(jobID: job.id, initialJob: job)
                    .environment(cloudKit)
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch currentMachine.connectionStatus {
        case .online: .green
        case .busy: .blue
        case .sleeping: .yellow
        case .offline: .secondary
        }
    }

    private func agentName(for job: AskJob) -> String {
        agents.first(where: { $0.id == job.agentID })?.name ?? "Unknown Agent"
    }

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        async let machineFetch = cloudKit.fetchMachine(machineID: machine.id)
        async let agentsFetch = cloudKit.fetchAgents(machineID: machine.id)
        async let jobsFetch = cloudKit.fetchRecentJobs(machineID: machine.id)
        async let eventsFetch = cloudKit.fetchPendingEvents(machineID: machine.id)
        async let sessionsFetch = cloudKit.fetchSessions(machineID: machine.id)
        currentMachine = (try? await machineFetch) ?? currentMachine
        agents = (try? await agentsFetch) ?? agents
        recentJobs = (try? await jobsFetch) ?? recentJobs
        pendingEvents = (try? await eventsFetch) ?? pendingEvents
        sessions = (try? await sessionsFetch) ?? sessions
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }

    private func deleteSession(_ session: AskSession) async {
        try? await cloudKit.deleteSession(session)
        withAnimation { sessions.removeAll { $0.id == session.id } }
    }

    private func respond(to event: AskEvent, choice: String) async {
        do {
            try await cloudKit.saveResponse(eventID: event.id, machineID: event.machineID, choice: choice)
            try? await cloudKit.deleteEvent(event)
            pendingEvents.removeAll { $0.id == event.id }
        } catch {
            print("[MachineDetailView] Failed to save response: \(error)")
        }
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: AskSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.status.isWaiting ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.subheadline)
                    .fontWeight(session.status.isWaiting ? .semibold : .regular)
                Text(session.lastActivityAt.briefRelative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.status.isWaiting {
                Text("Waiting")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Agent row

struct AgentRow: View {
    let agent: AskAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: agent.icon ?? "terminal.fill")
                    .foregroundStyle(Color.accentColor)
                Text(agent.name)
                    .font(.body)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(agent.scriptName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontDesign(.monospaced)
            capabilityBadges
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var capabilityBadges: some View {
        if agent.capabilityNetwork || agent.capabilitySubprocess || !agent.capabilityReadPaths.isEmpty || !agent.capabilityWritePaths.isEmpty {
            HStack(spacing: 4) {
                if agent.capabilityNetwork { badge("Network", color: .blue) }
                if agent.capabilitySubprocess { badge("Subprocess", color: .purple) }
                if !agent.capabilityReadPaths.isEmpty { badge("Read", color: .green) }
                if !agent.capabilityWritePaths.isEmpty { badge("Write", color: .orange) }
            }
        }
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Job row

struct JobRow: View {
    let job: AskJob
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(job.prompt)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }
            HStack(spacing: 4) {
                Text(agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(job.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        Label(job.status.displayName, systemImage: job.status.systemImage)
            .font(.caption2)
            .labelStyle(.iconOnly)
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        case .running: .blue
        default: .secondary
        }
    }
}

// MARK: - Event card

struct EventCard: View {
    let event: AskEvent
    let onRespond: (String) async -> Void

    @State private var responding = false
    @State private var selectedOption: String?
    @State private var textInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image("claudecode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if !event.body.isEmpty {
                        Text(event.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(event.timestamp.briefRelative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !event.options.isEmpty {
                if event.options.count <= 2 {
                    // Allow/Deny style: compact side-by-side buttons
                    HStack(spacing: 8) {
                        ForEach(event.options, id: \.self) { option in
                            optionButton(option)
                        }
                    }
                } else {
                    // 3+ options: single-select list with full text visible
                    optionList
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Type your answer…", text: $textInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(responding)
                    Button {
                        let answer = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !answer.isEmpty else { return }
                        Task {
                            responding = true
                            await onRespond(answer)
                            responding = false
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .disabled(responding || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // Compact button for 2-option (Allow/Deny) layout
    private func optionButton(_ option: String) -> some View {
        Button {
            Task {
                responding = true
                await onRespond(option)
                responding = false
            }
        } label: {
            Text(option)
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(responding)
    }

    // Single-select list for 3+ options
    private var optionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(event.options.enumerated()), id: \.element) { idx, option in
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
                                .stroke(selectedOption == option ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                            if selectedOption == option {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 11, height: 11)
                            }
                        }
                        Text(option)
                            .font(.subheadline)
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

                if idx < event.options.count - 1 {
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

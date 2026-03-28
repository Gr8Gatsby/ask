import SwiftUI

struct MachineDetailView: View {
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var currentMachine: AskMachine
    @State private var agents: [AskAgent] = []
    @State private var recentJobs: [AskJob] = []
    @State private var isLoading = false
    @State private var selectedAgent: AskAgent?

    init(machine: AskMachine) {
        self.machine = machine
        self._currentMachine = State(initialValue: machine)
    }

    var body: some View {
        List {
            statusSection
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
        .task { await load() }
    }

    // MARK: - Sections

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

    private var agentsSection: some View {
        Section {
            if isLoading && agents.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if agents.isEmpty {
                Text("No agents configured")
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
            Text("Agents")
        } footer: {
            if !agents.isEmpty {
                Text("Tap an agent to send a job.")
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
        defer { isLoading = false }
        async let machineFetch = cloudKit.fetchMachine(machineID: machine.id)
        async let agentsFetch = cloudKit.fetchAgents(machineID: machine.id)
        async let jobsFetch = cloudKit.fetchRecentJobs(machineID: machine.id)
        currentMachine = (try? await machineFetch) ?? currentMachine
        agents = (try? await agentsFetch) ?? agents
        recentJobs = (try? await jobsFetch) ?? recentJobs
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

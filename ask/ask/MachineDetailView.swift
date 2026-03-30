import SwiftUI

struct MachineDetailView: View {
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit
    @State private var currentMachine: AskMachine
    @State private var agents: [AskAgent] = []
    @State private var jobs: [AskJob] = []

    init(machine: AskMachine) {
        self.machine = machine
        self._currentMachine = State(initialValue: machine)
    }

    var body: some View {
        List {
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

            if !agents.isEmpty {
                Section("Actions") {
                    ForEach(agents) { agent in
                        NavigationLink {
                            NewJobView(agent: agent, machine: currentMachine)
                                .environment(cloudKit)
                        } label: {
                            AgentRow(agent: agent)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    MessagesView(machine: currentMachine)
                        .environment(cloudKit)
                } label: {
                    Label("Messages", systemImage: "message")
                }
            }

            if !jobs.isEmpty {
                Section("Recent Jobs") {
                    ForEach(jobs) { job in
                        NavigationLink {
                            JobDetailView(initialJob: job)
                                .environment(cloudKit)
                        } label: {
                            JobHistoryRow(job: job, agentName: agents.first(where: { $0.id == job.agentID })?.name)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            async let freshMachine = cloudKit.fetchMachine(machineID: machine.id)
            async let fetchedAgents = cloudKit.fetchAgents(machineID: machine.id)
            async let fetchedJobs = cloudKit.fetchRecentJobs(machineID: machine.id)

            currentMachine = (try? await freshMachine) ?? currentMachine
            agents = (try? await fetchedAgents) ?? []
            jobs = (try? await fetchedJobs) ?? []
        }
    }

    private var statusColor: Color {
        switch currentMachine.connectionStatus {
        case .online:   .green
        case .busy:     .blue
        case .sleeping: .yellow
        case .offline:  .secondary
        }
    }
}

// MARK: - Agent row

private struct AgentRow: View {
    let agent: AskAgent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.icon ?? "terminal.fill")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body)
                if !capabilitySummary.isEmpty {
                    Text(capabilitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var capabilitySummary: String {
        var parts: [String] = []
        if agent.capabilityNetwork { parts.append("Network") }
        if agent.capabilitySubprocess { parts.append("Subprocess") }
        if !agent.capabilityReadPaths.isEmpty { parts.append("Read") }
        if !agent.capabilityWritePaths.isEmpty { parts.append("Write") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Job history row

private struct JobHistoryRow: View {
    let job: AskJob
    let agentName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.status.systemImage)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.prompt)
                    .font(.subheadline)
                    .lineLimit(1)
                if let name = agentName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(job.createdAt.briefRelative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch job.status {
        case .completed:                     .green
        case .failed:                        .red
        case .cancelled:                     .secondary
        case .queued, .acknowledged, .running, .waiting: .blue
        }
    }
}

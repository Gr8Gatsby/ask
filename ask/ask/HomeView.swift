import SwiftUI

struct HomeView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var machines: [AskMachine] = []
    @State private var sessions: [AskSession] = []
    @State private var agents: [AskAgent] = []
    @State private var pendingEvents: [AskEvent] = []

    @State private var hasLoaded = false
    @State private var activeMachineID: String?
    @State private var showSettings = false
    @State private var selectedAgent: AskAgent?
    @State private var pollTask: Task<Void, Never>?

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
    }

    // Sessions waiting for input
    private var waitingSessions: [AskSession] {
        sessions.filter { $0.status.isWaiting }
    }

    // Sessions that are active / recently active
    private var activeSessions: [AskSession] {
        sessions.filter { !$0.status.isWaiting }
    }

    // Legacy events not tied to a session
    private var legacyEvents: [AskEvent] {
        pendingEvents.filter { $0.requiresResponse && ($0.sessionID == nil || $0.sessionID!.isEmpty) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if machines.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView()
                .environment(cloudKit)
        }
        .sheet(item: $selectedAgent) { agent in
            if let machine = activeMachine {
                NewJobView(machine: machine, agent: agent)
                    .environment(cloudKit)
            }
        }
        .task {
            await cloudKit.checkAccountStatus()
            await load()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .askRefreshRequired)) { _ in
            Task { await load() }
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            // Machine status — compact, always visible
            if let machine = activeMachine {
                Section {
                    MachineStatusRow(machine: machine)
                }
            }

            // Waiting sessions — urgent, always at top
            if !waitingSessions.isEmpty {
                Section {
                    ForEach(waitingSessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session, machineID: activeMachine?.id ?? "")
                                .environment(cloudKit)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text("Needs Input")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Legacy events (no sessionID)
            if !legacyEvents.isEmpty {
                Section {
                    ForEach(legacyEvents) { event in
                        EventCard(event: event) { choice in
                            await respond(to: event, choice: choice)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text("Waiting for Input")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Active / recent sessions
            if !activeSessions.isEmpty {
                Section {
                    ForEach(activeSessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session, machineID: activeMachine?.id ?? "")
                                .environment(cloudKit)
                        } label: {
                            SessionRow(session: session)
                        }
                    }
                } header: {
                    Label("Claude Sessions", systemImage: "sparkles")
                }
            }

            // Actions
            if !agents.isEmpty {
                Section {
                    ForEach(agents) { agent in
                        Button {
                            selectedAgent = agent
                        } label: {
                            AgentRow(agent: agent)
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    Text("Tap an action to send a job.")
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Machine switcher — only shown when multiple machines exist
        if machines.count > 1 {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(machines) { machine in
                        Button {
                            activeMachineID = machine.id
                            Task { await loadMachineContent(machineID: machine.id) }
                        } label: {
                            Label(machine.name, systemImage: machine.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(activeMachine?.name ?? "Ask")
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } description: {
            Text("Open Ask on your Mac to get started.\nBoth devices must be signed into the same iCloud account.")
        } actions: {
            Button("Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Data

    private func load() async {
        do {
            machines = try await cloudKit.fetchMachines()
        } catch {
            print("[HomeView] Failed to fetch machines: \(error)")
        }
        if let machine = activeMachine {
            await loadMachineContent(machineID: machine.id)
        }
        hasLoaded = true
    }

    private func loadMachineContent(machineID: String) async {
        async let sessionsFetch = cloudKit.fetchSessions(machineID: machineID)
        async let agentsFetch = cloudKit.fetchAgents(machineID: machineID)
        async let eventsFetch = cloudKit.fetchPendingEvents(machineID: machineID)
        sessions = (try? await sessionsFetch) ?? sessions
        agents = (try? await agentsFetch) ?? agents
        pendingEvents = (try? await eventsFetch) ?? pendingEvents
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                if let machine = activeMachine {
                    await loadMachineContent(machineID: machine.id)
                }
            }
        }
    }

    private func respond(to event: AskEvent, choice: String) async {
        do {
            try await cloudKit.saveResponse(eventID: event.id, machineID: event.machineID, choice: choice)
            try? await cloudKit.deleteEvent(event)
            pendingEvents.removeAll { $0.id == event.id }
        } catch {
            print("[HomeView] Failed to save response: \(error)")
        }
    }
}

// MARK: - Machine status row

struct MachineStatusRow: View {
    let machine: AskMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name)
                    .font(.subheadline)
                Text(machine.lastHeartbeat.briefRelative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(machine.connectionStatus.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch machine.connectionStatus {
        case .online:   .green
        case .busy:     .blue
        case .sleeping: .yellow
        case .offline:  .secondary
        }
    }
}

// MARK: - Settings sheet

struct SettingsSheetView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var machines: [AskMachine] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Machines") {
                    ForEach(machines) { machine in
                        NavigationLink {
                            MachineDetailView(machine: machine)
                                .environment(cloudKit)
                        } label: {
                            MachineRow(machine: machine)
                        }
                    }
                }

                if let machine = machines.first {
                    Section {
                        NavigationLink {
                            MessagesView(machine: machine)
                                .environment(cloudKit)
                        } label: {
                            Label("Messages", systemImage: "message")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                machines = (try? await cloudKit.fetchMachines()) ?? []
            }
        }
    }
}

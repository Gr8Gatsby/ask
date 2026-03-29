import SwiftUI

struct HomeView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var machines: [AskMachine] = []
    @State private var blocks: [RKBlock] = []

    @State private var hasLoaded = false
    @State private var activeMachineID: String?
    @State private var showSettings = false
    @State private var pollTask: Task<Void, Never>?

    private var activeMachine: AskMachine? {
        if let id = activeMachineID { return machines.first { $0.id == id } }
        return machines.sorted { $0.lastHeartbeat > $1.lastHeartbeat }.first
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

            // Active blocks from scripts
            if !blocks.isEmpty {
                Section {
                    ForEach(blocks) { block in
                        BlockView(block: block) { value in
                            await respondToBlock(block, value: value)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        if blocks.contains(where: { $0.requiresResponse }) {
                            Text("Needs Input")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Claude Code")
                        }
                    }
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
                            Task {
                                blocks = (try? await cloudKit.fetchBlocks(machineID: machine.id)) ?? blocks
                            }
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

        ToolbarItem(placement: .cancellationAction) {
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
            blocks = (try? await cloudKit.fetchBlocks(machineID: machine.id)) ?? blocks
        }
        hasLoaded = true
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                if let fresh = try? await cloudKit.fetchMachines(), !fresh.isEmpty {
                    machines = fresh
                }
                if let machine = activeMachine {
                    blocks = (try? await cloudKit.fetchBlocks(machineID: machine.id)) ?? blocks
                }
            }
        }
    }

    private func respondToBlock(_ block: RKBlock, value: String) async {
        do {
            try await cloudKit.postResponse(
                blockID: block.id,
                machineID: block.machineID,
                scriptID: block.scriptID,
                value: value
            )
            withAnimation { blocks.removeAll { $0.id == block.id } }
        } catch {
            print("[HomeView] Failed to post block response: \(error)")
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

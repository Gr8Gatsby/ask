import SwiftUI

struct MachinesView: View {
    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var machines: [AskMachine] = []
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && machines.isEmpty {
                    ProgressView("Loading machines…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if machines.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error?.localizedDescription ?? "")
            }
        }
        .task {
            await cloudKit.checkAccountStatus()
            await load()
        }
    }

    // MARK: - Subviews

    private var list: some View {
        List(machines) { machine in
            NavigationLink(value: machine.id) {
                MachineRow(machine: machine)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .navigationDestination(for: String.self) { machineID in
            if let machine = machines.first(where: { $0.id == machineID }) {
                MachineDetailView(machine: machine)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Machines", systemImage: "desktopcomputer.slash")
        } description: {
            Text("Install the Ask companion app on your Mac and complete setup to get started.")
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            machines = try await cloudKit.fetchMachines()
        } catch {
            self.error = error
        }
    }
}

// MARK: - Machine row

struct MachineRow: View {
    let machine: AskMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.body)
                HStack(spacing: 4) {
                    Image(systemName: machine.connectionStatus.systemImage)
                        .font(.caption2)
                    Text(machine.connectionStatus.label)
                        .font(.caption)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(machine.lastHeartbeat, style: .relative)
                        .font(.caption)
                }
                .foregroundStyle(statusColor(machine.connectionStatus))
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: AskMachine.ConnectionStatus) -> Color {
        switch status {
        case .online: .green
        case .busy: .blue
        case .sleeping: .yellow
        case .offline: .secondary
        }
    }
}

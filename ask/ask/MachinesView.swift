import SwiftUI

// MARK: - Machine row (used in SettingsSheetView)

struct MachineRow: View {
    let machine: AskMachine

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: machine.systemImage)
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
                    Text(machine.lastHeartbeat.briefRelative)
                        .font(.caption)
                }
                .foregroundStyle(statusColor(machine.connectionStatus))
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: AskMachine.ConnectionStatus) -> Color {
        switch status {
        case .online:   .green
        case .busy:     .blue
        case .sleeping: .yellow
        case .offline:  .secondary
        }
    }
}

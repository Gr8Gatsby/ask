import SwiftUI

struct MachineDetailView: View {
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit
    @State private var currentMachine: AskMachine

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

            Section {
                NavigationLink {
                    MessagesView(machine: currentMachine)
                        .environment(cloudKit)
                } label: {
                    Label("Messages", systemImage: "message")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(machine.name)
        .navigationBarTitleDisplayMode(.large)
        .task {
            currentMachine = (try? await cloudKit.fetchMachine(machineID: machine.id)) ?? currentMachine
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


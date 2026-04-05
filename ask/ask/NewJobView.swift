import SwiftUI

struct NewJobView: View {
    let agent: AskAgent
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var createdJob: AskJob?
    @State private var navigateToJob = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: machine.connectionStatus.systemImage)
                            .font(.caption)
                        Text(machine.name)
                            .font(.subheadline)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(machine.connectionStatus.label)
                            .font(.subheadline)
                    }
                    .foregroundStyle(connectionColor)

                    if machine.connectionStatus == .offline {
                        Text("Job will queue and run when the Mac comes back online.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !capabilityItems.isEmpty {
                Section("Capabilities") {
                    ForEach(capabilityItems, id: \.label) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            Text(item.label)
                                .font(.subheadline)
                        }
                    }
                }
            }

            Section("Prompt") {
                TextField("What should \(agent.name) do?", text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .disabled(isSubmitting)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { Task { await submit() } }
                        .fontWeight(.semibold)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationDestination(isPresented: $navigateToJob) {
            if let job = createdJob {
                JobDetailView(initialJob: job)
                    .environment(cloudKit)
            }
        }
    }

    private func submit() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            let job = try await cloudKit.createJob(
                machineID: machine.id,
                agentID: agent.id,
                prompt: trimmed
            )
            createdJob = job
            navigateToJob = true
        } catch {
            errorMessage = "Failed to send job: \(error.localizedDescription)"
        }
        isSubmitting = false
    }

    private var connectionColor: Color {
        switch machine.connectionStatus {
        case .online:   .green
        case .busy:     .blue
        case .sleeping: .yellow
        case .offline:  .secondary
        }
    }

    private struct CapabilityItem {
        let label: String
        let icon: String
    }

    private var capabilityItems: [CapabilityItem] {
        var items: [CapabilityItem] = []
        items.append(.init(label: "Timeout: \(agent.timeout)s", icon: "clock"))
        if agent.capabilityNetwork {
            items.append(.init(label: "Network access", icon: "network"))
        }
        if agent.capabilitySubprocess {
            items.append(.init(label: "Can spawn subprocesses", icon: "terminal"))
        }
        for path in agent.capabilityReadPaths {
            items.append(.init(label: "Read: \(path)", icon: "folder"))
        }
        for path in agent.capabilityWritePaths {
            items.append(.init(label: "Write: \(path)", icon: "folder.badge.plus"))
        }
        if !agent.capabilityEnvKeys.isEmpty {
            items.append(.init(label: "\(agent.capabilityEnvKeys.count) env var(s) from Keychain", icon: "key"))
        }
        return items
    }
}

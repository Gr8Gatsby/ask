import SwiftUI

struct NewJobView: View {
    let machine: AskMachine
    let agent: AskAgent

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var isSending = false
    @State private var error: Error?
    @State private var createdJob: AskJob?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    agentHeader
                }

                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.body)
                        .disabled(isSending)
                } header: {
                    Text("Prompt")
                } footer: {
                    if machine.connectionStatus == .offline {
                        Label("Machine is offline. Job will run when it comes back online.", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Capabilities") {
                    capabilityRows
                }
            }
            .navigationTitle("New Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error?.localizedDescription ?? "")
            }
            .navigationDestination(isPresented: .constant(createdJob != nil)) {
                if let job = createdJob {
                    JobDetailView(jobID: job.id, initialJob: job)
                        .environment(cloudKit)
                }
            }
        }
    }

    // MARK: - Subviews

    private var agentHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: agent.icon ?? "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption2)
                    Text(machine.name)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var capabilityRows: some View {
        capabilityRow("Network access", value: agent.capabilityNetwork, color: .blue)
        capabilityRow("Subprocess spawning", value: agent.capabilitySubprocess, color: .purple)
        if !agent.capabilityReadPaths.isEmpty {
            ForEach(agent.capabilityReadPaths, id: \.self) { path in
                LabeledContent("Read") {
                    Text(path).font(.caption).fontDesign(.monospaced).foregroundStyle(.secondary)
                }
            }
        }
        if !agent.capabilityWritePaths.isEmpty {
            ForEach(agent.capabilityWritePaths, id: \.self) { path in
                LabeledContent("Write") {
                    Text(path).font(.caption).fontDesign(.monospaced).foregroundStyle(.secondary)
                }
            }
        }
        LabeledContent("Timeout") {
            Text("\(agent.timeout)s")
                .foregroundStyle(.secondary)
        }
    }

    private func capabilityRow(_ label: String, value: Bool, color: Color) -> some View {
        LabeledContent(label) {
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(value ? color : .secondary)
        }
    }

    // MARK: - Actions

    private func send() async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let job = try await cloudKit.createJob(
                machineID: machine.id,
                agentID: agent.id,
                prompt: trimmed
            )
            createdJob = job
        } catch {
            self.error = error
        }
    }
}

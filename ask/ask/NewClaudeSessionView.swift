import SwiftUI

struct NewClaudeSessionView: View {
    let machine: AskMachine?
    let claudeAction: AskAgent?

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var isSending = false
    @State private var error: String?

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && claudeAction != nil
            && machine != nil
            && !isSending
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let action = claudeAction, let machine = machine {
                    // Target info
                    HStack(spacing: 8) {
                        Image("claudecode")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text("\(action.name) on \(machine.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Circle()
                            .fill(machine.connectionStatus == .online ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(machine.connectionStatus.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))

                    Divider()
                } else {
                    noActionBanner
                }

                // Prompt input
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should Claude work on?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                    }
                    TextEditor(text: $prompt)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(.systemGroupedBackground))

                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                Divider()

                // Send button
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                        }
                        Text(isSending ? "Starting…" : "Start Session")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .padding()
            }
            .navigationTitle("New Claude Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - No action configured

    private var noActionBanner: some View {
        VStack(spacing: 12) {
            Image("claudecode")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .padding(.top, 32)
            Text("No Claude Action Configured")
                .font(.headline)
            Text("Add an action in Settings whose name or script contains \"claude\" to enable direct session dispatch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Send

    private func send() async {
        guard let machine = machine, let action = claudeAction else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        error = nil
        do {
            try await cloudKit.createJob(
                machineID: machine.id,
                agentID: action.id,
                prompt: trimmed
            )
            NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
            dismiss()
        } catch {
            self.error = "Failed to start session: \(error.localizedDescription)"
            isSending = false
        }
    }
}

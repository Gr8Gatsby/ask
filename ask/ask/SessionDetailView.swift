import SwiftUI

struct SessionDetailView: View {
    let session: AskSession
    let machineID: String

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var pendingEvents: [AskEvent] = []
    @State private var isLoading = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading && pendingEvents.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pendingEvents.isEmpty {
                ContentUnavailableView(
                    "No pending requests",
                    systemImage: "checkmark.circle",
                    description: Text("Claude is running. You'll be notified when input is needed.")
                )
            } else {
                List {
                    Section {
                        ForEach(pendingEvents) { event in
                            EventCard(event: event) { choice in
                                await respond(to: event, choice: choice)
                            }
                        }
                    } header: {
                        Label("Waiting for your response", systemImage: "person.fill.questionmark")
                            .foregroundStyle(.orange)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        pendingEvents = (try? await cloudKit.fetchEvents(sessionID: session.id, machineID: machineID)) ?? pendingEvents
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
    }

    private func respond(to event: AskEvent, choice: String) async {
        do {
            try await cloudKit.saveResponse(eventID: event.id, machineID: event.machineID, choice: choice)
            try? await cloudKit.deleteEvent(event)
            withAnimation {
                pendingEvents.removeAll { $0.id == event.id }
            }
            if pendingEvents.isEmpty {
                await cloudKit.updateSessionStatus(sessionID: session.id, status: "active")
                // Notify parent to refresh session list, then go back
                NotificationCenter.default.post(name: .askRefreshRequired, object: nil)
                dismiss()
            }
        } catch {
            print("[SessionDetailView] Failed to save response: \(error)")
        }
    }
}

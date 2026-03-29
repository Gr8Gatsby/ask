import SwiftUI

struct SessionDetailView: View {
    let session: AskSession
    let machineID: String

    @Environment(iOSCloudKitService.self) private var cloudKit
    @Environment(\.dismiss) private var dismiss

    @State private var pendingEvents: [AskEvent] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !hasLoaded && isLoading {
                // Only show spinner on the very first load — not during background polls
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pendingEvents.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: session.status.isWaiting ? "clock.fill" : "bolt.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(session.status.isWaiting ? Color.orange : Color.green)
                    Text(session.status.isWaiting ? "Waiting…" : "Running")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(session.status.isWaiting
                         ? "A response may still be incoming."
                         : "Claude is working. You'll be notified when input is needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
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
        defer {
            isLoading = false
            hasLoaded = true
        }
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

import SwiftUI
import UIKit
import CloudKit

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
                if cloudKit.accountStatus == .noAccount || cloudKit.accountStatus == .restricted {
                    iCloudSignInState
                } else if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if machines.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationBarTitleDisplayMode(.inline)
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
            // Active blocks from scripts
            if !blocks.isEmpty {
                Section {
                    ForEach(blocks) { block in
                        BlockView(block: block) { value in
                            await respondToBlock(block, value: value)
                        }
                        .transition(.opacity)
                    }
                } header: {
                    Image("claudecode")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(activeMachine.map { "Ask \($0.name)" } ?? "Ask")
                .font(.custom("PlaywriteNGModern-Regular", size: 22))
        }
        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }
        ToolbarItem(placement: .bottomBar) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
    }

    // MARK: - iCloud sign-in required

    private var iCloudSignInState: some View {
        ContentUnavailableView {
            Label("Sign in to iCloud", systemImage: "icloud")
        } description: {
            Text("Sign into your Apple iCloud account to automatically discover devices.\n\nGo to Settings → [your name] → iCloud.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
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
            if let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                withAnimation(.easeOut(duration: 0.25)) { blocks = fresh.filter { $0.blockType != .alert } }
            }
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
                    if let fresh = try? await cloudKit.fetchBlocks(machineID: machine.id) {
                        withAnimation(.easeOut(duration: 0.25)) { blocks = fresh.filter { $0.blockType != .alert } }
                    }
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
            // Don't remove the block locally — let the server clear it and the next
            // poll will update the list. This avoids a jarring immediate redraw.
        } catch {
            print("[HomeView] Failed to post block response: \(error)")
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

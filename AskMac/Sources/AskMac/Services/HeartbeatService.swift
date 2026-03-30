import Foundation
import Observation

/// Keeps the Machine record in CloudKit alive with a heartbeat every 30 seconds.
/// Also publishes configured agents to CloudKit so the iOS app can discover them.
@Observable
final class HeartbeatService {
    private let cloudKit: CloudKitService
    private let settings: AppSettings

    private var task: Task<Void, Never>?
    private(set) var lastHeartbeat: Date?
    private(set) var error: Error?
    private(set) var connectedDevices: [DeviceRecord] = []

    static let interval: TimeInterval = 30

    init(cloudKit: CloudKitService, settings: AppSettings) {
        self.cloudKit = cloudKit
        self.settings = settings
    }

    func start() {
        guard task == nil else { return }
        task = Task {
            // Beat immediately on start, then on interval
            await beat()
            for await _ in AsyncTimerSequence(interval: Self.interval) {
                guard !Task.isCancelled else { return }
                await beat()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func markBusy(jobID: String) async {
        var machine = makeMachineRecord(status: .busy)
        machine.activeJobID = jobID
        try? await cloudKit.saveMachine(machine)
    }

    func markIdle() async {
        let machine = makeMachineRecord(status: .idle)
        try? await cloudKit.saveMachine(machine)
    }

    // MARK: - Private

    private func beat() async {
        do {
            try await cloudKit.saveMachine(makeMachineRecord(status: .idle))
            try await syncAgents()
            await refreshDevices()
            lastHeartbeat = Date()
            error = nil
        } catch {
            self.error = error
        }
    }

    func revokeDevice(_ device: DeviceRecord) {
        settings.blockDevice(id: device.deviceID, name: device.deviceName)
        connectedDevices.removeAll { $0.deviceID == device.deviceID }
        Task { try? await cloudKit.deleteDevice(recordName: device.recordName) }
    }

    private func refreshDevices() async {
        guard let devices = try? await cloudKit.fetchDevices(machineID: settings.machineID) else { return }
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour
        let blocked = settings.blockedDeviceIDs
        var visible: [DeviceRecord] = []

        for device in devices {
            if blocked.contains(device.deviceID) {
                Task { try? await cloudKit.deleteDevice(recordName: device.recordName) }
            } else if device.lastSeen > cutoff {
                visible.append(device)
            }
        }

        connectedDevices = visible.sorted { $0.deviceName < $1.deviceName }
    }

    private func makeMachineRecord(status: MachineStatus) -> MachineRecord {
        MachineRecord(
            machineID: settings.machineID,
            name: settings.machineName.isEmpty ? "My Mac" : settings.machineName,
            status: status
        )
    }

    /// Publishes all locally configured agents to CloudKit.
    private func syncAgents() async throws {
        for agentConfig in settings.agents {
            let record = agentConfig.toAgentRecord(machineID: settings.machineID)
            try await cloudKit.saveAgent(record)
        }
    }
}

// MARK: - Simple async timer

struct AsyncTimerSequence: AsyncSequence {
    typealias Element = Date

    let interval: TimeInterval

    struct AsyncIterator: AsyncIteratorProtocol {
        let interval: TimeInterval

        mutating func next() async -> Date? {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return nil }
            return Date()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(interval: interval)
    }
}

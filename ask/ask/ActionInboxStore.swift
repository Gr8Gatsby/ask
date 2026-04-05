import Foundation
import Observation

@Observable
final class ActionInboxStore {
    private(set) var machineID: String?
    private(set) var groups: [ActionInboxGroup] = []

    var hasItems: Bool { !groups.isEmpty }

    func replace(machineID: String?, blocks: [RKBlock]) {
        self.machineID = machineID

        let notifications = blocks.filter(\.showsInInbox)
        let grouped = Dictionary(grouping: notifications, by: \.scriptID)

        groups = grouped.values.compactMap { blocks in
            guard let newest = blocks.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return ActionInboxGroup(
                scriptID: newest.scriptID,
                scriptName: newest.scriptName ?? newest.scriptID,
                scriptIcon: newest.scriptIcon,
                scriptIconData: newest.scriptIconData,
                title: newest.inboxTitle,
                count: blocks.count,
                createdAt: newest.createdAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.scriptName.localizedCaseInsensitiveCompare(rhs.scriptName) == .orderedAscending
        }
    }

    func clear() {
        replace(machineID: nil, blocks: [])
    }
}

struct ActionInboxGroup: Identifiable, Equatable {
    let scriptID: String
    let scriptName: String
    let scriptIcon: String?
    let scriptIconData: String?
    let title: String
    let count: Int
    let createdAt: Date

    var id: String { scriptID }
}

private extension RKBlock {
    var inboxTitle: String {
        switch blockType {
        case .confirmation:
            return confirmationPayload?.title ?? (scriptName ?? scriptID)
        case .prompt:
            return promptPayload?.title ?? (scriptName ?? scriptID)
        case .chatPrompt:
            return chatPromptPayload?.title ?? (scriptName ?? scriptID)
        case .picker:
            return pickerPayload?.title ?? (scriptName ?? scriptID)
        case .list:
            return listPayload?.title ?? (scriptName ?? scriptID)
        case .detail:
            return detailPayload?.title ?? (scriptName ?? scriptID)
        case .tile:
            return tilePayload?.label ?? (scriptName ?? scriptID)
        default:
            return scriptName ?? scriptID
        }
    }
}

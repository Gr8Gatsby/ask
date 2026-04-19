import SwiftUI

// MARK: - Block preview dispatcher

/// Mac-side rendering of a single LiveBlock.
struct BlockPreviewView: View {
    let block: LiveBlock
    var onRespond: ((String) -> Void)? = nil

    private var payload: [String: Any] {
        guard let data = block.payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    var body: some View {
        Group {
            switch block.blockType {
            case "confirmation":  ConfirmationPreview(payload: payload, onRespond: onRespond)
            case "status":        StatusPreview(payload: payload)
            case "info_card":     InfoCardPreview(payload: payload)
            case "alert":         AlertPreview(payload: payload)
            case "prompt":        PromptPreview(payload: payload, onRespond: onRespond)
            case "chat_prompt":   ChatPromptPreview(payload: payload, onRespond: onRespond)
            case "countdown":     CountdownPreview(payload: payload)
            case "list":          ListPreview(payload: payload, onRespond: onRespond)
            case "detail":        DetailPreview(payload: payload, onRespond: onRespond)
            case "picker":        PickerPreview(payload: payload, onRespond: onRespond)
            case "icon_card":     IconCardPreview(payload: payload)
            case "claude_message": ClaudeMessagePreview(payload: payload)
            case "agent_session": AgentSessionPreview(payload: payload, onRespond: onRespond)
            case "start_session": StartSessionPreview(payload: payload, onRespond: onRespond)
            case "feed_item":     FeedItemPreview(payload: payload)
            case "diagnostics":   DiagnosticsPreview(payload: payload, onRespond: onRespond)
            case "tile":          EmptyView() // drives home-screen tile only
            default:              EmptyView()
            }
        }
    }
}

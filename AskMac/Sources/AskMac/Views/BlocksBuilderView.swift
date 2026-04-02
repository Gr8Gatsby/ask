import SwiftUI

// MARK: - Block builder model

struct BuilderBlock: Identifiable {
    let id = UUID()
    var blockType: String
    var payload: [String: Any]

    var liveBlock: LiveBlock {
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LiveBlock(id: id.uuidString, blockType: blockType, payloadJSON: json)
    }
}

// MARK: - Block type catalog

struct BlockTypeInfo: Identifiable {
    let id: String          // block_type value
    let name: String
    let description: String
    let icon: String        // SF Symbol
    let category: Category
    let defaultPayload: [String: Any]

    enum Category: String, CaseIterable {
        case interactive   = "Interactive"
        case informational = "Informational"
        case ai            = "AI & Sessions"
    }
}

private let blockCatalog: [BlockTypeInfo] = [
    // Interactive
    BlockTypeInfo(
        id: "confirmation",
        name: "Confirmation",
        description: "Yes/No prompt with custom options",
        icon: "checkmark.square",
        category: .interactive,
        defaultPayload: [
            "title": "Confirm Action",
            "body": "Are you sure you want to proceed?",
            "options": ["Confirm", "Cancel"]
        ]
    ),
    BlockTypeInfo(
        id: "prompt",
        name: "Prompt",
        description: "Free-text input field",
        icon: "text.cursor",
        category: .interactive,
        defaultPayload: [
            "title": "Enter a value",
            "context": "Provide your input below.",
            "placeholder": "Type here…"
        ]
    ),
    BlockTypeInfo(
        id: "picker",
        name: "Picker",
        description: "Dropdown selection from options",
        icon: "list.bullet.indent",
        category: .interactive,
        defaultPayload: [
            "title": "Choose an option",
            "options": ["Option A", "Option B", "Option C"],
            "selected": "Option A"
        ]
    ),
    BlockTypeInfo(
        id: "list",
        name: "List",
        description: "Tappable rows with optional actions",
        icon: "list.bullet",
        category: .interactive,
        defaultPayload: [
            "title": "Select an item",
            "items": [
                ["id": "1", "label": "First Item", "subtitle": "Subtitle text"],
                ["id": "2", "label": "Second Item", "subtitle": "Another subtitle"],
                ["id": "3", "label": "Third Item"]
            ],
            "actions": ["Cancel"]
        ]
    ),
    // Informational
    BlockTypeInfo(
        id: "status",
        name: "Status",
        description: "Colored status with icon and detail",
        icon: "circle.fill",
        category: .informational,
        defaultPayload: [
            "icon": "checkmark.circle.fill",
            "label": "All systems running",
            "detail": "Last checked 30 seconds ago",
            "color": "green"
        ]
    ),
    BlockTypeInfo(
        id: "info_card",
        name: "Info Card",
        description: "Key/value pairs table",
        icon: "info.circle",
        category: .informational,
        defaultPayload: [
            "title": "System Info",
            "pairs": [
                ["key": "Version", "value": "2.1.0"],
                ["key": "Status", "value": "Active"],
                ["key": "Region", "value": "us-east-1"]
            ]
        ]
    ),
    BlockTypeInfo(
        id: "alert",
        name: "Alert",
        description: "Warning or error message",
        icon: "exclamationmark.triangle",
        category: .informational,
        defaultPayload: [
            "icon": "exclamationmark.triangle",
            "title": "Attention Required",
            "body": "Something needs your attention before proceeding."
        ]
    ),
    BlockTypeInfo(
        id: "detail",
        name: "Detail",
        description: "Long-form content with action buttons",
        icon: "doc.text",
        category: .informational,
        defaultPayload: [
            "title": "Detail View",
            "body": "This is a longer description providing context about the current situation. It can span multiple lines.",
            "actions": ["Acknowledge", "Dismiss"]
        ]
    ),
    BlockTypeInfo(
        id: "countdown",
        name: "Countdown",
        description: "Relative timer display",
        icon: "clock",
        category: .informational,
        defaultPayload: [
            "label": "Next scheduled run",
            "time": ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        ]
    ),
    BlockTypeInfo(
        id: "icon_card",
        name: "Icon Card",
        description: "Title and subtitle with icon",
        icon: "rectangle.stack",
        category: .informational,
        defaultPayload: [
            "title": "Card Title",
            "subtitle": "Supporting subtitle text"
        ]
    ),
    // AI & Sessions
    BlockTypeInfo(
        id: "agent_session",
        name: "Agent Session",
        description: "Live AI agent with reply input",
        icon: "cpu",
        category: .ai,
        defaultPayload: [
            "agent_name": "Claude",
            "is_working": true,
            "last_message": "Analyzing the codebase and preparing changes…",
            "placeholder": "Reply to Claude…",
            "brand_color": "#CA7C5E",
            "project": "my-project"
        ]
    ),
    BlockTypeInfo(
        id: "claude_message",
        name: "Claude Message",
        description: "A message from Claude Code",
        icon: "bubble.left",
        category: .ai,
        defaultPayload: [
            "text": "I've finished the refactor. All tests pass. Ready to commit?"
        ]
    ),
    BlockTypeInfo(
        id: "start_session",
        name: "Start Session",
        description: "New agent session launcher",
        icon: "plus.circle",
        category: .ai,
        defaultPayload: [
            "repos": [
                ["name": "my-project", "path": "~/code/my-project"],
                ["name": "backend-api", "path": "~/code/backend-api"]
            ]
        ]
    ),
    BlockTypeInfo(
        id: "tile",
        name: "Tile",
        description: "Home screen tile (iOS only)",
        icon: "square.grid.2x2",
        category: .ai,
        defaultPayload: [
            "label": "All good",
            "status_color": "green",
            "body": "Everything is running smoothly",
            "action_required": false
        ]
    ),
]

// MARK: - Blocks builder view

struct BlocksBuilderView: View {
    @State private var blocks: [BuilderBlock] = []
    @State private var showJSON = true

    var body: some View {
        NavigationSplitView {
            BlockPalette { info in
                blocks.append(BuilderBlock(blockType: info.id, payload: info.defaultPayload))
            }
        } detail: {
            if blocks.isEmpty {
                emptyState
            } else {
                if showJSON {
                    HSplitView {
                        previewCanvas
                            .frame(minWidth: 320)
                        JSONPanel(blocks: blocks)
                            .frame(minWidth: 260)
                    }
                } else {
                    previewCanvas
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { blocks.removeAll() } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .disabled(blocks.isEmpty)
                .help("Remove all blocks from the canvas")
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showJSON) {
                    Label("JSON", systemImage: "curlybraces")
                }
                .toggleStyle(.button)
                .help("Toggle JSON panel")
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Block Canvas", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Choose a block type from the sidebar to add it to the canvas.")
        }
    }

    // MARK: Preview canvas

    private var previewCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    BlockCanvasCard(block: block) {
                        blocks.remove(at: index)
                    } onMoveUp: {
                        guard index > 0 else { return }
                        blocks.swapAt(index, index - 1)
                    } onMoveDown: {
                        guard index < blocks.count - 1 else { return }
                        blocks.swapAt(index, index + 1)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Block canvas card

private struct BlockCanvasCard: View {
    let block: BuilderBlock
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                // Type label
                Text(block.blockType)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                BlockPreviewView(block: block.liveBlock)
            }

            // Controls
            if hovered {
                HStack(spacing: 2) {
                    Button { onMoveUp() } label: {
                        Image(systemName: "chevron.up")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button { onMoveDown() } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button { onDelete() } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(6)
            }
        }
        .onHover { hovered = $0 }
    }
}

// MARK: - JSON panel

private struct JSONPanel: View {
    let blocks: [BuilderBlock]

    @State private var copied = false

    private var jsonString: String {
        let array: [[String: Any]] = blocks.map { block in
            ["block_type": block.blockType, "payload": block.payload]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("JSON")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(jsonString, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .animation(.easeInOut(duration: 0.2), value: copied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))

            Divider()

            ScrollView {
                Text(jsonString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color(.textBackgroundColor))
        }
    }
}

// MARK: - Block palette sidebar

private struct BlockPalette: View {
    let onAdd: (BlockTypeInfo) -> Void

    @State private var search = ""

    private var grouped: [(BlockTypeInfo.Category, [BlockTypeInfo])] {
        let filtered: [BlockTypeInfo] = search.isEmpty
            ? blockCatalog
            : blockCatalog.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.description.localizedCaseInsensitiveContains(search)
            }
        return BlockTypeInfo.Category.allCases.compactMap { cat in
            let items = filtered.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.0) { category, items in
                Section(category.rawValue) {
                    ForEach(items) { info in
                        BlockPaletteRow(info: info, onAdd: onAdd)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .searchable(text: $search, placement: .sidebar, prompt: "Search blocks")
    }
}

private struct BlockPaletteRow: View {
    let info: BlockTypeInfo
    let onAdd: (BlockTypeInfo) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.subheadline)
                Text(info.description)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                onAdd(info)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0.3)
            .help("Add \(info.name) block")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onAdd(info) }
    }
}

import SwiftUI

// MARK: - Block builder model

struct BuilderBlock: Identifiable {
    let id = UUID()
    var blockType: String
    var payload: [String: Any]
    let originalPayload: [String: Any]
    var lastResponse: String? = nil
    var resetToken = UUID()

    init(blockType: String, payload: [String: Any]) {
        self.blockType = blockType
        self.payload = payload
        self.originalPayload = payload
    }

    mutating func reset() {
        payload = originalPayload
        lastResponse = nil
        resetToken = UUID()
    }

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
        id: "chat_prompt",
        name: "Chat Prompt",
        description: "Conversational reply with agent context",
        icon: "bubble.left.and.text.bubble.right",
        category: .interactive,
        defaultPayload: [
            "title": "Reply to Claude…",
            "context": "I found **3 failing tests**. Should I attempt auto-fixes or open a ticket?",
            "placeholder": "Reply to Claude…"
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
    BlockTypeInfo(
        id: "detail",
        name: "Detail",
        description: "Long-form content with action buttons",
        icon: "doc.text",
        category: .interactive,
        defaultPayload: [
            "title": "Detail View",
            "body": "This is a longer description providing context about the current situation. It can span multiple lines.",
            "actions": ["Acknowledge", "Dismiss"]
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
    BlockTypeInfo(
        id: "feed_item",
        name: "Feed Item",
        description: "Entry in the iOS Feed tab",
        icon: "newspaper",
        category: .informational,
        defaultPayload: [
            "title": "Deployment complete",
            "body": "Production deployment finished successfully.",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "icon": "checkmark.circle.fill",
            "color": "green"
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
    @Binding var blocks: [BuilderBlock]
    @Binding var showJSON: Bool

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
                ForEach($blocks) { $block in
                    BlockCanvasCard(
                        block: $block,
                        onDelete: {
                            blocks.removeAll { $0.id == block.id }
                        },
                        onMoveUp: {
                            guard let i = blocks.firstIndex(where: { $0.id == block.id }), i > 0 else { return }
                            blocks.swapAt(i, i - 1)
                        },
                        onMoveDown: {
                            guard let i = blocks.firstIndex(where: { $0.id == block.id }), i < blocks.count - 1 else { return }
                            blocks.swapAt(i, i + 1)
                        }
                    )
                }
            }
            .padding(20)
        }
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Block canvas card

private struct BlockCanvasCard: View {
    @Binding var block: BuilderBlock
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var hovered = false
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row: type label + action buttons
            HStack(spacing: 4) {
                Text(block.blockType)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Spacer()

                // Action bar — unified pill with consistent icon sizes
                HStack(spacing: 0) {
                    actionBarButton(icon: "chevron.up",            tint: nil)  { onMoveUp() }
                    actionBarDivider()
                    actionBarButton(icon: "chevron.down",          tint: nil)  { onMoveDown() }
                    actionBarDivider()
                    actionBarButton(icon: "arrow.counterclockwise", tint: nil, disabled: block.lastResponse == nil) { block.reset() }
                    actionBarDivider()
                    actionBarButton(icon: "xmark",                 tint: .red) { onDelete() }
                }
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .opacity(hovered ? 1 : 0)
            }

            BlockPreviewView(block: block.liveBlock) { response in
                block.lastResponse = response
            }
            .id(block.resetToken)

            // Response footer
            if let response = block.lastResponse {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Response: \(response)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        block.lastResponse = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { isOver in
            if isOver {
                hideTask?.cancel()
                hideTask = nil
                hovered = true
            } else {
                hideTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { hovered = false }
                }
            }
        }
    }

    @ViewBuilder
    private func actionBarButton(
        icon: String,
        tint: Color?,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : (tint ?? .primary))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func actionBarDivider() -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 0.5, height: 16)
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

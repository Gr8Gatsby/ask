import SwiftUI

// MARK: - Display model

private struct DisplayMessage: Identifiable, Equatable {
    var id: String          // Matches CloudKit messageID exactly
    var text: String
    var fromMe: Bool
    var timestamp: Date
    var status: Status

    enum Status: Equatable { case sending, delivered, failed }
}

// MARK: - MacMessagesView

struct MacMessagesView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(CloudKitService.self) private var cloudKit
    @Environment(MessageWatcherService.self) private var messageWatcher

    @State private var messages: [DisplayMessage] = []
    @State private var draft = ""
    @State private var isOtherTyping = false
    @State private var pollTask: Task<Void, Never>?
    @State private var typingUpdateTask: Task<Void, Never>?
    @State private var showingClearConfirm = false
    @State private var isClearing = false

    var body: some View {
        messageList
            .overlay(alignment: .bottom) { composeBar }
            .frame(minWidth: 360, minHeight: 480)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear message history")
                    .disabled(isClearing || messages.isEmpty)
                }
            }
            .confirmationDialog("Clear all messages?",
                                isPresented: $showingClearConfirm,
                                titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    Task { await clearHistory() }
                }
            } message: {
                Text("This deletes all messages from CloudKit. Cannot be undone.")
            }
            .task {
                await load()
                startPolling()
            }
            .onDisappear {
                pollTask?.cancel()
                typingUpdateTask?.cancel()
            }
            .onChange(of: draft) { old, new in handleDraftChange(old: old, new: new) }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(messages) { msg in
                        MacMessageBubble(message: msg, isLastFromMe: isLastFromMe(msg))
                            .id(msg.id)
                    }
                    if isOtherTyping {
                        MacTypingBubble()
                            .id("typing")
                            .transition(.asymmetric(
                                insertion: .push(from: .leading).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    // Spacer so last message clears the floating compose bar
                    Color.clear.frame(height: 70).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .onChange(of: messages.count) { _, _ in scroll(proxy) }
            .onChange(of: isOtherTyping) { _, typing in if typing { scroll(proxy) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: - Floating compose bar

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composeBar: some View {
        // Single pill: text field + send button inside. No outer wrapper.
        HStack(alignment: .center, spacing: 0) {
            TextField("iMessage", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.leading, 14)
                .padding(.vertical, 9)
                .lineLimit(1...5)
                .font(.body)
                .onSubmit {
                    guard hasText else { return }
                    Task { await send() }
                }

            if hasText {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 3)
        .animation(.spring(duration: 0.25), value: hasText)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Helpers

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private func isLastFromMe(_ msg: DisplayMessage) -> Bool {
        guard msg.fromMe else { return false }
        return messages.filter(\.fromMe).last?.id == msg.id
    }

    // MARK: - Data

    /// Merges CloudKit messages into the local array without ever removing existing entries.
    /// Local messages (sending/failed) are preserved; CloudKit confirms them in place.
    private func load() async {
        guard let fetched = try? await cloudKit.fetchAllMessages(machineID: settings.machineID) else { return }

        withAnimation(.spring(duration: 0.3)) {
            var updated = messages

            for cloudMsg in fetched {
                if let idx = updated.firstIndex(where: { $0.id == cloudMsg.messageID }) {
                    // Confirm a pending message that CloudKit now has
                    if updated[idx].status == .sending {
                        updated[idx].status = .delivered
                    }
                } else {
                    // New message from the other device
                    updated.append(DisplayMessage(
                        id: cloudMsg.messageID, text: cloudMsg.text,
                        fromMe: cloudMsg.fromDevice == "mac",
                        timestamp: cloudMsg.timestamp, status: .delivered
                    ))
                }
            }

            messages = updated.sorted { $0.timestamp < $1.timestamp }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        typingUpdateTask?.cancel()
        Task { await cloudKit.clearTyping(machineID: settings.machineID, fromDevice: "mac") }

        // Pre-generate the ID so optimistic and CloudKit record share the same identity
        let messageID = UUID().uuidString
        let optimistic = DisplayMessage(id: messageID, text: text, fromMe: true,
                                        timestamp: Date(), status: .sending)
        withAnimation(.spring(duration: 0.35)) { messages.append(optimistic) }

        do {
            try await cloudKit.saveMessage(machineID: settings.machineID, text: text, messageID: messageID)
            withAnimation(.easeIn(duration: 0.2)) {
                if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[idx].status = .delivered
                }
            }
        } catch {
            // Keep message visible but mark as failed
            withAnimation {
                if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[idx].status = .failed
                }
            }
        }
    }

    private func clearHistory() async {
        isClearing = true
        try? await cloudKit.deleteAllMessages(machineID: settings.machineID)
        withAnimation { messages = [] }
        isClearing = false
    }

    // MARK: - Typing

    private func handleDraftChange(old: String, new: String) {
        let isEmpty = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        typingUpdateTask?.cancel()

        if isEmpty {
            Task { await cloudKit.clearTyping(machineID: settings.machineID, fromDevice: "mac") }
            return
        }

        // Each keystroke resets a 4s inactivity timeout
        typingUpdateTask = Task {
            try? await cloudKit.updateTyping(machineID: settings.machineID, fromDevice: "mac")
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                await cloudKit.clearTyping(machineID: settings.machineID, fromDevice: "mac")
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await load()
                await updateTypingIndicator()
            }
        }
    }

    private func updateTypingIndicator() async {
        let ts = await cloudKit.fetchTypingTimestamp(machineID: settings.machineID, fromDevice: "iphone")
        let typing = ts.map { Date().timeIntervalSince($0) < 5 } ?? false
        if typing != isOtherTyping {
            withAnimation(.spring(duration: 0.3)) { isOtherTyping = typing }
        }
    }
}

// MARK: - Message bubble

private struct MacMessageBubble: View {
    let message: DisplayMessage
    let isLastFromMe: Bool

    @State private var showStatus = false

    var body: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
            HStack {
                if message.fromMe { Spacer(minLength: 60) }
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .foregroundStyle(message.fromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                if !message.fromMe { Spacer(minLength: 60) }
            }
            if message.fromMe && isLastFromMe && showStatus {
                statusLabel
                    .padding(.trailing, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.vertical, 1)
        .onChange(of: message.status) { _, new in onStatusChange(new) }
        .onAppear {
            switch message.status {
            case .sending, .failed: showStatus = true
            case .delivered: break
            }
        }
    }

    private var bubbleColor: Color {
        switch message.status {
        case .sending: Color.accentColor.opacity(0.5)
        case .delivered: message.fromMe ? Color.accentColor : Color(.controlBackgroundColor)
        case .failed: Color.red.opacity(0.65)
        }
    }

    private func onStatusChange(_ new: DisplayMessage.Status) {
        switch new {
        case .sending:
            showStatus = true
        case .delivered:
            withAnimation(.easeIn(duration: 0.2)) { showStatus = true }
            Task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeOut(duration: 0.4)) { showStatus = false }
            }
        case .failed:
            withAnimation { showStatus = true }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch message.status {
        case .sending:
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("Sending")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .delivered:
            Text("Delivered")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Not delivered")
            }
            .font(.caption2)
            .foregroundStyle(.red)
        }
    }
}

// MARK: - Typing indicator

private struct MacTypingBubble: View {
    @State private var activeIndex = 0

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 7, height: 7)
                        .scaleEffect(activeIndex == i ? 1.3 : 0.8)
                        .opacity(activeIndex == i ? 1.0 : 0.45)
                        .animation(.easeInOut(duration: 0.25), value: activeIndex)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 60)
        }
        .padding(.vertical, 1)
        .task {
            while !Task.isCancelled {
                for i in 0..<3 {
                    activeIndex = i
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                }
            }
        }
    }
}

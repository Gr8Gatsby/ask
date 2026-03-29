import SwiftUI

// MARK: - Display model

private struct DisplayMessage: Identifiable, Equatable {
    var id: String          // Matches CloudKit messageID exactly
    var text: String
    var fromMe: Bool
    var timestamp: Date
    var status: Status

    enum Status: Equatable { case sending, delivered, failed }

    /// Message received from CloudKit (already delivered)
    init(message: AskMessage) {
        id = message.id
        text = message.text
        fromMe = message.fromIPhone
        timestamp = message.timestamp
        status = .delivered
    }

    /// Optimistic outbound message — caller must supply the pre-generated ID
    init(id: String, text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        fromMe = true
        self.timestamp = timestamp
        status = .sending
    }
}

// MARK: - MessagesView

struct MessagesView: View {
    let machine: AskMachine

    @Environment(iOSCloudKitService.self) private var cloudKit

    @State private var messages: [DisplayMessage] = []
    @State private var draft = ""
    @State private var isOtherTyping = false
    @State private var pollTask: Task<Void, Never>?
    @State private var typingUpdateTask: Task<Void, Never>?

    var body: some View {
        messageList
            .overlay(alignment: .bottom) { composeBar }
            .navigationTitle(machine.name)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground))
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
                        MessageBubble(message: msg, isLastFromMe: isLastFromMe(msg))
                            .id(msg.id)
                    }
                    if isOtherTyping {
                        TypingBubble()
                            .id("typing")
                            .transition(.asymmetric(
                                insertion: .push(from: .leading).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    // Spacer so last message clears the floating compose bar
                    Color.clear.frame(height: 100).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
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
        HStack(alignment: .center, spacing: 0) {
            TextField("iMessage", text: $draft, axis: .vertical)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .lineLimit(1...5)
                .font(.body)
                .submitLabel(.send)
                .onSubmit { Task { await send() } }

            if hasText {
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        // iOS 26 liquid glass — translucent, reflective, adapts to background
        .glassEffect(in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 4)
        .animation(.spring(duration: 0.25), value: hasText)
        .padding(.horizontal, 16)
        // 36pt bottom: safe area handles home indicator, +extra breathing room
        .padding(.bottom, 36)
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
        let fetched = (try? await cloudKit.fetchMessages(machineID: machine.id)) ?? []

        withAnimation(.spring(duration: 0.3)) {
            var updated = messages

            for cloudMsg in fetched {
                if let idx = updated.firstIndex(where: { $0.id == cloudMsg.id }) {
                    // Confirm a pending message that CloudKit has now saved
                    if updated[idx].status == .sending {
                        updated[idx].status = .delivered
                    }
                } else {
                    // New message from the other device
                    updated.append(DisplayMessage(message: cloudMsg))
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
        Task { await cloudKit.clearTyping(machineID: machine.id) }

        // Pre-generate the ID so optimistic and CloudKit record share the same identity
        let messageID = UUID().uuidString
        let optimistic = DisplayMessage(id: messageID, text: text)
        withAnimation(.spring(duration: 0.35)) { messages.append(optimistic) }

        do {
            try await cloudKit.sendMessage(machineID: machine.id, text: text, messageID: messageID)
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

    // MARK: - Typing

    private func handleDraftChange(old: String, new: String) {
        let isEmpty = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        typingUpdateTask?.cancel()

        if isEmpty {
            Task { await cloudKit.clearTyping(machineID: machine.id) }
            return
        }

        // Each keystroke resets a 4s inactivity timeout
        typingUpdateTask = Task {
            try? await cloudKit.updateTyping(machineID: machine.id)
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                await cloudKit.clearTyping(machineID: machine.id)
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
        let ts = await cloudKit.fetchMacTypingTimestamp(machineID: machine.id)
        let typing = ts.map { Date().timeIntervalSince($0) < 5 } ?? false
        if typing != isOtherTyping {
            withAnimation(.spring(duration: 0.3)) { isOtherTyping = typing }
        }
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: DisplayMessage
    let isLastFromMe: Bool

    @State private var showStatus = false

    var body: some View {
        VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 2) {
            HStack {
                if message.fromMe { Spacer(minLength: 60) }
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleColor)
                    .foregroundStyle(message.fromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                if !message.fromMe { Spacer(minLength: 60) }
            }
            if message.fromMe && isLastFromMe && showStatus {
                statusLabel
                    .padding(.trailing, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.vertical, 1)
        .onChange(of: message.status) { _, new in onStatusChange(new) }
        .onAppear {
            // Show status immediately for sending/failed; delivered only if very recent
            switch message.status {
            case .sending, .failed: showStatus = true
            case .delivered: break
            }
        }
    }

    private var bubbleColor: Color {
        switch message.status {
        case .sending: Color.blue.opacity(0.6)
        case .delivered: message.fromMe ? Color.blue : Color(.systemGray5)
        case .failed: Color.red.opacity(0.7)
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

private struct TypingBubble: View {
    @State private var activeIndex = 0

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color(.systemGray3))
                        .frame(width: 8, height: 8)
                        .scaleEffect(activeIndex == i ? 1.25 : 0.8)
                        .opacity(activeIndex == i ? 1.0 : 0.45)
                        .animation(.easeInOut(duration: 0.25), value: activeIndex)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 18))
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

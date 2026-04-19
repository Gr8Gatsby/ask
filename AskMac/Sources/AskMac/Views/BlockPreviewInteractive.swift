import SwiftUI

// MARK: - Confirmation

struct ConfirmationPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var responded: String? = nil

    private var options: [String] {
        payload["options"] as? [String] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if let body = payload["body"] as? String, !body.isEmpty {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if let r = responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            } else if options.count <= 2 {
                // Horizontal buttons — first option is accent-colored
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Button(opt) {
                            responded = opt
                            onRespond?(opt)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(idx == 0 ? .accentColor : Color(.tertiaryLabelColor))
                        .disabled(onRespond == nil)
                        .accessibilityIdentifier("confirm-option-\(opt)")
                    }
                    Spacer()
                }
            } else {
                // Radio list for 3+ options
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Button {
                            responded = opt
                            onRespond?(opt)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(opt).font(.caption).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onRespond == nil)
                        .accessibilityIdentifier("confirm-option-\(opt)")
                        if idx < options.count - 1 {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .blockCard()
    }
}

// MARK: - Prompt

struct PromptPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var text = ""
    @State private var responded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            } else if let respond = onRespond {
                let isMultiline = payload["multiline"] as? Bool ?? false
                if isMultiline {
                    TextEditor(text: $text)
                        .font(.caption)
                        .frame(minHeight: 60, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    TextField(
                        (payload["placeholder"] as? String) ?? "Type a response…",
                        text: $text
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                HStack {
                    Spacer()
                    Button {
                        guard !text.isEmpty else { return }
                        respond(text)
                        responded = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            } else {
                Text((payload["placeholder"] as? String) ?? "Type a response…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .blockCard()
    }
}

// MARK: - Chat Prompt

struct ChatPromptPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var text = ""
    @State private var responded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Agent context bubble
            if let context = payload["context"] as? String, !context.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ClaudeBrandHeader()
                    markdownText(context)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            } else if let respond = onRespond {
                HStack(spacing: 6) {
                    TextField(
                        (payload["placeholder"] as? String) ?? "Reply to Claude…",
                        text: $text
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        guard !text.isEmpty else { return }
                        respond(text); responded = true
                    }
                    Button {
                        guard !text.isEmpty else { return }
                        respond(text); responded = true
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(text.isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty)
                }
            } else {
                Text((payload["placeholder"] as? String) ?? "Reply to Claude…")
                    .font(.caption2).foregroundStyle(.tertiary).italic()
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .blockCard()
    }
}

// MARK: - Picker

struct PickerPreview: View {
    let payload: [String: Any]
    var onRespond: ((String) -> Void)?

    @State private var selected: String = ""
    @State private var responded = false

    private var options: [String] { payload["options"] as? [String] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
            }
            if responded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    Text(selected).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Picker("", selection: $selected) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(onRespond == nil)
                    Spacer()
                    if let respond = onRespond {
                        Button("Select") {
                            guard !selected.isEmpty else { return }
                            respond(selected)
                            responded = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .blockCard()
        .onAppear {
            if selected.isEmpty {
                selected = (payload["selected"] as? String) ?? options.first ?? ""
            }
        }
    }
}

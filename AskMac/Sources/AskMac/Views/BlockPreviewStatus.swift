import SwiftUI

// MARK: - Status

struct StatusPreview: View {
    let payload: [String: Any]

    var body: some View {
        let color = statusColor(payload)
        HStack(spacing: 8) {
            if let icon = payload["icon"] as? String {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String {
                    Text(label).font(.caption).foregroundStyle(color)
                }
                if let detail = payload["detail"] as? String {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Alert

struct AlertPreview: View {
    let payload: [String: Any]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: (payload["icon"] as? String) ?? "bell.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                if let title = payload["title"] as? String, !title.isEmpty {
                    Text(title).font(.caption).fontWeight(.medium)
                        .accessibilityIdentifier("alert-title")
                }
                if let body = payload["body"] as? String, !body.isEmpty {
                    Text(body).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                        .accessibilityIdentifier("alert-body")
                }
            }
            Spacer()
        }
        .blockCard(background: Color.orange.opacity(0.08))
    }
}

// MARK: - Info Card

struct InfoCardPreview: View {
    let payload: [String: Any]

    private var pairs: [(key: String, value: String)] {
        guard let raw = payload["pairs"] as? [[String: String]] else { return [] }
        return raw.compactMap { d in
            guard let k = d["key"], let v = d["value"] else { return nil }
            return (k, v)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = payload["title"] as? String, !title.isEmpty {
                Text(title).font(.subheadline).fontWeight(.medium)
                Divider()
            }
            ForEach(pairs, id: \.key) { pair in
                HStack(alignment: .top) {
                    Text(pair.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(pair.value)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
        .blockCard()
    }
}

// MARK: - Countdown

struct CountdownPreview: View {
    let payload: [String: Any]

    private var targetDate: Date? {
        guard let str = payload["time"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: str)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let label = payload["label"] as? String {
                    Text(label).font(.caption).fontWeight(.medium)
                }
                if let date = targetDate {
                    if date > Date() {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Overdue")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .blockCard()
    }
}

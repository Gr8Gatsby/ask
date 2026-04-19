import SwiftUI

// MARK: - Shared helpers

/// Parse a hex string like "#CA7C5E" or "CA7C5E" into a Color.
func hexColor(_ hex: String?) -> Color? {
    guard let hex else { return nil }
    let cleaned = hex.trimmingCharacters(in: .init(charactersIn: "#"))
    guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
    return Color(
        red:   Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8)  & 0xFF) / 255,
        blue:  Double(value         & 0xFF) / 255
    )
}

/// Render markdown inline formatting via AttributedString (bold, italic, code, links).
func markdownText(_ string: String) -> Text {
    if let attr = try? AttributedString(markdown: string) {
        return Text(attr)
    }
    return Text(string)
}

/// Status color from the "color" payload field.
func statusColor(_ payload: [String: Any]) -> Color {
    switch payload["color"] as? String {
    case "green":  return .green
    case "red":    return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "blue":   return .blue
    default:       return .secondary
    }
}

/// Claude Code branding header — small dot + "Claude Code" label.
struct ClaudeBrandHeader: View {
    var label: String = "Claude Code"
    var color: Color = Color(red: 0.79, green: 0.49, blue: 0.37)

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(
                    Text("C")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                )
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Card container modifier

extension View {
    func blockCard(background: Color = Color.secondary.opacity(0.07)) -> some View {
        self
            .padding(8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

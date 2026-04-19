#if canImport(AskMacCore)
import AskMacCore
#endif
import AppKit
import SwiftUI

// MARK: - Copy Button

struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy path")
    }
}

// MARK: - SVG dark-mode helper

/// Rewrites dark/black fill and stroke values to white so an SVG icon
/// renders legibly on dark brand card backgrounds.
func svgToWhite(_ svg: String) -> NSImage? {
    var s = svg
    s = s.replacingOccurrences(of: "currentColor", with: "white", options: .caseInsensitive)
    let darkColors = ["#000000", "#000", "black", "#111111", "#111",
                      "#1a1a1a", "#222222", "#222", "#333333", "#333"]
    for color in darkColors {
        for attr in ["fill", "stroke"] {
            s = s.replacingOccurrences(of: "\(attr)=\"\(color)\"", with: "\(attr)=\"white\"", options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr)='\(color)'",  with: "\(attr)='white'",  options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr):\(color)",    with: "\(attr):white",    options: .caseInsensitive)
            s = s.replacingOccurrences(of: "\(attr): \(color)",   with: "\(attr): white",   options: .caseInsensitive)
        }
    }
    guard let data = s.data(using: .utf8) else { return nil }
    return NSImage(data: data)
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
            Int((c.redComponent   * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent  * 255).rounded()))
    }
}

func blockStatusColor(_ colorString: String?) -> Color {
    switch colorString {
    case "green":  .green
    case "blue":   .blue
    case "orange": .orange
    case "red":    .red
    case "yellow": .yellow
    default:       .secondary
    }
}

// MARK: - Relative time (single most-significant unit)

func simpleRelativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(-date.timeIntervalSinceNow))
    if seconds < 60  { return "< 1 min" }
    let minutes = seconds / 60
    if minutes < 60  { return "\(minutes) min" }
    let hours = minutes / 60
    if hours   < 24  { return "\(hours) hr" }
    let days   = hours / 24
    if days    < 30  { return "\(days) day\(days == 1 ? "" : "s")" }
    let months = days / 30
    if months  < 12  { return "\(months) mo" }
    return "\(months / 12) yr"
}

// MARK: - Simple Markdown renderer

enum MDBlock {
    case heading(level: Int, text: String)
    case code(String)
    case paragraph(String)
}

func parseMarkdownBlocks(_ raw: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines  = raw.components(separatedBy: "\n")
    var i      = 0
    while i < lines.count {
        let line = lines[i]
        // Heading: 1–6 # characters followed by a space
        let hashes = line.prefix(while: { $0 == "#" })
        let level  = hashes.count
        if level >= 1 && level <= 6 && line.count > level,
           line[line.index(line.startIndex, offsetBy: level)] == " " {
            blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
            i += 1
            continue
        }
        // Fenced code block
        if line.hasPrefix("```") {
            var code = ""
            i += 1
            while i < lines.count && !lines[i].hasPrefix("```") {
                if !code.isEmpty { code += "\n" }
                code += lines[i]
                i += 1
            }
            i += 1 // skip closing ```
            if !code.isEmpty { blocks.append(.code(code)) }
            continue
        }
        // Blank line
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            continue
        }
        // Paragraph — collect until blank / heading / code fence
        var para: [String] = []
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if l.hasPrefix("#") { break }
            if l.hasPrefix("```") { break }
            para.append(l)
            i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
    }
    return blocks
}

struct MarkdownBlock: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(level <= 2 ? .callout.weight(.bold) : .callout.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        case .paragraph(let text):
            // AttributedString renders inline Markdown: **bold**, *italic*, `code`, [links](url)
            let attr = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(text)
            Text(attr)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SimpleMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = parseMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlock(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - View extension helpers

extension View {
    /// Applies a transform only when the optional value is non-nil.
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

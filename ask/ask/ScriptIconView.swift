import SwiftUI

/// Renders a script's icon. Priority: PNG (base64) → SF Symbol fallback.
///
/// Monochrome icons (black/grayscale) are rendered as template images so they
/// appear white in dark mode via `.foregroundStyle(.primary)`. Colorful icons
/// (e.g. Claude Code's orange pixel art) keep their original colors.
struct ScriptIconView: View {
    let svgString: String?   // unused on iOS — Mac pre-renders to PNG
    let iconData: String?    // base64 PNG
    let sfSymbol: String

    @Environment(\.colorScheme) private var colorScheme
    /// Cached monochrome detection — computed once on first appearance.
    @State private var monochrome: Bool? = nil

    var body: some View {
        if let data = iconData,
           let imageData = Data(base64Encoded: data),
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .renderingMode(monochrome == true ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary)
                .onAppear {
                    if monochrome == nil {
                        monochrome = uiImage.looksMonochrome
                    }
                }
        } else {
            Image(systemName: sfSymbol)
                .font(.title3)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Monochrome detection

extension UIImage {
    /// Returns `true` when the image's opaque pixels are essentially grayscale
    /// (mean HSB saturation < 15%). Sampled at 16×16 for performance.
    var looksMonochrome: Bool {
        guard let cgImage = cgImage else { return false }
        let side = 16
        guard let ctx = CGContext(
            data: nil,
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let ptr = ctx.data else { return true }

        let pixels = ptr.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var totalSaturation: Float = 0
        var opaqueCount = 0

        for i in 0..<(side * side) {
            let alpha = Float(pixels[i * 4 + 3]) / 255
            guard alpha > 0.1 else { continue }           // skip transparent
            let r = Float(pixels[i * 4])     / 255
            let g = Float(pixels[i * 4 + 1]) / 255
            let b = Float(pixels[i * 4 + 2]) / 255
            totalSaturation += max(r, g, b) - min(r, g, b)
            opaqueCount += 1
        }

        guard opaqueCount > 0 else { return true }
        return (totalSaturation / Float(opaqueCount)) < 0.15
    }
}

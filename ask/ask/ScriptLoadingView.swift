import SwiftUI

/// Shown instead of a spinner while the first CloudKit load is in progress.
/// Renders cached script icons as skeleton placeholder tiles — same layout and
/// position as the real `ScriptTileView` rows. Each icon bobs gently in its tile.
///
/// When `hasLoaded` becomes true:
///   - matched tile  → fades out in place, revealing the live tile behind it
///   - unmatched tile → slides up and off screen (script no longer active)
struct ScriptLoadingView: View {
    let entries: [CachedScriptEntry]
    /// IDs that appeared in the loaded `scriptGroups`. Empty while loading.
    let loadedIDs: Set<String>
    let hasLoaded: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.element.id) { i, entry in
                    SkeletonTileRow(
                        entry: entry,
                        index: i,
                        hasLoaded: hasLoaded,
                        settles: loadedIDs.contains(entry.id)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Individual skeleton tile

private struct SkeletonTileRow: View {
    let entry: CachedScriptEntry
    let index: Int
    let hasLoaded: Bool
    let settles: Bool   // true → fade in-place; false → slide up and off

    @State private var bobOffset: CGFloat = 0
    @State private var tileYOffset: CGFloat = 0
    @State private var tileOpacity: Double = 1

    /// Deterministic width for the name placeholder bar (looks more natural than
    /// all bars being the same width).
    private var namePlaceholderWidth: CGFloat {
        let hash = abs(entry.id.hashValue)
        return CGFloat(90 + (hash % 5) * 18)  // 90…162 pt
    }

    /// Small per-icon phase delay so the bobbing looks organic.
    private var bobPhase: Double {
        Double(abs(entry.id.hashValue) % 6) * 0.15
    }

    var body: some View {
        HStack(spacing: 12) {
            ScriptIconView(
                svgString: nil,
                iconData: entry.iconData,
                sfSymbol: entry.sfSymbol ?? "terminal.fill"
            )
            .frame(width: 30, height: 30)
            .offset(y: bobOffset)

            VStack(alignment: .leading, spacing: 5) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: namePlaceholderWidth, height: 11)
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 60, height: 8)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .offset(y: tileYOffset)
        .opacity(tileOpacity)
        .onAppear { startBobbing() }
        .onChange(of: hasLoaded) { _, loaded in
            guard loaded else { return }
            let delay = Double(index) * 0.06
            if settles {
                // Stop the bob, then fade out to reveal the live tile underneath
                withAnimation(.spring(response: 0.25).delay(delay)) {
                    bobOffset = 0
                }
                withAnimation(.easeOut(duration: 0.22).delay(delay + 0.05)) {
                    tileOpacity = 0
                }
            } else {
                // Script is gone — slide the tile up and out
                withAnimation(.easeIn(duration: 0.28).delay(delay)) {
                    tileYOffset = -60
                    tileOpacity = 0
                }
            }
        }
    }

    private func startBobbing() {
        DispatchQueue.main.asyncAfter(deadline: .now() + bobPhase) {
            withAnimation(
                .easeInOut(duration: 0.85 + bobPhase * 0.3)
                .repeatForever(autoreverses: true)
            ) {
                bobOffset = -4
            }
        }
    }
}

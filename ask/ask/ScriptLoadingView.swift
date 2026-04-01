import SwiftUI

/// Shown instead of a spinner while the first CloudKit load is in progress.
/// Renders cached script icons as floating bubbles above the toolbar with a
/// gentle idle bob. When `hasLoaded` becomes true each icon plays its exit:
///   - matched icon  → settles downward and shrinks (lands in its tile)
///   - unmatched icon → flies upward off-screen (script no longer active)
struct ScriptLoadingView: View {
    let entries: [CachedScriptEntry]
    /// IDs that appeared in the loaded `scriptGroups`. Empty while loading.
    let loadedIDs: Set<String>
    let hasLoaded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 18) {
                // Cap at 8 icons so they fit comfortably on any screen width
                ForEach(Array(entries.prefix(8).enumerated()), id: \.element.id) { i, entry in
                    FloatingIconBubble(
                        entry: entry,
                        index: i,
                        hasLoaded: hasLoaded,
                        settles: loadedIDs.contains(entry.id)
                    )
                }
            }
            // Position just above the floating toolbar capsule (which is ~76pt from bottom)
            .padding(.bottom, 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: - Individual floating icon

private struct FloatingIconBubble: View {
    let entry: CachedScriptEntry
    let index: Int
    let hasLoaded: Bool
    let settles: Bool   // true → animate down into tile; false → fly off top

    @State private var bobOffset: CGFloat = 0
    @State private var exitYOffset: CGFloat = 0
    @State private var exitScale: CGFloat = 1
    @State private var exitOpacity: Double = 1

    /// Small per-icon phase delay so the bobbing looks organic rather than
    /// synchronized. Derived deterministically from the script ID so it's
    /// stable across reloads.
    private var bobPhase: Double {
        let hash = abs(entry.id.hashValue)
        return Double(hash % 6) * 0.15   // 0…0.75 s offset
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)

            iconImage
                .frame(width: 28, height: 28)
        }
        .scaleEffect(exitScale)
        .opacity(exitOpacity)
        .offset(y: bobOffset + exitYOffset)
        .onAppear { startBobbing() }
        .onChange(of: hasLoaded) { _, loaded in
            guard loaded else { return }
            playExitAnimation()
        }
    }

    @ViewBuilder
    private var iconImage: some View {
        if let data = entry.iconData,
           let imageData = Data(base64Encoded: data),
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: entry.sfSymbol ?? "terminal.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func startBobbing() {
        // Delay the start so icons don't all begin on the same frame
        DispatchQueue.main.asyncAfter(deadline: .now() + bobPhase) {
            withAnimation(
                .easeInOut(duration: 0.85 + bobPhase * 0.3)
                .repeatForever(autoreverses: true)
            ) {
                bobOffset = -8
            }
        }
    }

    private func playExitAnimation() {
        // Stagger exits so they don't all disappear simultaneously
        let delay = Double(index) * 0.07
        if settles {
            // Icon "lands" in its tile — drops down, shrinks, fades
            withAnimation(.spring(response: 0.38, dampingFraction: 0.65).delay(delay)) {
                exitYOffset = 80
                exitScale = 0.15
                exitOpacity = 0
            }
        } else {
            // Script not loaded / stale — icon flies upward off screen
            withAnimation(.easeIn(duration: 0.32).delay(delay)) {
                exitYOffset = -350
                exitScale = 0.6
                exitOpacity = 0
            }
        }
    }
}

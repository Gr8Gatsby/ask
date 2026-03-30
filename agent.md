# iOS App Development Agent — Liquid Glass + SwiftUI

You are an expert iOS developer. When building or advising on iOS applications, follow the principles and practices below. All guidance targets the **latest iOS release** and **SwiftUI exclusively**. Do not suggest UIKit unless there is no SwiftUI equivalent.

---

## Platform Requirements

- **Minimum deployment target**: Latest iOS release only. Do not add backward-compatibility shims or conditionals for older OS versions.
- **Language**: Swift (latest version).
- **UI framework**: SwiftUI exclusively. Never introduce UIKit or AppKit unless wrapping a third-party SDK with no SwiftUI surface.
- **Tooling**: Xcode latest stable release. App icons must be configured with Icon Composer.

---

## Liquid Glass — Core Principles

Liquid Glass is Apple's dynamic material that combines the optical properties of glass with a sense of fluidity. It is the foundational visual language of the latest Apple platforms.

### Automatic adoption
Standard SwiftUI controls and navigation elements pick up Liquid Glass appearance automatically when built against the latest SDK. Do not override or suppress this behavior. Prefer standard components over custom ones wherever they exist.

### Design principles
- **Hierarchy**: Define a clear layout and navigation structure that keeps the most important content in focus. Liquid Glass emphasizes depth and layering — use it to reinforce, not compete with, content.
- **Restraint with color**: Be judicious with color in controls and navigation. Let content infuse controls and shine through the glass material. Avoid opaque backgrounds on chrome elements.
- **Dimensionality**: Embrace the layered, dimensional quality of the material. Design for depth — content lives beneath controls, not beside them.
- **Consistency**: Ensure elements fit with system software and hardware design across devices. Follow standard iconography and predictable action placement.
- **Bold simplicity**: Reimagine custom UI with simple, bold shapes that benefit from the glass material rather than fighting it.

---

## SwiftUI Architecture

### App structure
- Use `@main` with a `App` struct and `Scene`-based lifecycle.
- Prefer `NavigationStack` or `NavigationSplitView` over deprecated `NavigationView`.
- Use `TabView` with the `.tabViewStyle(.sidebarAdaptable)` on iPad for adaptive navigation.

### State management
- `@State` for local, view-owned state.
- `@StateObject` / `@ObservableObject` or `@Observable` (Swift observation macro, preferred) for model objects.
- `@Environment` and `@EnvironmentObject` for dependency injection down the view tree.
- Avoid global singletons. Pass dependencies through the environment.

### View design
- Keep views small and composable. Extract sub-views aggressively.
- Use `ViewBuilder` for conditional or multi-branch view construction.
- Prefer value-type views. Avoid storing reference types directly in view structs.
- Use `@ViewBuilder` closures and generics to build reusable components.

---

## Liquid Glass — Implementation in SwiftUI

### Standard components (use these first)
The following SwiftUI components automatically render with Liquid Glass material:
- `TabBar` / `TabView`
- `NavigationBar` / `toolbar`
- `Sheet` and `FullScreenCover`
- `Menu` and `ContextMenu`
- `Button` (in toolbars and navigation)
- `SearchBar` via `.searchable`
- `Sidebar` in `NavigationSplitView`
- `Inspector`

Do not re-implement these with custom views. Always reach for the system component first.

### Edge-to-edge content
- Extend content under navigation bars and tab bars using `.ignoresSafeArea(.all, edges: .bottom)` and `.ignoresSafeArea(.container, edges: .top)` where appropriate.
- Use the **background extension effect** to let rich media or gradients bleed behind Liquid Glass chrome.
- For horizontal scroll views inside a `NavigationSplitView`, allow content to extend under the sidebar or inspector for a seamless immersive feel.

### Custom Liquid Glass effects
When applying the material to custom UI elements:
- Use `.glassEffect()` modifier (introduced alongside Liquid Glass) to apply the standard glass material to custom shapes and containers.
- Use `.backgroundStyle(.glass)` or `.containerBackground(.glass, for:)` for container-level glass backgrounds.
- Pair with `.shadow(color:radius:)` sparingly — the glass material has inherent depth; additional shadows should be subtle.
- Animate transitions into and out of glass surfaces using `.animation(.spring)` or `.animation(.bouncy)` for fluid, physical-feeling motion.

### Background materials (for layering)
When you need a translucent surface that is not full Liquid Glass:
```swift
.background(.ultraThinMaterial)   // lightest veil
.background(.thinMaterial)
.background(.regularMaterial)     // default chrome
.background(.thickMaterial)
.background(.ultraThickMaterial)  // most opaque
```
Reserve `.ultraThinMaterial` for secondary chrome that should recede. Use the system glass effect for primary interactive chrome.

---

## Navigation Patterns

- Use `NavigationStack` with a typed path (`NavigationPath` or an enum-based router) for programmatic navigation.
- Use `NavigationSplitView` for iPad and Mac Catalyst — it adapts automatically between sidebar and stack on iPhone.
- Provide a universal search experience with `.searchable(text:placement:)`. Use `.navigationBarDrawer` or `.toolbar` placement as appropriate per platform.
- Do not build custom navigation chrome. Toolbar items must use `.toolbar` modifier with `ToolbarItem(placement:)`.
- Place primary actions in `.primaryAction` or `.confirmationAction` placements; destructive actions in `.destructiveAction`.

---

## Layout and Content Hierarchy

- Use `LazyVStack` / `LazyHStack` / `LazyVGrid` for long lists to avoid upfront layout cost.
- Use `List` with `.listStyle(.insetGrouped)` or `.listStyle(.sidebar)` for data collections — these carry Liquid Glass-aware separators and backgrounds automatically.
- Use `ScrollView` with `.scrollContentBackground(.hidden)` when placing a `List` over a custom background.
- Maintain safe area insets. Never hard-code pixel offsets for navigation bar or tab bar heights.
- Use `GeometryReader` sparingly — prefer `ViewThatFits`, `.frame(maxWidth:)`, and adaptive layout modifiers.

---

## App Icon

- Use **Icon Composer** in Xcode to create app icons. Liquid Glass icons require layered assets with a foreground layer and optional background layer.
- Design icons with **simple, bold shapes** that benefit from the dimensionality the system applies.
- Do not provide flat, legacy-style icons. Embrace the new layered format.

---

## Animations and Transitions

- Use `.animation(.spring(duration:bounce:))` or `.animation(.bouncy)` for interactive elements to match the fluid physics of Liquid Glass.
- Use `withAnimation` blocks for state-driven transitions.
- Use `matchedGeometryEffect` for hero transitions between views.
- Prefer `.transition(.push(from:))` for navigation-style content transitions and `.transition(.opacity.combined(with: .scale))` for appearing/disappearing chrome.

---

## Color and Typography

- Use **semantic colors** (`Color.primary`, `Color.secondary`, `Color.accentColor`) — they adapt correctly to light/dark mode and glass surfaces.
- Avoid hard-coding hex colors for text or icons on glass surfaces — the material's vibrancy adjusts foreground colors automatically.
- Use SF Symbols for all icons. Prefer variable-weight and multicolor symbols where available.
- Text on glass: use `.foregroundStyle(.primary)` or `.foregroundStyle(.secondary)`. Do not apply custom shadow to text on glass; the material provides legibility.
- Typography: stick to Dynamic Type. Use `Font.largeTitle`, `.title`, `.headline`, `.body`, `.caption` — never fixed point sizes.

---

## Accessibility

- All interactive elements must have `.accessibilityLabel` if the label cannot be inferred from content.
- Use `.accessibilityAddTraits` and `.accessibilityRemoveTraits` to correctly describe custom controls.
- Support Dynamic Type at all size categories including accessibility sizes.
- Test with VoiceOver and ensure navigation order is logical.
- Respect `.accessibilityReduceMotion` — gate complex animations behind this environment value.
- Respect `.accessibilityReduceTransparency` — when true, use opaque backgrounds instead of glass materials.

---

## Performance

- Mark view bodies as pure — do not perform side effects inside `body`.
- Use `@State` and `@Observable` to minimize re-render scope.
- Avoid large, deeply nested view hierarchies. Break into sub-views so SwiftUI can diff efficiently.
- Use `task(id:)` for async data loading tied to view lifecycle.
- Cancel async tasks in `onDisappear` or rely on structured concurrency cancellation via `task` modifier.
- Profile with Instruments (SwiftUI instrument) before optimizing — do not prematurely optimize.

---

## Testing

- Unit test business logic and view models independently of SwiftUI views.
- Use `ViewInspector` or snapshot testing libraries for view-level regression tests if needed.
- Test on real device for Liquid Glass rendering — simulator may not faithfully represent material effects.
- Test across iPhone and iPad form factors; `NavigationSplitView` behavior differs significantly.
- Test both light and dark mode and all Dynamic Type size categories.

---

## Ask Block System

This project uses a block-based UI system where Mac scripts push UI cards to the iOS app via CloudKit. When writing scripts or modifying block rendering:

- All supported block types, their payloads, visual design, and lifecycle are documented in **[design.md](design.md)**.
- Block types: `confirmation`, `alert`, `status`, `prompt`, `chat_prompt`, `info_card`, `icon_card`.
- Script identity (name, icon) is embedded in every block record — iOS section headers derive from this, not from hardcoded mappings.
- Script icons are transmitted as raw SVG strings (`scriptIconSVG`) and rendered on iOS via `SVGImageView` (`WKWebView`-backed). SF Symbol (`scriptIcon`) is the fallback.
- `UIViewRepresentable` wrapping `WKWebView` is the **only** acceptable UIKit usage in this codebase — it exists solely for SVG rendering, which has no native SwiftUI equivalent.
- When creating a new Ask script, use the `/ask-script` skill (`.claude/skills/ask-script/SKILL.md`) — it contains the complete MCP protocol, all block types, working MCPClient implementations for Python and Swift, code signing requirements, and test mode patterns.

---

## Key WWDC 2025 References

- **Meet Liquid Glass** — https://developer.apple.com/videos/play/wwdc2025/219
- **Get to know the new design system** — https://developer.apple.com/videos/play/wwdc2025/356
- **Build a SwiftUI app with the new design** — https://developer.apple.com/videos/play/wwdc2025/323

---

## Swift Language Version

- **Always target the latest Swift language version.** Write code that compiles cleanly in Swift 6 strict concurrency mode with zero warnings.
- Use `nonisolated` explicitly on methods and types that do not require actor isolation so the compiler does not infer incorrect isolation.
- Avoid `FileHandle.readabilityHandler` and `FileHandle.availableData` — they are `@MainActor`-annotated and cause isolation warnings. Use `DispatchSource.makeReadSource(fileDescriptor:queue:)` with raw `Darwin.read()` for pipe I/O instead.
- For mutable state shared across `DispatchSource` event handlers, define a local `final class … : @unchecked Sendable` inside the enclosing function so the compiler cannot infer `@MainActor` from surrounding context.
- Use `async`/`await` and structured concurrency (`TaskGroup`, `withTaskGroup`) over callback-based APIs wherever possible.
- Never suppress warnings with `#warning` or by downgrading the Swift language version — fix the underlying concurrency model instead.

---

## What NOT to Do

- Do not use `UIViewRepresentable` to wrap UIKit views that have a native SwiftUI equivalent.
- Do not override `.tint` or `.accentColor` with non-semantic values on toolbar or navigation elements.
- Do not place `ZStack` overlays over system chrome to simulate Liquid Glass — use the real material APIs.
- Do not target multiple iOS versions; do not add `if #available` guards.
- Do not use `GeometryReader` to measure navigation bar height — use safe area insets.
- Do not suppress the system's Liquid Glass rendering with custom `.background(.white)` on navigation or tab bars.

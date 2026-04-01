# AskMac — Agent Notes

## Swift Concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

The Xcode project (`ask/ask.xcodeproj`) sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes **every** type and member implicitly `@MainActor` unless told otherwise.

**Impact on non-`@MainActor` actors (e.g. `TerminalMonitorService`):**
Any value type (struct/enum) whose `init` or properties are called from inside a non-`@MainActor` actor will produce a Swift 6 error like:

```
Main actor-isolated initializer 'init(...)' cannot be called from outside of the actor
```

**Fix:** Explicitly annotate the affected members with `nonisolated`:

```swift
public struct MyValue: Sendable {
    // Without nonisolated, the implicit @MainActor default makes this
    // uncallable from a non-@MainActor actor.
    public nonisolated init(...) { ... }
    public nonisolated var someProperty: Int { ... }
}
```

Apply `nonisolated` to any `init`, computed property, or method on a value type that needs to be usable from a non-`@MainActor` actor context. This is **not** needed when building via `swift build` (Package.swift), which does not set the default isolation — only the Xcode target is affected.

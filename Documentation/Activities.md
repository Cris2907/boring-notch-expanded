# Notch Activities

An activity is a source-defined unit of notch content. It gives the app a stable identifier, navigation metadata, SwiftUI presentations, availability and active state, and optional lifecycle or configuration behavior.

Activities are ordinary Swift types compiled into the app. The registry is not a runtime plugin loader and does not load third-party executable code.

## Core types

`NotchActivity` uses associated view types, so activity implementations return concrete SwiftUI views. `AnyNotchActivity` performs type erasure only when different activity types are stored together in `ActivityRegistry`.

Every activity provides:

- A stable `ActivityID`. Do not derive it from a display name or change it after release.
- `ActivityMetadata` containing its name, SF Symbol, tint, and optional expanded height.
- An expanded presentation.
- `isAvailable`, which determines whether it appears in activity navigation.
- `isActive`, which represents ongoing work such as a running timer. It is independent of the currently selected page.

Compact presentation, configuration, and appearance lifecycle callbacks are optional.

## Registration and navigation

Production activities are registered in the source-defined builder in `ActivityRegistry.shared`:

```swift
return try ActivityRegistry {
    CalendarActivity()
    MyActivity()
}
```

Registration order controls activity order between Home and the legacy Activities page. Duplicate IDs prevent registry creation. An activity whose `isAvailable` value is false remains registered but is removed from tabs, pagination, and swipe navigation. If the selected activity becomes unavailable, navigation falls back to Home.

`ExampleActivity` intentionally is not in the production registry. Add it to the builder temporarily to see the example in the notch.

## Expanded and compact presentations

The expanded host calls `makeExpandedView()`, applies `preferredExpandedHeight` when present, and invokes `activityDidAppear()` and `activityDidDisappear()` as the destination enters or leaves the hierarchy.

To declare compact content, return a concrete view from `makeCompactView()` and set `supportsCompactPresentation` to true. Compact content should be inexpensive and should only update as often as its displayed data requires.

```swift
var supportsCompactPresentation: Bool { true }

func makeCompactView() -> some View {
    Image(systemName: metadata.systemImage)
}
```

The current closed-notch shell still owns the established priority between battery, Bluetooth, HUD, timer, music, and idle content. Registering an activity does not automatically insert its compact view into that chain yet. Compact integration should be added when an existing compact feature is migrated and its priority and sizing behavior can be preserved explicitly.

## State and lifecycle

Use SwiftUI state for presentation-local state:

- `@State` for values owned by one rendered view.
- `@StateObject` for a reference model owned by one rendered view.
- `@ObservedObject` for an existing shared manager.

Use a manager for persistent sessions, system observers, services, or state shared across displays. Do not move those responsibilities into the registry. Activity instances are shared, while the app can create a notch window per display.

Publish changes to `isAvailable` and `isActive`. Type erasure and the registry forward `objectWillChange` to navigation consumers.

Lifecycle callbacks are for work that genuinely follows visibility. They may run once per visible notch window, so implementations must be idempotent or reference-counted. Prefer normal SwiftUI `onAppear` and `onDisappear` inside activity views for view-local behavior.

## Configuration

An activity with configuration returns a concrete configuration view and sets `supportsConfiguration` to true:

```swift
var supportsConfiguration: Bool { true }

func makeConfigurationView() -> some View {
    MyActivitySettings()
}
```

`ActivityConfigurationView(activityID:)` hosts that content. The registry does not automatically add a Settings sidebar entry; add an explicit entry when an activity needs user-facing configuration. This preserves the current Settings organization.

## Creating an activity

1. Create an `ObservableObject` conforming to `NotchActivity`.
2. Choose a permanent ID and metadata.
3. Return the expanded SwiftUI view.
4. Add compact content, configuration, or lifecycle callbacks only when needed.
5. Register the activity in `ActivityRegistry.shared`.
6. Add the Swift file to the app target and add focused tests for ID, availability, state, and navigation behavior.
7. Build and run the macOS tests.

Minimal example:

```swift
@MainActor
final class WeatherActivity: NotchActivity {
    let id = ActivityID("community.weather")
    let metadata = ActivityMetadata(
        name: "Weather",
        systemImage: "cloud.sun.fill",
        tint: .blue
    )

    func makeExpandedView() -> some View {
        WeatherView()
    }
}
```

Keep activity initialization cheap. Managers that install observers, request permissions, or start polling should remain lazy and should only start when the feature requires them.

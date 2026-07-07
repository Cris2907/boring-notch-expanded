import Combine
import SwiftUI

public struct ActivityID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

struct ActivityMetadata {
    let name: String
    let systemImage: String
    let tint: Color
    let preferredExpandedHeight: CGFloat?

    init(
        name: String,
        systemImage: String,
        tint: Color = .accentColor,
        preferredExpandedHeight: CGFloat? = nil
    ) {
        self.name = name
        self.systemImage = systemImage
        self.tint = tint
        self.preferredExpandedHeight = preferredExpandedHeight
    }
}

enum ActivityLivePresentationPriority: Int, Comparable, Sendable {
    case low = 0
    case normal = 100
    case high = 200

    static func < (
        lhs: ActivityLivePresentationPriority,
        rhs: ActivityLivePresentationPriority
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ActivityLivePresentationState: Equatable, Sendable {
    case hidden
    case visible(priority: ActivityLivePresentationPriority)

    var priority: ActivityLivePresentationPriority? {
        guard case .visible(let priority) = self else { return nil }
        return priority
    }
}

@MainActor
protocol NotchActivity: ObservableObject {
    associatedtype ExpandedContent: View
    associatedtype CompactContent: View = EmptyView
    associatedtype LivePresentationContent: View = EmptyView
    associatedtype MinimalLivePresentationContent: View = LivePresentationContent
    associatedtype ConfigurationContent: View = EmptyView

    var id: ActivityID { get }
    var metadata: ActivityMetadata { get }
    var isAvailable: Bool { get }
    var isActive: Bool { get }
    var supportsCompactPresentation: Bool { get }
    var livePresentationState: ActivityLivePresentationState { get }
    var supportsConfiguration: Bool { get }

    @ViewBuilder func makeExpandedView() -> ExpandedContent
    @ViewBuilder func makeCompactView() -> CompactContent
    @ViewBuilder func makeLivePresentationView() -> LivePresentationContent
    @ViewBuilder func makeMinimalLivePresentationView() -> MinimalLivePresentationContent
    @ViewBuilder func makeConfigurationView() -> ConfigurationContent

    func activityDidAppear()
    func activityDidDisappear()
}

extension NotchActivity {
    var isAvailable: Bool { true }
    var isActive: Bool { false }
    var supportsCompactPresentation: Bool { false }
    var livePresentationState: ActivityLivePresentationState { .hidden }
    var supportsConfiguration: Bool { false }

    func activityDidAppear() {}
    func activityDidDisappear() {}
}

extension NotchActivity where CompactContent == EmptyView {
    func makeCompactView() -> EmptyView {
        EmptyView()
    }
}

extension NotchActivity where LivePresentationContent == EmptyView {
    func makeLivePresentationView() -> EmptyView {
        EmptyView()
    }
}

extension NotchActivity where MinimalLivePresentationContent == LivePresentationContent {
    func makeMinimalLivePresentationView() -> LivePresentationContent {
        makeLivePresentationView()
    }
}

extension NotchActivity where ConfigurationContent == EmptyView {
    func makeConfigurationView() -> EmptyView {
        EmptyView()
    }
}

@MainActor
final class AnyNotchActivity: @MainActor ObservableObject, Identifiable {
    let objectWillChange = ObservableObjectPublisher()

    let id: ActivityID
    let metadata: ActivityMetadata

    private let availability: () -> Bool
    private let activeState: () -> Bool
    private let compactPresentationSupport: () -> Bool
    private let livePresentation: () -> ActivityLivePresentationState
    private let configurationSupport: () -> Bool
    private let expandedView: () -> AnyView
    private let compactView: () -> AnyView
    private let livePresentationView: () -> AnyView
    private let minimalLivePresentationView: () -> AnyView
    private let configurationView: () -> AnyView
    private let didAppear: () -> Void
    private let didDisappear: () -> Void
    private var activityObservation: AnyCancellable?

    init<Activity: NotchActivity>(_ activity: Activity) {
        id = activity.id
        metadata = activity.metadata
        availability = { activity.isAvailable }
        activeState = { activity.isActive }
        compactPresentationSupport = { activity.supportsCompactPresentation }
        livePresentation = { activity.livePresentationState }
        configurationSupport = { activity.supportsConfiguration }
        expandedView = { AnyView(activity.makeExpandedView()) }
        compactView = { AnyView(activity.makeCompactView()) }
        livePresentationView = { AnyView(activity.makeLivePresentationView()) }
        minimalLivePresentationView = { AnyView(activity.makeMinimalLivePresentationView()) }
        configurationView = { AnyView(activity.makeConfigurationView()) }
        didAppear = activity.activityDidAppear
        didDisappear = activity.activityDidDisappear

        activityObservation = activity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isAvailable: Bool { availability() }
    var isActive: Bool { activeState() }
    var supportsCompactPresentation: Bool { compactPresentationSupport() }
    var livePresentationState: ActivityLivePresentationState { livePresentation() }
    var supportsConfiguration: Bool { configurationSupport() }

    func makeExpandedView() -> AnyView { expandedView() }
    func makeCompactView() -> AnyView { compactView() }
    func makeLivePresentationView() -> AnyView { livePresentationView() }
    func makeMinimalLivePresentationView() -> AnyView { minimalLivePresentationView() }
    func makeConfigurationView() -> AnyView { configurationView() }

    func activityDidAppear() { didAppear() }
    func activityDidDisappear() { didDisappear() }
}

struct ActivityLivePresentationSnapshot: Equatable, Sendable {
    static let empty = ActivityLivePresentationSnapshot(startedSequences: [:])

    let startedSequences: [ActivityID: Int]

    func startedSequence(for id: ActivityID) -> Int? {
        startedSequences[id]
    }
}

@MainActor
final class ActivityLivePresentationCoordinator: ObservableObject {
    static let shared = ActivityLivePresentationCoordinator(registry: .shared)

    @Published private(set) var snapshot: ActivityLivePresentationSnapshot = .empty

    private let registry: ActivityRegistry
    private var knownEligibility: [ActivityID: Bool] = [:]
    private var startedSequences: [ActivityID: Int] = [:]
    private var nextSequence = 0
    private var registryObservation: AnyCancellable?
    private var reconcileTask: Task<Void, Never>?

    init(registry: ActivityRegistry) {
        self.registry = registry
        reconcile(recordStartsForNewEligibility: false)

        registryObservation = registry.objectWillChange.sink { [weak self] _ in
            #if DEBUG
            ActivityLivePresentationDebugLogger.logRegistryChangeReceived()
            #endif
            self?.scheduleReconcile()
        }
    }

    deinit {
        reconcileTask?.cancel()
        registryObservation?.cancel()
    }

    func waitForPendingReconciliation() async {
        await reconcileTask?.value
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.reconcile(recordStartsForNewEligibility: true)
        }
    }

    private func reconcile(recordStartsForNewEligibility: Bool) {
        #if DEBUG
        ActivityLivePresentationDebugLogger.logReconciliationStarted(
            recordStartsForNewEligibility: recordStartsForNewEligibility
        )
        #endif

        var nextEligibility: [ActivityID: Bool] = [:]
        var nextStartedSequences = startedSequences

        for activity in registry.activities {
            let isEligible = activity.isAvailable && activity.livePresentationState.priority != nil
            let wasEligible = knownEligibility[activity.id] ?? false

            nextEligibility[activity.id] = isEligible

            if isEligible && !wasEligible {
                if recordStartsForNewEligibility {
                    nextSequence += 1
                    nextStartedSequences[activity.id] = nextSequence
                    #if DEBUG
                    ActivityLivePresentationDebugLogger.logBecameEligible(
                        activityID: activity.id,
                        sequence: nextSequence
                    )
                    #endif
                } else {
                    nextStartedSequences.removeValue(forKey: activity.id)
                    #if DEBUG
                    ActivityLivePresentationDebugLogger.logInitiallyEligible(
                        activityID: activity.id
                    )
                    #endif
                }
            } else if !isEligible {
                if wasEligible {
                    #if DEBUG
                    ActivityLivePresentationDebugLogger.logBecameIneligible(
                        activityID: activity.id
                    )
                    #endif
                }
                nextStartedSequences.removeValue(forKey: activity.id)
            }
        }

        knownEligibility = nextEligibility
        startedSequences = nextStartedSequences
        snapshot = ActivityLivePresentationSnapshot(startedSequences: startedSequences)

        #if DEBUG
        ActivityLivePresentationDebugLogger.logReconciled(
            activities: registry.activities,
            snapshot: snapshot
        )
        #endif
    }
}

enum ActivityLivePresentationStack {
    case none
    case full(AnyNotchActivity)
    case split(leading: AnyNotchActivity, trailing: AnyNotchActivity)

    var isVisible: Bool {
        if case .none = self { return false }
        return true
    }

    var identity: String {
        switch self {
        case .none:
            return "none"
        case .full(let activity):
            return "full:\(activity.id.rawValue)"
        case .split(let leading, let trailing):
            return "split:\(leading.id.rawValue):\(trailing.id.rawValue)"
        }
    }

    var debugSelectionDescription: String {
        switch self {
        case .none:
            return ".none"
        case .full(let activity):
            return ".full(\(activity.id.rawValue))"
        case .split(let leading, let trailing):
            return ".split(\(leading.id.rawValue), \(trailing.id.rawValue))"
        }
    }
}

@MainActor
func selectedActivityLivePresentationStack(
    from activities: [AnyNotchActivity],
    snapshot: ActivityLivePresentationSnapshot
) -> ActivityLivePresentationStack {
    let eligibleActivities = eligibleLiveActivitiesInSelectionOrder(
        from: activities,
        snapshot: snapshot
    )

    let selection: ActivityLivePresentationStack
    switch eligibleActivities.count {
    case 0:
        selection = .none
    case 1:
        selection = .full(eligibleActivities[0])
    default:
        selection = .split(leading: eligibleActivities[1], trailing: eligibleActivities[0])
    }

    #if DEBUG
    ActivityLivePresentationDebugLogger.logSelectorRun(
        eligibleActivities: eligibleActivities,
        snapshot: snapshot,
        selection: selection
    )
    #endif

    return selection
}

@MainActor
private func eligibleLiveActivitiesInSelectionOrder(
    from activities: [AnyNotchActivity],
    snapshot: ActivityLivePresentationSnapshot
) -> [AnyNotchActivity] {
    activities.enumerated()
        .filter { _, activity in
            activity.isAvailable && activity.livePresentationState.priority != nil
        }
        .sorted { lhs, rhs in
            let lhsSequence = snapshot.startedSequence(for: lhs.element.id)
            let rhsSequence = snapshot.startedSequence(for: rhs.element.id)

            switch (lhsSequence, rhsSequence) {
            case let (lhsSequence?, rhsSequence?) where lhsSequence != rhsSequence:
                return lhsSequence > rhsSequence
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
}

#if DEBUG
@MainActor
enum ActivityLivePresentationDebugLogger {
    private static var lastSelectorSignature: String?

    static func logRegistryChangeReceived() {
        log("registry/activity change received; scheduling eligibility reconciliation")
    }

    static func logReconciliationStarted(recordStartsForNewEligibility: Bool) {
        log("reconciling eligibility recordStarts=\(recordStartsForNewEligibility)")
    }

    static func logBecameEligible(activityID: ActivityID, sequence: Int) {
        log("activity became eligible id=\(activityID.rawValue) sequence=\(sequence)")
    }

    static func logInitiallyEligible(activityID: ActivityID) {
        log("activity initially eligible id=\(activityID.rawValue) sequence=registry-order")
    }

    static func logBecameIneligible(activityID: ActivityID) {
        log("activity became ineligible id=\(activityID.rawValue)")
    }

    static func logReconciled(
        activities: [AnyNotchActivity],
        snapshot: ActivityLivePresentationSnapshot
    ) {
        let eligibleActivities = eligibleLiveActivitiesInSelectionOrder(
            from: activities,
            snapshot: snapshot
        )
        log("eligible snapshot recencyOrder=[\(activityListDescription(activities: eligibleActivities, snapshot: snapshot))]")
    }

    static func logSelectorRun(
        eligibleActivities: [AnyNotchActivity],
        snapshot: ActivityLivePresentationSnapshot,
        selection: ActivityLivePresentationStack
    ) {
        let candidates = activityListDescription(
            activities: eligibleActivities,
            snapshot: snapshot
        )
        let signature = "candidates=[\(candidates)] result=\(selection.debugSelectionDescription)"
        guard signature != lastSelectorSignature else { return }
        lastSelectorSignature = signature
        log("selector run \(signature)")
    }

    static func logContentViewPresentationChange(from oldValue: String, to newValue: String) {
        log("ContentView closed-notch presentation changed \(oldValue) -> \(newValue)")
    }

    private static func activityListDescription(
        activities: [AnyNotchActivity],
        snapshot: ActivityLivePresentationSnapshot
    ) -> String {
        activities
            .map { activity in
                let sequence = snapshot.startedSequence(for: activity.id)
                    .map(String.init) ?? "registry-order"
                let priority = activity.livePresentationState.priority
                    .map { "\($0.rawValue)" } ?? "hidden"
                return "\(activity.id.rawValue)#seq=\(sequence)#priority=\(priority)"
            }
            .joined(separator: ", ")
    }

    private static func log(_ message: String) {
        print("[LiveActivityStack] \(message)")
    }
}
#endif

struct ExpandedActivityView: View {
    @ObservedObject var activity: AnyNotchActivity

    var body: some View {
        Group {
            if let height = activity.metadata.preferredExpandedHeight {
                activity.makeExpandedView()
                    .preferredOpenNotchHeight(height)
            } else {
                activity.makeExpandedView()
            }
        }
        .onAppear {
            activity.activityDidAppear()
        }
        .onDisappear {
            activity.activityDidDisappear()
        }
    }
}

struct ActivityConfigurationView: View {
    let activityID: ActivityID

    @ObservedObject private var registry = ActivityRegistry.shared

    var body: some View {
        if let activity = registry.activity(for: activityID), activity.supportsConfiguration {
            RegisteredActivityConfigurationView(activity: activity)
        } else {
            EmptyView()
        }
    }
}

private struct RegisteredActivityConfigurationView: View {
    @ObservedObject var activity: AnyNotchActivity

    var body: some View {
        activity.makeConfigurationView()
    }
}

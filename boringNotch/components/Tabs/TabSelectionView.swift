//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
    let tint: Color
}

func visibleNotchViews(
    availableActivityIDs: [ActivityID],
    includesShelf: Bool
) -> [NotchViews] {
    var views: [NotchViews] = [.home]
    views.append(contentsOf: availableActivityIDs.map(NotchViews.activity))
    views.append(.activities)
    if includesShelf {
        views.append(.shelf)
    }
    return views
}

func resolvedNotchView(
    _ currentView: NotchViews,
    availableActivityIDs: [ActivityID],
    includesShelf: Bool
) -> NotchViews {
    visibleNotchViews(
        availableActivityIDs: availableActivityIDs,
        includesShelf: includesShelf
    )
        .contains(currentView) ? currentView : .home
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var activityRegistry = ActivityRegistry.shared
    @Default(.boringShelf) private var boringShelf
    @Default(.tintedTabIcons) private var tintedTabIcons
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        select(tab.view)
                    }
                    .frame(height: 26)
                    .foregroundStyle(iconColor(for: tab.view))
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
                    .onHover { hovering in
                        guard hovering else { return }
                        select(tab.view)
                    }
            }
        }
        .clipShape(Capsule())
    }

    private var visibleTabs: [TabModel] {
        visibleNotchViews(
            availableActivityIDs: activityRegistry.availableActivityIDs,
            includesShelf: boringShelf
        )
        .compactMap { tabModel(for: $0) }
    }

    private func iconColor(for view: NotchViews) -> Color {
        guard view == coordinator.currentView else { return .gray }
        return tintedTabIcons ? tabModel(for: view)?.tint ?? .white : .white
    }

    private func select(_ view: NotchViews) {
        guard coordinator.currentView != view else { return }
        withAnimation(.smooth) {
            coordinator.currentView = view
        }
    }

    private func tabModel(for view: NotchViews) -> TabModel? {
        switch view {
        case .home:
            return TabModel(label: "Home", icon: "house.fill", view: view, tint: .blue)
        case .activities:
            return TabModel(label: "Activities", icon: "timer", view: view, tint: .orange)
        case .shelf:
            return TabModel(label: "Shelf", icon: "tray.fill", view: view, tint: .blue)
        case .activity(let id):
            guard let activity = activityRegistry.activity(for: id), activity.isAvailable else {
                return nil
            }
            return TabModel(
                label: activity.metadata.name,
                icon: activity.metadata.systemImage,
                view: view,
                tint: activity.metadata.tint
            )
        }
    }
}

struct NotchPaginationDots: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var activityRegistry = ActivityRegistry.shared
    @Default(.boringShelf) private var boringShelf

    private var pages: [NotchViews] {
        visibleNotchViews(
            availableActivityIDs: activityRegistry.availableActivityIDs,
            includesShelf: boringShelf
        )
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(pages, id: \.self) { page in
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        coordinator.currentView = page
                    }
                } label: {
                    Circle()
                        .fill(page == coordinator.currentView ? Color.white : Color.gray.opacity(0.45))
                        .frame(width: page == coordinator.currentView ? 6 : 5, height: page == coordinator.currentView ? 6 : 5)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: page))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private func accessibilityLabel(for page: NotchViews) -> String {
        switch page {
        case .home: return "Home page"
        case .activities: return "Activities page"
        case .shelf: return "Shelf page"
        case .activity(let id):
            return "\(activityRegistry.activity(for: id)?.metadata.name ?? "Activity") page"
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}

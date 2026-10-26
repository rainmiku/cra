import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Transient sidebar UI state shared between AppKit and SwiftUI.
@MainActor
@Observable
final class SidebarUIState {
    var renamingID: UUID?
    var draggingID: UUID?
    var hoveredTabID: UUID?
    /// Loading progress per tab (0...1), fed by the browser manager.
    var progress: [UUID: Double] = [:]
    var loadedTabIDs: Set<UUID> = []
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isCompact = false
    /// Page theme colour of the visible tab ("#RRGGBB" or "").
    var pageThemeColor = ""
    /// Tab chosen from the keyboard; Arc draws its yellow/black dashed ring
    /// around it until the mouse picks another tab.
    var keyboardFocusID: UUID?
    /// The pointer is over a draggable sidebar row or tile. The sidebar's
    /// hosting view then refuses window-background drags so SwiftUI's
    /// `.draggable` gets the press (the window is movable by its background).
    var pointerOverDraggable = false
    /// Per-tab navigation state for split panes (each pane has its own toolbar).
    var navStates: [UUID: TabNavState] = [:]
    /// Panes currently shown in the window (empty when a single page shows).
    var splitPaneIDs: [UUID] = []
    /// A sidebar tab is being dragged over the content area; which pane edge it would land on.
    var splitDropTarget: SplitDropTarget?
    /// Live space swipe, in pages away from the focused space (+ toward the next one);
    /// 0 at rest. The sidebar pages and the window tint follow it (Dia: PageSwipeController).
    var spaceSwipe: CGFloat = 0
    /// Release velocity for the settle spring, relative to the distance left to travel.
    var spaceSettleVelocity: Double = 0
    /// Dia settles pages with a zero-bounce spring that picks up the release speed.
    var spaceSettleAnimation: Animation {
        .interpolatingSpring(duration: 0.4, bounce: 0, initialVelocity: spaceSettleVelocity)
    }
    /// Tabs picked with ⌘/⇧-click; closing acts on all of them.
    var multiSelection: Set<UUID> = []
    /// Where the next ⇧-click range starts.
    var selectionAnchor: UUID?
    /// A sidebar drag over the space's list and what releasing it would do.
    var listDrop: SidebarListDrop?
    /// Row and section frames in the list's coordinate space, for hit-testing drags.
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    /// Dia's nav-bar status: a short confirmation shown in place of the URL
    /// ("Copied Current URL"), then the URL comes back.
    var toolbarStatus: ToolbarStatus?
    @ObservationIgnored private var statusClear: Task<Void, Never>?

    func flashStatus(_ text: String, symbol: String, for seconds: Double = 2) {
        let status = ToolbarStatus(symbol: symbol, text: text)
        withAnimation(.easeOut(duration: 0.15)) { toolbarStatus = status }
        statusClear?.cancel()
        statusClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.toolbarStatus?.id == status.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toolbarStatus = nil }
        }
    }

    func navState(for id: UUID) -> TabNavState { navStates[id] ?? TabNavState() }

    /// ⌘-click toggles a tab, ⇧-click adds the run of rows from the anchor.
    /// The open tab counts as picked when a selection starts (Finder-style).
    func pick(_ id: UUID, range: Bool, in store: SidebarStore) {
        let order = store.listedTabIDs(in: store.focusedSpaceID)
        if multiSelection.isEmpty, let open = store.selectedTabID, order.contains(open) { multiSelection = [open] }
        if range, let a = order.firstIndex(of: selectionAnchor ?? store.selectedTabID ?? id), let b = order.firstIndex(of: id) {
            multiSelection.formUnion(order[min(a, b)...max(a, b)])
        } else {
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
            selectionAnchor = id
        }
    }

    func clearPicks(anchor: UUID? = nil) {
        if !multiSelection.isEmpty { multiSelection = [] }
        selectionAnchor = anchor
    }
}

struct ToolbarStatus: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

struct TabNavState: Equatable {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var themeColor = ""
}

/// Where a dragged tab or link would go in the split (Arc: SplitViewControllerLayout.DropTarget).
enum SplitDropTarget: Equatable {
    case insert(index: Int)
    case replace(index: Int)
}

/// Things the sidebar needs AppKit to do.
@MainActor
final class SidebarActions {
    var openCommandBar: (CommandBarMode) -> Void = { _ in }
    var closeTab: (UUID) -> Void = { _ in }
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var reload: () -> Void = {}
    var editSpace: (Space?) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    var showArchive: () -> Void = {}
    var resetPinnedTab: (UUID) -> Void = { _ in }
    var openURL: (String) -> Void = { _ in }
    var performAction: (String) -> Void = { _ in }
    /// Double-click on an empty part of the header strip (sidebar title row or toolbar).
    var titleBarDoubleClick: () -> Void = {}
    /// Split view: make a pane the focused one (its toolbar acts on it).
    var focusPane: (UUID) -> Void = { _ in }
    /// Split view: close one pane (Arc: "Close this Split Pane").
    var closePane: (UUID) -> Void = { _ in }
    /// Split view: move a pane out into its own tab (Arc: "Separate Tab from Split").
    var separatePane: (UUID) -> Void = { _ in }
    /// Split view: pane-level navigation (goBack/goForward/reload by tab).
    var paneNavigate: (UUID, String) -> Void = { _, _ in }
    /// Split view: open the command bar for one pane (edit its URL / fill an empty pane).
    var editPaneURL: (UUID) -> Void = { _ in }
    /// Toolbar extension button (Chromium extension ID): run its action on the focused page.
    var runExtension: (String) -> Void = { _ in }
    /// Toolbar Extensions button: the extensions menu, under the pointer.
    var showExtensionsMenu: () -> Void = {}
}

private struct SidebarActionsKey: EnvironmentKey {
    @MainActor static var defaultValue: SidebarActions { SidebarActions() }
}

extension EnvironmentValues {
    var sidebarActions: SidebarActions {
        get { self[SidebarActionsKey.self] }
        set { self[SidebarActionsKey.self] = newValue }
    }
}

extension UTType {
    static let craSidebarItem = UTType(exportedAs: "io.github.rainmiku.cra.sidebar-item")
}

struct SidebarDragItem: Codable, Transferable {
    let id: UUID

    /// `.draggable` evaluates its payload when the drag starts; record what
    /// is being dragged so drop targets can preview before the drop.
    static func begin(_ id: UUID, _ ui: SidebarUIState) -> SidebarDragItem {
        MainActor.assumeIsolated { ui.draggingID = id }
        return SidebarDragItem(id: id)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .craSidebarItem)
    }
}

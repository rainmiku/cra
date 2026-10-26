import AppKit
import CraCEF
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, BrowserManagerDelegate {
    unowned let app: AppDelegate
    var store: SidebarStore { app.store }
    let sidebarUI = SidebarUIState()
    let sidebarActions = SidebarActions()
    let overlay = OverlayState()
    let commandBar: CommandBarController
    private(set) var browsers: BrowserManager!
    private(set) var shell: ShellView!
    private var commandPanel: CommandBarPanel!
    private var commandHost: NSHostingView<AnyView>!
    private var spaceEditor: NSWindow?
    private var importWindow: ImportWindowController?
    private var scrollMonitor: Any?
    private var childClickMonitor: Any?
    private enum SwipeAxis { case undecided, horizontal, vertical }
    private var swipeAxis = SwipeAxis.vertical
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    /// Points travelled since the space swipe locked, and recent deltas for its release speed.
    private var swipeTravel: CGFloat = 0
    private var swipeSamples: [(time: TimeInterval, dx: CGFloat)] = []
    private var swipeDetent = 0
    private var enteredFullscreenForContent = false
    private var lastSidebarVisible = true
    private var lastSidebarWidth: CGFloat = 0
    private var commandBarOpenedAt = Date.distantPast
    private var commandObserving = false

    var currentBrowser: CraBrowser? { browsers.visibleRuntime?.browser }

    init(app: AppDelegate) {
        self.app = app
        commandBar = CommandBarController(engine: app.engine, store: app.store)
        let frame = app.store.prefs.windowFrame.map { NSRectFromString($0) } ?? NSRect(x: 0, y: 0, width: 1400, height: 880)
        let window = CraWindow(contentRect: frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Cra"
        if app.store.prefs.windowFrame == nil { window.center() }

        let store = app.store
        let palette = store.focusedSpace.theme.palette
        let env: (AnyView) -> AnyView = { v in
            AnyView(v.environment(store).environment(self.sidebarUI).environment(app.favicons).environment(\.sidebarActions, self.sidebarActions))
        }
        shell = ShellView(frame: window.contentView!.bounds,
                          background: SpaceBackground(palette: palette, pager: SpacePager(store: store, ui: sidebarUI)),
                          sidebar: env(AnyView(SidebarRootView())),
                          toolbar: env(AnyView(ContentToolbarView(palette: palette))),
                          placeholder: AnyView(EmptyContentView(space: store.focusedSpace)),
                          status: AnyView(StatusBubble(overlay: overlay)),
                          toasts: AnyView(ToastStack(overlay: overlay)),
                          find: AnyView(FindBar(overlay: overlay, onFind: { [weak self] q, fwd, next in self?.find(q, forward: fwd, next: next) },
                                                onClose: { [weak self] in self?.hideFindBar() })))
        shell.sidebarWidth = CGFloat(store.prefs.sidebarWidth)
        shell.sidebarVisible = store.prefs.sidebarVisible
        shell.showToolbar = store.settings.showToolbar
        lastSidebarVisible = store.prefs.sidebarVisible
        lastSidebarWidth = CGFloat(store.prefs.sidebarWidth)
        window.contentView = shell
        window.backgroundColor = NSColor(palette.gradientColors.first ?? .gray)

        browsers = BrowserManager(store: store, favicons: app.favicons, container: shell.parkingView)
        browsers.delegate = self
        shell.sidebarHost.pointerOverDraggable = { [weak self] in self?.sidebarUI.pointerOverDraggable ?? false }
        browsers.paneHost = { [weak self] id in self?.shell.card(for: id)?.webArea }
        shell.makeToolbar = { [weak self] id in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(ContentToolbarView(palette: self.store.focusedSpace.theme.palette, paneTabID: id)
                .environment(self.store).environment(self.sidebarUI).environment(app.favicons).environment(\.sidebarActions, self.sidebarActions))
        }
        shell.onPaneResizeBegan = { [weak self] in self?.pageWindowsFollowLive = true }
        shell.onPaneResizeEnded = { [weak self] factors in
            guard let self else { return }
            self.pageWindowsFollowLive = false
            if let sel = self.store.selectedTabID, let split = self.store.splitContaining(sel) {
                self.store.setSplitWidthFactors(split.id, factors.mapValues { Double($0) })
            }
        }

        commandPanel = CommandBarPanel()
        commandHost = NSHostingView(rootView: AnyView(CommandBarView(controller: commandBar).environment(app.favicons)))
        commandPanel.contentView = commandHost
        commandPanel.delegate = self

        wireActions()
        shell.resizeHandle.onDrag = { [weak self] dx in
            guard let self else { return }
            let w = min(max(CraMetrics.sidebarMinWidth, shell.sidebarWidth + dx), CraMetrics.sidebarMaxWidth)
            shell.sidebarWidth = w
            shell.layoutSubtreeIfNeeded()
        }
        shell.resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            store.prefs.sidebarWidth = Double(shell.sidebarWidth)
            lastSidebarWidth = shell.sidebarWidth
        }
        shell.onEdgeHover = { [weak self] show in self?.setFloatingSidebar(show) }

        installSwipeMonitor()
        installChildClickMonitor()
        installFloatingSidebar()
        observeStore()
        refresh()
        shell.onDevToolsFrame = { [weak self] rect in self?.positionDevToolsWindow(rect) }
        shell.onPaneFrames = { [weak self] frames in self?.positionPageWindows(frames) }
        shell.onAnimatePaneFrames = { [weak self] frames, d in self?.animatePageWindows(to: frames, duration: d) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shell.windowActive = true }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shell.windowActive = false }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Wiring

    private func wireActions() {
        sidebarActions.titleBarDoubleClick = { [weak self] in (self?.window as? CraWindow)?.performTitleDoubleClickAction() }
        sidebarActions.openCommandBar = { [weak self] mode in self?.openCommandBar(mode) }
        sidebarActions.closeTab = { [weak self] id in self?.closeTab(id) }
        sidebarActions.goBack = { [weak self] in self?.currentBrowser?.goBack() }
        sidebarActions.goForward = { [weak self] in self?.currentBrowser?.goForward() }
        sidebarActions.reload = { [weak self] in
            guard let b = self?.currentBrowser else { return }
            b.isLoading ? b.stopLoading() : b.reload()
        }
        sidebarActions.editSpace = { [weak self] s in self?.showSpaceEditor(space: s) }
        sidebarActions.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebarActions.showArchive = { [weak self] in self?.app.showArchiveWindow() }
        sidebarActions.resetPinnedTab = { [weak self] id in self?.resetPinnedTab(id) }
        sidebarActions.openURL = { [weak self] url in self?.store.createTab(url: url) }
        sidebarActions.focusPane = { [weak self] id in
            guard let self, self.store.selectedTabID != id else { return }
            self.store.selectTab(id)
        }
        sidebarActions.closePane = { [weak self] id in self?.closeSplitPane(id) }
        sidebarActions.separatePane = { [weak self] id in self?.separatePane(id) }
        sidebarActions.paneNavigate = { [weak self] id, what in
            guard let self else { return }
            if self.store.selectedTabID != id { self.store.selectTab(id) }
            guard let b = self.browsers.runtime(for: id)?.browser else { return }
            switch what {
            case "goBack": b.goBack()
            case "goForward": b.goForward()
            case "reload": b.isLoading ? b.stopLoading() : b.reload()
            default: break
            }
        }
        sidebarActions.editPaneURL = { [weak self] id in
            guard let self else { return }
            if self.store.selectedTabID != id { self.store.selectTab(id) }
            self.openCommandBar(.editURL)
        }
        // Toolbar buttons are ~34 pt wide and the click lands near the middle: the popup's
        // right edge lines up with the button's (Chrome anchors popups that way).
        sidebarActions.runExtension = { [weak self] id in self?.runExtensionAction(id, buttonRightX: NSEvent.mouseLocation.x + 17) }
        sidebarActions.showExtensionsMenu = { [weak self] in self?.showToolbarExtensionsMenu() }
        sidebarActions.performAction = { [weak self] id in
            if id.hasPrefix("muteTab:"), let uuid = UUID(uuidString: String(id.dropFirst(8))) {
                let muted = self?.store.item(uuid)?.tab?.muted ?? false
                self?.browsers.runtime(for: uuid)?.browser.setAudioMuted(muted)
            } else {
                self?.app.perform(id)
            }
        }
        commandBar.onCommit = { [weak self] s, typed, mode, force in self?.handleCommit(s, typed: typed, mode: mode, forceNewTab: force) }
        commandBar.onClose = { [weak self] in self?.hideCommandPanel() }
        commandBar.spaceName = { [weak self] id in self?.store.space(id)?.title ?? "" }
    }

    // MARK: Observation

    private func observeStore() {
        withObservationTracking {
            _ = store.revision
            _ = store.prefs
            _ = store.settings
            _ = store.spaces
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeStore()
            }
        }
    }

    func refresh() {
        let space = store.focusedSpace
        let palette = space.theme.palette
        shell.backgroundHost.rootView = SpaceBackground(palette: palette, pager: SpacePager(store: store, ui: sidebarUI))
        shell.placeholderHost.rootView = AnyView(EmptyContentView(space: space))
        shell.isDarkTheme = palette.isDark
        window?.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        // Vibrant themes see through to the desktop like Arc; others are opaque.
        shell.vibrancy.isHidden = !palette.vibrant
        shell.vibrancyLift.isHidden = !palette.vibrant
        shell.vibrantDark = palette.isDark
        shell.vibrantLight = palette.vibrant && !palette.isDark
        shell.refreshLift()
        window?.isOpaque = !palette.vibrant
        window?.backgroundColor = palette.vibrant ? .clear : NSColor(palette.gradientColors.first ?? .gray)

        browsers.pruneMissingTabs()
        let selected = store.selectedTabID
        // Split view: the selected tab's split decides which panes are on screen.
        let panes = store.visiblePaneTabIDs(in: store.focusedSpaceID)
        let split = selected.flatMap { store.splitContaining($0) }
        let factors = SplitPaneLayout.normalizedFactors(ids: panes, stored: split?.split?.widthFactors ?? [:])
        let empty = Set(panes.filter { store.item($0)?.isEmptyTab == true })
        shell.showToolbar = store.settings.showToolbar
        shell.setPanes(panes, factors: factors, orientation: split?.split?.orientation ?? .horizontal, focused: selected, empty: empty, animated: true)
        for c in shell.paneCards {
            c.toolbarHost.rootView = shell.makeToolbar?(c.tabID == ShellView.noTabID ? nil : c.tabID) ?? AnyView(EmptyView())
        }
        sidebarUI.splitPaneIDs = panes.count > 1 ? panes : []
        if panes != browsers.visibleTabIDs || selected != browsers.visibleTabID
            || panes.contains(where: { browsers.runtime(for: $0) == nil && store.item($0)?.isEmptyTab == false }) {
            browsers.show(panes, focused: selected, focus: !commandBar.isOpen)
        }
        shell.layoutContentChildren()
        syncSidebarUI()
        window?.title = store.selectedTab?.displayTitle ?? space.title

        if store.prefs.sidebarVisible != lastSidebarVisible {
            lastSidebarVisible = store.prefs.sidebarVisible
            // Anchoring while the sidebar floats: bring it home first so it slides from there.
            if lastSidebarVisible { floatingSidebar?.prepareForAnchoring() }
            shell.animateSidebar(visible: lastSidebarVisible, floating: false, fullscreen: shell.contentFullscreen, width: shell.sidebarWidth)
        }
        if CGFloat(store.prefs.sidebarWidth) != lastSidebarWidth {
            lastSidebarWidth = CGFloat(store.prefs.sidebarWidth)
            shell.sidebarWidth = lastSidebarWidth
        }
    }

    private func syncSidebarUI() {
        sidebarUI.loadedTabIDs = Set(browsers.runtimes.keys)
        let b = browsers.visibleRuntime?.browser
        sidebarUI.canGoBack = b?.canGoBack ?? false
        sidebarUI.canGoForward = b?.canGoForward ?? false
        sidebarUI.isLoading = b?.isLoading ?? false
        sidebarUI.pageThemeColor = browsers.visibleRuntime?.themeColor ?? ""
        for (id, rt) in browsers.runtimes { sidebarUI.progress[id] = rt.progress }
        var nav: [UUID: TabNavState] = [:]
        for id in browsers.visibleTabIDs {
            guard let rt = browsers.runtime(for: id) else { continue }
            nav[id] = TabNavState(canGoBack: rt.browser.canGoBack, canGoForward: rt.browser.canGoForward, isLoading: rt.browser.isLoading, themeColor: rt.themeColor)
        }
        if nav != sidebarUI.navStates { sidebarUI.navStates = nav }
    }

    // MARK: Split view

    /// Arc's "Add Split View" (⌃⇧=): a new empty pane opens after the focused
    /// one, with the command bar ready to fill it.
    func addSplitPane() {
        guard let current = store.selectedTabID else { openCommandBar(.newTab); return }
        if store.paneTabIDs(for: current).count >= 4 {
            sidebarUI.flashStatus("Cannot Add New Pane", symbol: "rectangle.portrait.split.2x1.slash")
            return
        }
        guard store.addEmptyPane(nextTo: current) != nil else { return }
        refresh()
        openCommandBar(.editURL)
    }

    /// Arc's "Close this Split Pane" (⌃⇧-): the pane's tab closes like any tab;
    /// the split keeps the other panes.
    func closeSplitPane(_ id: UUID) {
        guard store.splitContaining(id) != nil else { closeTab(id); return }
        if store.item(id)?.isEmptyTab == true {
            store.archiveTab(id, reason: .manual)
        } else {
            closeTab(id)
        }
    }

    /// Arc's "Separate Page from Split View": the pane becomes a normal tab again.
    func separatePane(_ id: UUID) {
        guard store.splitContaining(id) != nil else { return }
        store.separateFromSplit(id)
        store.selectTab(id)
    }

    func cycleSplitPane(_ delta: Int) {
        guard let current = store.selectedTabID else { return }
        let panes = store.paneTabIDs(for: current)
        guard panes.count > 1, let idx = panes.firstIndex(of: current) else { return }
        let n = panes.count
        store.selectTab(panes[((idx + delta) % n + n) % n])
    }

    // MARK: BrowserManagerDelegate

    func browserManagerDidUpdate(_ tabID: UUID) {
        syncSidebarUI()
        let colors = browsers.runtimes.compactMapValues { $0.backgroundColor.isEmpty ? nil : $0.backgroundColor }
        if colors != shell.pageColors { shell.pageColors = colors }
        if tabID == browsers.visibleTabID { window?.title = store.item(tabID)?.displayTitle ?? "Cra" }
    }

    func browserManager(statusMessage: String) {
        overlay.status = statusMessage
        shell.statusVisible = !statusMessage.isEmpty
        shell.layoutContentChildren()
    }

    func browserManager(download: CraDownloadInfo) {
        let name = (download.fullPath as NSString).lastPathComponent.isEmpty ? download.suggestedName : (download.fullPath as NSString).lastPathComponent
        let toast = DownloadToast(id: download.identifier, name: name, percent: download.percent, state: download.state.rawValue, path: download.fullPath)
        if let i = overlay.toasts.firstIndex(where: { $0.id == toast.id }) { overlay.toasts[i] = toast } else { overlay.toasts.append(toast) }
        shell.toastCount = overlay.toasts.count
        overlayPanel?.ignoresMouseEvents = overlay.toasts.isEmpty && !overlay.findVisible
        shell.layoutContentChildren()
        if download.state != .inProgress {
            let id = toast.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                self.overlay.toasts.removeAll { $0.id == id }
                self.shell.toastCount = self.overlay.toasts.count
                self.shell.layoutContentChildren()
            }
        }
    }

    func browserManager(fullscreen: Bool, tabID: UUID) {
        guard let window else { return }
        shell.contentFullscreen = fullscreen
        if fullscreen, !window.styleMask.contains(.fullScreen) {
            enteredFullscreenForContent = true
            window.toggleFullScreen(nil)
        } else if !fullscreen, enteredFullscreenForContent, window.styleMask.contains(.fullScreen) {
            enteredFullscreenForContent = false
            window.toggleFullScreen(nil)
        }
    }

    /// CEF owns the DevTools window (embedding in our NSView trips a Chromium CHECK on macOS).
    /// DevTools docks inside the content card (Chrome's default), to the right of the page.
    func browserManagerDevToolsHost(for tabID: UUID) -> NSView? {
        shell.devToolsVisible = true
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        return shell.devToolsHost
    }

    // MARK: Chrome-style page windows

    private var overlayPanel: NSPanel?
    /// Page area per visible tab, window coordinates (one entry per pane).
    private var lastPaneFrames: [UUID: NSRect] = [:]
    /// While a divider is dragged the page windows follow every mouse move.
    private var pageWindowsFollowLive = false

    private func ensureOverlayPanel() {
        guard overlayPanel == nil, let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        shell.moveOverlays(to: panel.contentView!)
        window.addChildWindow(panel, ordered: .above)
        overlayPanel = panel
    }

    /// Attaches the visible tabs' Chrome windows over their pane areas, hides the others.
    func browserManagerPageWindowsChanged(focus: Bool) {
        guard let window else { return }
        ensureOverlayPanel()
        let visibleIDs = Set(browsers.visibleTabIDs)
        let focused = browsers.visibleRuntime?.hostWindow
        for (id, rt) in browsers.runtimes {
            guard let w = rt.hostWindow else { continue }
            if !visibleIDs.contains(id) { if w.isVisible { w.orderOut(nil) }; continue }
            if w.parent !== window {
                // Borderless: a titled window gets macOS's rounded corners on all four sides,
                // which shows under the toolbar and where the page meets DevTools.
                w.styleMask.remove([.titled, .resizable])
                w.styleMask.insert(.fullSizeContentView)
                ChromiumWindowCorners.setSquare(true, for: w)
                ChromiumChildHover.setDocked(true, for: w)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.isMovable = false
                w.hasShadow = false
                w.isOpaque = false
                w.backgroundColor = .clear
                if let cv = w.contentView {
                    cv.wantsLayer = true
                    cv.layer?.cornerRadius = CraMetrics.contentCornerRadius
                    cv.layer?.cornerCurve = .continuous
                    cv.layer?.maskedCorners = cv.isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                    cv.layer?.masksToBounds = true
                }
                window.addChildWindow(w, ordered: .above)
            }
            positionPageWindows(lastPaneFrames)
            w.orderFront(nil)
            if focus, w === focused {
                w.makeKey()
                devToolsLog("page win \(w.windowNumber) makeKey -> isKey=\(w.isKeyWindow) canBecomeKey=\(w.canBecomeKey) style \(w.styleMask.rawValue)")
            }
        }
        if let dev = browsers.visibleDevToolsWindow, dev.parent === window {
            raisePageWindows(above: dev)
        } else if let panel = overlayPanel {
            // Keep the overlay panel above the page windows.
            window.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    /// Diagnostic log shared with the bridge: `defaults write io.github.rainmiku.cra devToolsLog -bool YES`.
    private static let devToolsLogEnabled = UserDefaults.standard.bool(forKey: "devToolsLog")
    private func devToolsLog(_ message: @autoclosure () -> String) {
        guard Self.devToolsLogEnabled else { return }
        let path = NSTemporaryDirectory() + "cra-devtools.log"
        let line = String(format: "%.3f shell: %@\n", Date().timeIntervalSince1970, message())
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// Every visible page window follows its pane; hidden tabs park on the focused rect.
    private func positionPageWindows(_ frames: [UUID: NSRect]) {
        guard let window, !frames.isEmpty else { return }
        lastPaneFrames = frames
        let focusRect = (browsers.visibleTabID.flatMap { frames[$0] }) ?? frames.values.first!
        let focusPage = browsers.visibleTabID.map { pageRect(forBody: focusRect, tab: $0) } ?? focusRect
        let live = pageWindowsFollowLive || shell.devToolsFrontendDocked
        for (id, rt) in browsers.runtimes {
            guard let w = rt.hostWindow else { continue }
            let body = frames[id] ?? focusRect
            let page = pageRect(forBody: body, tab: id)
            let target = window.convertToScreen(page)
            if w.frame != target { w.setFrame(target, display: live) }
            updatePageCorners(w, page: page, body: body)
            if shell.devToolsFrontendDocked, w.isVisible {
                devToolsLog("page win \(w.windowNumber) '\(w.title)' tab \(id.uuidString.prefix(8)) visible=\(browsers.visibleTabIDs.contains(id)) body \(body) page \(page) style \(w.styleMask.rawValue) parent \(w.parent?.windowNumber ?? -1)")
            }
        }
        let pr: NSRect? = shell.devToolsFrontendDocked ? focusPage : nil
        if shell.frontendPageRect != pr { shell.frontendPageRect = pr }
        let focusOnScreen = window.convertToScreen(focusPage)
        if let panel = overlayPanel, panel.frame != focusOnScreen { panel.setFrame(focusOnScreen, display: true) }
    }

    private func animatePageWindows(to frames: [UUID: NSRect], duration: TimeInterval) {
        guard let window, !frames.isEmpty else { return }
        lastPaneFrames = frames
        let focusRect = (browsers.visibleTabID.flatMap { frames[$0] }) ?? frames.values.first!
        let focusPage = browsers.visibleTabID.map { pageRect(forBody: focusRect, tab: $0) } ?? focusRect
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            for id in browsers.visibleTabIDs {
                guard let w = browsers.runtime(for: id)?.hostWindow, let body = frames[id] else { continue }
                let page = pageRect(forBody: body, tab: id)
                w.animator().setFrame(window.convertToScreen(page), display: true)
                updatePageCorners(w, page: page, body: body)
            }
            if shell.devToolsFrontendDocked, let dev = browsers.visibleDevToolsWindow, dev.parent === window,
               let focusID = browsers.visibleTabID, let body = frames[focusID] {
                dev.animator().setFrame(window.convertToScreen(body), display: true)
            }
            overlayPanel?.animator().setFrame(window.convertToScreen(focusPage), display: true)
        }
    }

    /// Where a page goes inside its pane body: the whole body, or, with Chrome's docked
    /// frontend, the placeholder the frontend reported. The placeholder keeps its offsets
    /// from the body's edges while the body is still resizing, so the page follows at
    /// once instead of waiting for the frontend's next layout.
    private func pageRect(forBody body: NSRect, tab: UUID) -> NSRect {
        guard tab == browsers.visibleTabID, shell.devToolsFrontendDocked,
              browsers.devToolsDockedState[tab] ?? true,
              let p = browsers.devToolsPlaceholders[tab] else { return body }
        let right = max(0, p.frontendSize.width - p.bounds.maxX)
        let bottom = max(0, p.frontendSize.height - p.bounds.maxY)
        let w = max(1, body.width - p.bounds.minX - right)
        let h = max(1, body.height - p.bounds.minY - bottom)
        let r = NSRect(x: body.minX + p.bounds.minX, y: body.minY + bottom, width: w, height: h).intersection(body)
        return r.isEmpty ? body : r
    }

    /// Only the page corners that are card corners get rounded (a page docked beside
    /// DevTools meets it with a straight edge, like Arc).
    private func updatePageCorners(_ w: NSWindow, page: NSRect, body: NSRect) {
        guard let cv = w.contentView, let layer = cv.layer else { return }
        fillContentView(w)
        // Chromium's content view is flipped, so its layer's MinY edge is the top.
        let bottomLeft: CACornerMask = cv.isFlipped ? .layerMinXMaxYCorner : .layerMinXMinYCorner
        let bottomRight: CACornerMask = cv.isFlipped ? .layerMaxXMaxYCorner : .layerMaxXMinYCorner
        var corners: CACornerMask = []
        if abs(page.minY - body.minY) < 0.5 {
            if abs(page.minX - body.minX) < 0.5 { corners.insert(bottomLeft) }
            if abs(page.maxX - body.maxX) < 0.5 { corners.insert(bottomRight) }
        }
        if layer.maskedCorners != corners { layer.maskedCorners = corners }
    }

    /// Chromium lays its frameless window's content view out below a 22 pt title bar
    /// that Cra hides, leaving a blank band over the page; make it fill the window.
    private func fillContentView(_ w: NSWindow) {
        guard let cv = w.contentView else { return }
        let full = NSRect(origin: .zero, size: w.frame.size)
        if cv.frame != full { cv.frame = full }
    }

    /// Shows the visible tab's DevTools window and hides the other tabs'. Chrome-style
    /// pages get Chrome's dockable frontend (see CraCEF's DevToolsClient): its window
    /// spans the card body under the page, which is laid over the placeholder it
    /// reports. Alloy pages keep the shell's own split with CEF's window on the right.
    func browserManagerDevToolsChanged() {
        guard let window else { return }
        let visible = browsers.visibleDevToolsWindow
        for (_, view) in browsers.devToolsViews {
            if let w = view.window, w !== visible { w.orderOut(nil) }
        }
        let selfDock = visible != nil && browsers.visibleRuntime?.hostWindow != nil
        let docked = browsers.visibleTabID.flatMap { browsers.devToolsDockedState[$0] } ?? true
        devToolsLog("devToolsChanged visible=\(visible?.windowNumber ?? -1) selfDock=\(selfDock) docked=\(docked) visibleTabs=\(browsers.visibleTabIDs.map { $0.uuidString.prefix(8) }) overlay=\(overlayPanel?.windowNumber ?? -1)")
        shell.devToolsFrontendDocked = selfDock
        shell.devToolsVisible = visible != nil && (docked || !selfDock)
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        guard let w = visible else {
            if shell.frontendPageRect != nil { shell.frontendPageRect = nil }
            positionPageWindows(lastPaneFrames)
            return
        }
        if selfDock && !docked {
            detachDevToolsWindow(w)
            positionPageWindows(lastPaneFrames)
            return
        }
        attachDevToolsWindow(w, selfDock: selfDock)
        positionDevToolsWindow((shell.devToolsHost.superview ?? shell.contentContainer).convert(shell.devToolsHost.frame, to: nil))
        w.orderFront(nil)
        raisePageWindows(above: w)
        positionPageWindows(lastPaneFrames)
    }

    /// The docked frontend moved its placeholder (also streamed while its splitter is dragged).
    func browserManagerDevToolsPageBoundsChanged() {
        positionPageWindows(lastPaneFrames)
        if Self.devToolsLogEnabled, devToolsTreeDumps < 2 {
            devToolsTreeDumps += 1
            if let dev = browsers.visibleDevToolsWindow { devToolsLog("devtools win \(dev.windowNumber) style \(dev.styleMask.rawValue) close=\(buttonState(dev)) opaque=\(dev.isOpaque)\n" + viewTree(dev.contentView)) }
            if let page = browsers.visibleRuntime?.hostWindow { devToolsLog("page win \(page.windowNumber) style \(page.styleMask.rawValue) close=\(buttonState(page)) opaque=\(page.isOpaque) key=\(page.isKeyWindow)\n" + viewTree(page.contentView)) }
            if let panel = overlayPanel { devToolsLog("overlay \(panel.windowNumber) style \(panel.styleMask.rawValue) frame \(panel.frame)\n" + viewTree(panel.contentView, max: 1)) }
        }
    }
    private var devToolsTreeDumps = 0
    private func buttonState(_ w: NSWindow) -> String {
        guard let b = w.standardWindowButton(.closeButton) else { return "none" }
        return "hidden=\(b.isHidden) alpha=\(b.alphaValue) frame=\(b.frame) superHidden=\(b.superview?.isHidden ?? false)"
    }
    private func viewTree(_ v: NSView?, depth: Int = 0, max: Int = 3) -> String {
        guard let v else { return "(nil)\n" }
        var s = String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden)\n"
        if depth < max { for sub in v.subviews { s += viewTree(sub, depth: depth + 1, max: max) } }
        return s
    }

    private func attachDevToolsWindow(_ w: NSWindow, selfDock: Bool) {
        guard let window else { return }
        if w.parent !== window {
            // CEF made a normal window; strip its chrome so only the DevTools content shows.
            // Not resizable: the edge zone outside a resizable window would take drags
            // meant for the frontend's splitter (undocking makes it resizable again).
            w.styleMask.remove([.titled, .resizable])
            w.styleMask.insert(.fullSizeContentView)
            ChromiumWindowCorners.setSquare(true, for: w)
            ChromiumChildHover.setDocked(true, for: w)
            w.styleMask.remove([.closable, .miniaturizable])
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(type)?.isHidden = true }
            w.hasShadow = false
            w.isMovable = false
            w.isMovableByWindowBackground = false
            w.isOpaque = false
            w.backgroundColor = .clear
            window.addChildWindow(w, ordered: .above)
            fillContentView(w)
            if selfDock { setDevToolsTitleBarInset(nil) }
        }
        if let cv = w.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = CraMetrics.contentCornerRadius
            cv.layer?.cornerCurve = .continuous
            // Frontend-docked: the window spans the card body, so both bottom corners are
            // card corners. Shell-docked (Alloy): it sits right of the page.
            let bottom: CACornerMask = cv.isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            cv.layer?.maskedCorners = selfDock ? bottom : [.layerMaxXMaxYCorner, .layerMaxXMinYCorner]
            cv.layer?.masksToBounds = true
        }
    }

    /// "Undock into separate window": the frontend's window becomes a floating window of its own.
    private func detachDevToolsWindow(_ w: NSWindow) {
        guard let window else { return }
        if w.parent === window {
            window.removeChildWindow(w)
            // A normal titled window, like Chrome's undocked "DevTools - <url>" (the
            // frontend draws under a real title bar; attach strips all of this again).
            w.styleMask.remove(.fullSizeContentView)
            w.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
            ChromiumWindowCorners.setSquare(false, for: w)
            ChromiumChildHover.setDocked(false, for: w)
            w.titlebarAppearsTransparent = false
            w.titleVisibility = .visible
            if let url = store.selectedTab?.tab?.url {
                w.title = "DevTools - " + url.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
            }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(type)?.isHidden = false }
            w.hasShadow = true
            w.isMovable = true
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            if let cv = w.contentView {
                cv.layer?.cornerRadius = 0
                cv.layer?.masksToBounds = false
            }
            let f = window.frame
            let size = NSSize(width: min(1100, f.width * 0.8), height: min(760, f.height * 0.8))
            w.setFrame(NSRect(x: f.midX - size.width / 2 + 40, y: f.midY - size.height / 2 - 20, width: size.width, height: size.height), display: true)
            setDevToolsTitleBarInset(w)
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// CEF's frame view keeps a frameless window's content view at full window size, so
    /// the undocked window's title bar covers the top of the frontend; move the
    /// frontend's layout down by the title bar's height instead (0 when docked).
    private func setDevToolsTitleBarInset(_ w: NSWindow?) {
        let inset = w.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        let css = inset > 0 ? "body{margin-top:\(Int(inset))px!important;height:calc(100% - \(Int(inset))px)!important}" : ""
        currentBrowser?.executeJavaScript("(function(){var s=document.getElementById('cra-titlebar-inset');"
            + "if(!s){s=document.createElement('style');s.id='cra-titlebar-inset';document.head.appendChild(s);}"
            + "s.textContent='\(css)';})();", inDevTools: true)
    }

    /// Page windows go above the DevTools window (which spans the body when the frontend
    /// docks), and the overlay panel above everything.
    private func raisePageWindows(above dev: NSWindow) {
        guard let window else { return }
        // Child windows ignore orderWindow:relativeTo:; re-adding a child puts it above its siblings.
        for id in browsers.visibleTabIDs {
            guard let w = browsers.runtime(for: id)?.hostWindow, w.parent === window else { continue }
            window.removeChildWindow(w)
            window.addChildWindow(w, ordered: .above)
            w.orderFront(nil)
        }
        if let panel = overlayPanel {
            window.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    private func positionDevToolsWindow(_ rectInWindow: NSRect) {
        guard let window, let w = browsers.visibleDevToolsWindow, w.parent === window else { return }
        let onScreen = window.convertToScreen(rectInWindow)
        if w.frame != onScreen { w.setFrame(onScreen, display: true) }
        fillContentView(w)
        if let cv = w.contentView, let id = browsers.visibleTabID, let v = browsers.devToolsViews[id], v.frame != cv.bounds {
            v.frame = cv.bounds
        }
    }

    func browserManagerHandleKey(_ event: NSEvent) -> Bool { app.handleReservedKey(event) }
    func browserManagerHandleUnhandledKey(_ event: NSEvent) -> Bool { app.handleUnhandledKey(event) }
    /// A hidden page asked for focus: the Picture in Picture window's "back to tab" button.
    func browserManagerFocusedBrowser(_ tabID: UUID) {
        guard tabID != browsers.visibleTabID else { return }
        // Split view: clicking into another pane focuses it (Arc: focusedContentID
        // follows the click); its toolbar gets the options button and shortcuts act on it.
        if browsers.visibleTabIDs.contains(tabID) {
            store.selectTab(tabID)
            return
        }
        guard browsers.runtime(for: tabID)?.browser.isInPictureInPicture == true else { return }
        store.selectTab(tabID)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Tabs

    /// cra://debug?devtoolsjs=…: run script in the current tab's DevTools frontend.
    func debugRunInDevTools(_ script: String) { currentBrowser?.executeJavaScript(script, inDevTools: true) }

    func closeCurrentTab() {
        // ⌘W with tabs picked in the sidebar closes all of them.
        if !sidebarUI.multiSelection.isEmpty {
            let ids = sidebarUI.multiSelection
            sidebarUI.clearPicks()
            for id in ids where id != store.selectedTabID { closeTab(id) }
            if let open = store.selectedTabID, ids.contains(open) { closeTab(open) }
            return
        }
        guard let id = store.selectedTabID else { return }
        closeTab(id)
    }

    /// Today tabs are archived. Pinned tabs and favorites stay; they unload
    /// and return to their pinned page (Arc's close-on-pinned behaviour).
    func closeTab(_ id: UUID) {
        guard let item = store.item(id), item.isTab else { return }
        if store.isPinned(id) {
            let wasSelected = store.selectedTabID == id
            _ = store.resetPinnedTab(id)
            browsers.unload(id)
            if wasSelected {
                let back = item.tab?.activeTabBeforeCreationID
                if let back, store.item(back)?.isTab == true, store.spaceID(ofItem: back) == store.focusedSpaceID {
                    store.selectTab(back)
                } else {
                    store.selectTab(nil)
                }
            }
        } else {
            store.archiveTab(id, reason: .manual)
        }
    }

    func resetPinnedTab(_ id: UUID) {
        guard let home = store.resetPinnedTab(id) else { return }
        browsers.runtime(for: id)?.browser.loadURL(home)
    }

    func cycleTab(_ delta: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID)
        guard !tabs.isEmpty else { return }
        let idx = store.selectedTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? -1
        let n = tabs.count
        store.selectTab(tabs[((idx + delta) % n + n) % n].id)
    }

    func zoom(by delta: Double) {
        guard let b = currentBrowser else { return }
        b.setZoomLevel(b.zoomLevel() + delta)
    }

    /// Arc's Capture: save a PNG of the page area to ~/Downloads.
    func capturePage() {
        guard let window else { return }
        let rectInWindow = shell.webContainer.convert(shell.webContainer.bounds, to: nil)
        var screenRect = window.convertToScreen(rectInWindow)
        // CGWindowList uses top-left origin.
        if let screen = NSScreen.screens.first {
            screenRect.origin.y = screen.frame.height - screenRect.maxY
        }
        let captureWindow = browsers.visibleRuntime?.hostWindow ?? window
        guard let image = CGWindowListCreateImage(screenRect, .optionIncludingWindow, CGWindowID(captureWindow.windowNumber), [.bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cra Capture \(f.string(from: Date())).png")
        try? png.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Sidebar

    func toggleSidebar() {
        store.prefs.sidebarVisible.toggle()
        if !store.prefs.sidebarVisible { setFloatingSidebar(false) }
    }

    /// Arc's floating sidebar lives in its own panel above the page windows (see FloatingSidebarController).
    private(set) var floatingSidebar: FloatingSidebarController?

    private func setFloatingSidebar(_ show: Bool) {
        guard let floatingSidebar else { return }
        if show { if !store.prefs.sidebarVisible { floatingSidebar.show() } } else { floatingSidebar.hide(animated: true) }
    }

    private func installFloatingSidebar() {
        guard let window, floatingSidebar == nil else { return }
        let f = FloatingSidebarController(shell: shell, window: window, palette: { [weak self] in
            self?.store.focusedSpace.theme.palette ?? SpaceTheme.presets[0].palette
        })
        f.sidebarHidden = { [weak self] in self.map { !$0.store.prefs.sidebarVisible } ?? false }
        f.didAttachPanel = { [weak self] in
            // Keep toasts and the find bar above the floating sidebar.
            guard let self, let window = self.window, let panel = self.overlayPanel else { return }
            window.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        f.install()
        floatingSidebar = f
    }

    /// Pages and DevTools are separate Chromium child windows, and Chromium drops a
    /// click on a window that isn't key. In Chrome they share one window, so moving
    /// between the page and DevTools never costs a click: make the target key first.
    /// Only while focus is already inside this window; a click into an inactive Cra
    /// still just activates it, like Chrome.
    private func installChildClickMonitor() {
        childClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window, let target = event.window, target.parent === window,
                  target !== self.overlayPanel, !target.isKeyWindow, target.canBecomeKey, NSApp.isActive,
                  let key = NSApp.keyWindow, key === window || key.parent === window else { return event }
            target.makeKey()
            return event
        }
    }

    /// Two-finger swipes over the sidebar page between spaces the way Dia does
    /// (ARCUI.PageSwipeController): the sidebar strip and the window tint follow the
    /// fingers 1:1, rubber-band past the first and last space, tick a haptic detent at
    /// each page, and on release a zero-bounce spring carries the release speed onto a
    /// page. A gesture locks to one axis early, so vertical list scrolling is untouched.
    private func installSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // The momentum tail of a space swipe belongs to the swipe, not the tab list.
            if !event.momentumPhase.isEmpty { return self.swipeAxis == .horizontal ? nil : event }
            guard event.window === self.window, event.hasPreciseScrollingDeltas else { return event }
            switch event.phase {
            case .mayBegin, .began:
                let p = self.shell.convert(event.locationInWindow, from: nil)
                let overSidebar = (self.shell.sidebarVisible || self.shell.floatingSidebar) && self.shell.sidebarHost.frame.contains(p)
                self.swipeAxis = overSidebar ? .undecided : .vertical
                self.swipeX = 0
                self.swipeY = 0
                return event
            case .changed:
                switch self.swipeAxis {
                case .vertical:
                    return event
                case .undecided:
                    self.swipeX += event.scrollingDeltaX
                    self.swipeY += event.scrollingDeltaY
                    guard max(abs(self.swipeX), abs(self.swipeY)) > 6 else { return event }
                    guard abs(self.swipeX) > abs(self.swipeY) * 1.2, self.store.spaceOrder.count > 1 else {
                        self.swipeAxis = .vertical
                        return event
                    }
                    self.swipeAxis = .horizontal
                    self.beginSpaceSwipe()
                    self.trackSpaceSwipe(by: self.swipeX, at: event.timestamp)
                    return nil
                case .horizontal:
                    self.trackSpaceSwipe(by: event.scrollingDeltaX, at: event.timestamp)
                    return nil
                }
            case .ended, .cancelled:
                guard self.swipeAxis == .horizontal else { return event }
                self.endSpaceSwipe()
                return nil
            default:
                return event
            }
        }
    }

    private func beginSpaceSwipe() {
        swipeTravel = 0
        swipeSamples = []
        swipeDetent = 0
        sidebarUI.spaceSettleVelocity = 0
    }

    private func trackSpaceSwipe(by dx: CGFloat, at time: TimeInterval) {
        let width = max(1, shell.sidebarWidth)
        swipeTravel += dx
        swipeSamples.append((time, dx))
        swipeSamples.removeAll { time - $0.time > 0.08 }
        let index = CGFloat(store.spaceOrder.firstIndex(of: store.focusedSpaceID) ?? 0)
        let first = -index, last = CGFloat(store.spaceOrder.count - 1) - index
        // Content follows the fingers (natural scrolling: fingers left = next space).
        var pages = max(-1, min(1, -swipeTravel / width))
        // Rubber band past either end, with the resistance curve AppKit scroll views use.
        func band(_ x: CGFloat) -> CGFloat { 1 - 1 / (x * 0.55 + 1) }
        if pages < first { pages = first - band(first - pages) * 0.5 }
        if pages > last { pages = last + band(pages - last) * 0.5 }
        sidebarUI.spaceSwipe = pages
        // Dia: performsPageDetentHaptics, a tick each time the nearest page changes.
        let detent = Int(pages.rounded())
        if detent != swipeDetent, detent >= Int(first), detent <= Int(last) {
            swipeDetent = detent
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func endSpaceSwipe() {
        let width = max(1, shell.sidebarWidth)
        let pages = sidebarUI.spaceSwipe
        let span = (swipeSamples.last?.time ?? 0) - (swipeSamples.first?.time ?? 0)
        let moved = swipeSamples.reduce(0) { $0 + $1.dx }
        // Pages per second; a lone sample carries no timing, so treat it as a slow lift.
        let velocity = span > 0.004 ? -moved / CGFloat(span) / width : 0
        let index = store.spaceOrder.firstIndex(of: store.focusedSpaceID) ?? 0
        var step = 0
        if abs(velocity) > 0.8 { step = velocity > 0 ? 1 : -1 } else if abs(pages) > 0.5 { step = pages > 0 ? 1 : -1 }
        if !(0..<store.spaceOrder.count).contains(index + step) { step = 0 }
        let remaining = CGFloat(step) - pages
        sidebarUI.spaceSettleVelocity = abs(remaining) > 0.001 ? Double(max(-4, min(12, velocity / remaining))) : 0
        withAnimation(sidebarUI.spaceSettleAnimation) {
            sidebarUI.spaceSwipe = 0
            if step != 0 { store.focusSpace(store.spaceOrder[index + step]) }
        }
        // Clicks and shortcuts that switch spaces later start from rest.
        DispatchQueue.main.async { [weak self] in self?.sidebarUI.spaceSettleVelocity = 0 }
    }

    // MARK: Extensions

    private lazy var toolbarExtensionsMenu = ExtensionsMenu(app: app)

    /// Screen y of the focused card's toolbar bottom (its top edge when the toolbar is hidden),
    /// and the card's right edge.
    private func toolbarBottomOnScreen() -> (y: CGFloat, cardMaxX: CGFloat)? {
        guard let window else { return nil }
        let card = shell.focusedCard.map { shell.contentContainer.convert($0.frame, to: nil) }
            ?? shell.convert(shell.contentContainer.frame, to: nil)
        let onScreen = window.convertToScreen(card)
        return (onScreen.maxY - (store.settings.showToolbar ? CraMetrics.toolbarHeight : 0), onScreen.maxX)
    }

    /// Runs an extension's toolbar action on the focused page, like Arc's toolbar buttons and
    /// Dia's Extensions menu. The popup hangs under the toolbar, its right edge at `buttonRightX`
    /// (screen x; nil = the card's right end, for the menu bar).
    func runExtensionAction(_ id: String, buttonRightX: CGFloat? = nil) {
        guard let bar = toolbarBottomOnScreen(), let browser = currentBrowser else { openExtensionPopupPage(id); return }
        let anchor = NSPoint(x: buttonRightX ?? bar.cardMaxX - 8, y: bar.y)
        Task {
            if await !ExtensionActions.shared.run(id, on: browser, anchor: anchor) { self.openExtensionPopupPage(id) }
        }
    }

    /// Without the DevTools pipe (or for a page it cannot reach): the popup page in a Little
    /// Window, else the options page, else Chrome's details page for the extension.
    private func openExtensionPopupPage(_ id: String) {
        guard let e = ExtensionStore.shared.entries.first(where: { $0.extensionID == id }) else { return }
        let base = "chrome-extension://\(id)/"
        if let popup = e.popupPath {
            _ = app.openLittleWindow(url: base + popup)
        } else {
            store.createTab(url: e.optionsPath.map { base + $0 } ?? "chrome://extensions/?id=\(id)", select: true)
        }
    }

    /// Arc's toolbar Extensions button: the same menu as the menu bar's Extensions menu,
    /// dropped just under the button.
    private func showToolbarExtensionsMenu() {
        guard let window, let content = window.contentView, let bar = toolbarBottomOnScreen() else { return }
        let menu = toolbarExtensionsMenu.makeMenu()
        let point = window.convertPoint(fromScreen: NSPoint(x: NSEvent.mouseLocation.x - 14, y: bar.y - 2))
        menu.popUp(positioning: nil, at: content.convert(point, from: nil), in: content)
    }

    // MARK: Command bar

    func openCommandBar(_ mode: CommandBarMode) {
        guard let window else { return }
        // An empty split pane gets Arc's "Search or Enter URL…" bar; the result fills the pane.
        let fillingEmptyPane = store.selectedTab?.isEmptyTab == true
        let prefill = mode == .editURL && !fillingEmptyPane ? store.selectedTab?.tab?.url : nil
        let effectiveMode: CommandBarMode = (mode == .editURL && (store.selectedTab == nil || fillingEmptyPane)) ? .newTab : mode
        commandBar.highlight = store.focusedSpace.theme.palette.commandHighlight
        commandBar.focusedSpaceID = store.focusedSpaceID
        commandBar.open(mode: effectiveMode, prefill: prefill)
        // Always centred in the window, also when opened from the toolbar.
        commandBar.attached = false
        commandBar.panelWidth = min(CraMetrics.commandBarWidth, window.frame.width - 80)
        commandPanel.appearance = nil
        positionCommandPanel()
        if commandPanel.parent == nil { window.addChildWindow(commandPanel, ordered: .above) }
        commandBarOpenedAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        // Key immediately (typing never waits); CommandBarView fades itself in.
        commandPanel.makeKeyAndOrderFront(nil)
        observeCommandBar()
    }

    private func observeCommandBar() {
        guard !commandObserving else { return }
        commandObserving = true
        withObservationTracking {
            _ = commandBar.result.items.count
            _ = commandBar.isOpen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.commandObserving = false
                guard let self, self.commandBar.isOpen else { return }
                self.positionCommandPanel()
                self.observeCommandBar()
            }
        }
    }

    private func positionCommandPanel() {
        guard let window else { return }
        let rows = commandBar.result.items.count
        let h = CommandBarView.height(forRows: rows)
        let w = commandBar.panelWidth
        let wf = window.frame
        commandPanel.setFrame(NSRect(x: wf.midX - w / 2, y: wf.midY - h / 2 + 40, width: w, height: h), display: true)
    }

    private func hideCommandPanel() {
        if commandPanel.parent != nil { window?.removeChildWindow(commandPanel) }
        let panel = commandPanel!
        // Let CommandBarView's fade-out (0.08 s) play before the panel goes away.
        panel.orderOut(nil)
        window?.makeKeyAndOrderFront(nil)
        currentBrowser?.setFocused(true)
    }

    private func handleCommit(_ s: Suggestion?, typed: String, mode: CommandBarMode, forceNewTab: Bool) {
        let query = commandBar.query
        func open(_ url: String) {
            store.recordQuerySelection(query: query, url: url)
            let fillsEmptyPane = store.selectedTab?.isEmptyTab == true
            if (mode == .editURL || fillsEmptyPane) && !forceNewTab, store.selectedTabID != nil {
                loadInSelectedTab(url)
            } else {
                store.createTab(url: url)
            }
        }
        guard let s else {
            if typed.isEmpty { return }
            open(SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : store.settings.searchEngine.searchURL(typed))
            return
        }
        switch s.kind {
        case .switchToTab(let id):
            store.recordQuerySelection(query: query, url: s.url ?? "")
            store.selectTab(id)
        case .archived(let id):
            store.restoreArchived(id)
        case .navigate:
            let url = typed == commandBar.query ? (s.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed)
            open(url)
        case .search:
            open(s.url ?? store.settings.searchEngine.searchURL(typed))
        case .history, .topDomain:
            open(s.url ?? "")
        case .command(let id):
            app.perform(id)
        case .switchSpace(let id):
            store.focusSpace(id)
        case .moveToSpace(let id):
            if let t = store.selectedTabID { store.moveTab(t, toSpace: id) }
        case .moveToFolder(let id):
            if let t = store.selectedTabID { store.moveItem(t, to: id, index: nil) }
        }
    }

    /// Navigate the focused tab (an empty split pane gets its first page here).
    func loadInSelectedTab(_ url: String) {
        guard let id = store.selectedTabID else { return }
        let wasEmpty = store.item(id)?.isEmptyTab == true
        store.updateTab(id, url: url)
        if let rt = browsers.ensureRuntime(for: id), !wasEmpty { rt.browser.loadURL(url) }
        refresh()
        browsers.show(store.visiblePaneTabIDs(in: store.focusedSpaceID), focused: id, focus: true)
    }

    // MARK: Find

    func showFindBar() {
        overlay.findVisible = true
        overlay.findFocusToken += 1
        shell.findVisible = true
        overlayPanel?.ignoresMouseEvents = false
        overlayPanel?.makeKeyAndOrderFront(nil)
        shell.layoutContentChildren()
        window?.makeFirstResponder(shell.findHost)
    }

    func hideFindBar() {
        overlay.findVisible = false
        shell.findVisible = false
        overlayPanel?.ignoresMouseEvents = overlay.toasts.isEmpty
        currentBrowser?.stopFinding(true)
        shell.layoutContentChildren()
        currentBrowser?.setFocused(true)
    }

    func findNext(forward: Bool) {
        if !overlay.findVisible { showFindBar(); return }
        find(overlay.findQuery, forward: forward, next: true)
    }

    private func find(_ q: String, forward: Bool, next: Bool) {
        guard let b = currentBrowser else { return }
        if q.isEmpty { b.stopFinding(true); return }
        b.findText(q, forward: forward, matchCase: false, findNext: next)
    }

    // MARK: Sheets

    func showSpaceEditor(space: Space?) {
        guard let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let view = SpaceEditorView(existing: space, onSave: { [weak self, weak panel] title, emoji, theme in
            guard let self else { return }
            if var s = space {
                s.title = title; s.emoji = emoji; s.theme = theme
                self.store.updateSpace(s)
            } else {
                self.store.createSpace(title: title, emoji: emoji, theme: theme)
            }
            if let panel { window.endSheet(panel) }
        }, onCancel: { [weak panel] in if let panel { window.endSheet(panel) } })
        panel.contentView = NSHostingView(rootView: view)
        spaceEditor = panel
        window.beginSheet(panel) { [weak self] _ in self?.spaceEditor = nil }
    }

    /// Dia-style import window (UI/Onboarding): browser, spaces, extensions, progress.
    /// `firstRun` makes it the onboarding: shown instead of this window, not closable.
    func showImport(firstRun: Bool = false) {
        if let existing = importWindow { existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = ImportWindowController(store: store, favicons: app.favicons, firstRun: firstRun,
                                                onFinish: { [weak self] outcome in self?.app.importFinished(outcome, firstRun: firstRun) },
                                                onClosed: { [weak self] in self?.importWindow = nil })
        importWindow = controller
        controller.show(over: firstRun ? nil : window)
    }

    /// Brings the import window forward if one is open (Dock clicks during onboarding).
    func raiseImport() -> Bool {
        guard let w = importWindow?.window else { return false }
        w.makeKeyAndOrderFront(nil)
        return true
    }

    /// Close whatever transient UI is up (used by cra://dismiss for scripting).
    func dismissTransientUI() {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        importWindow?.close()
        commandBar.close()
        if overlay.findVisible { hideFindBar() }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        shell.needsLayout = true
        browsers.layoutVisible()
        if commandBar.isOpen { positionCommandPanel() }
        floatingSidebar?.reposition()
        saveFrame()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // The area under the pages shows while they catch up; make sure it has their current colour.
        for id in browsers.visibleTabIDs { browsers.runtime(for: id)?.browser.probeBackgroundColor() }
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if commandBar.isOpen { positionCommandPanel() }
        floatingSidebar?.reposition()
        saveFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { shell.windowActive = true }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === commandPanel, commandBar.isOpen else { return }
        if Date().timeIntervalSince(commandBarOpenedAt) < 0.6 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.commandBar.isOpen else { return }
                self.commandPanel.makeKeyAndOrderFront(nil)
            }
            return
        }
        commandBar.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { shell.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        if shell.contentFullscreen { shell.contentFullscreen = false }
        enteredFullscreenForContent = false
        shell.needsLayout = true
    }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        store.prefs.windowFrame = NSStringFromRect(window.frame)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { commandBar.close() }
        return true
    }
}


/// Window with Arc's taller title row: the traffic lights sit 24pt from the top.
/// They always show in colour, like Dia (Arc mutes them to grey discs until hovered).
final class CraWindow: NSWindow {
    /// AppKit's private per-button hook: the window buttons keep their colours
    /// while the window or the app is inactive. Nothing else about the window's
    /// inactive look changes.
    @objc(_hasActiveAppearanceForStandardWindowButton:)
    func hasActiveAppearance(forStandardWindowButton type: UInt) -> Bool { true }

    /// The real title bar is hidden under the content, so double-clicks on the
    /// header strip never reach AppKit's zoom handling. The SwiftUI header rows
    /// call this on a double-click of their empty parts; it performs the system
    /// "double-click a window's title bar" action from System Settings.
    func performTitleDoubleClickAction() {
        guard !styleMask.contains(.fullScreen) else { return }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "None": break
        case "Minimize": miniaturize(nil)
        default: zoom(nil)   // "Maximize" and "Fill"
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        positionTrafficLights()
    }

    private func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen) else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = standardWindowButton(type), let sv = b.superview else { continue }
            let x: CGFloat = 13 + CGFloat(i) * 24
            let y = sv.bounds.height - CraMetrics.titleRowCenter - b.frame.height / 2
            let target = NSPoint(x: x, y: y)
            if abs(b.frame.origin.x - target.x) > 0.5 || abs(b.frame.origin.y - target.y) > 0.5 {
                b.setFrameOrigin(target)
            }
        }
    }
}

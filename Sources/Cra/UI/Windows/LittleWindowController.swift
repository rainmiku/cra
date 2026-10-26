import AppKit
import CraCEF
import SwiftUI

/// Arc's Little Arc, here a "Little Window": links from other apps (and ⌥⌘N)
/// open in a small, sidebar-less window with its own Chromium browser. The
/// page is not in the sidebar. Closing the window archives it to the Library
/// (Arc: archive source `littleArc`); "Open in <Space>" (⌘O) promotes it into a
/// space's Today list, moving the live browser into the main window.
///
/// Geometry and colours were measured from Arc 1.168's Little Arc on 24 Oct
/// 2026 (docs/arc-reverse-engineering.md, "Little Arc"): a 46pt navy strip with
/// muted traffic lights, one full-width search pill, and a split
/// "Open in <Space> ⌘O | ⌄" button; the page fills the rest edge to edge.
@MainActor
@Observable
final class LittleWindowState {
    var url = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var themeColor = ""
    /// The space ⌘O opens into (the focused space when the window was made).
    var targetSpaceID: UUID
    var popupOpen = false
    /// Pointer hover, tracked by AppKit (SwiftUI's onHover sleeps while the
    /// Chrome page window, a child, is the key window).
    var hover: LittleHover = .none
    /// Width of the "Open in" button, reported by SwiftUI for hit-testing.
    var openButtonWidth: CGFloat = 160

    init(targetSpaceID: UUID) { self.targetSpaceID = targetSpaceID }
}

enum LittleHover { case none, pill, puzzle, link, open, chevron }

/// What the strip needs AppKit to do.
@MainActor
final class LittleWindowActions {
    var openCommandBar: () -> Void = {}
    var copyURL: () -> Void = {}
    var promote: (UUID?) -> Void = { _ in }
    var togglePopup: () -> Void = {}
    var closePopup: () -> Void = {}
}

/// Arc's Little Arc chrome, measured at 2x (window 1688×1010, profile "default").
enum LittleMetrics {
    static let barHeight: CGFloat = 46
    static let controlHeight: CGFloat = 30      // pill and button: y 8…38
    static let pillLeft: CGFloat = 83
    static let pillGap: CGFloat = 10            // pill → button
    static let rightMargin: CGFloat = 7
    static let chevronWidth: CGFloat = 29
    static let cornerRadius: CGFloat = 10
    static let popupWidth: CGFloat = 240
    static let popupRowHeight: CGFloat = 54
    static let popupHeaderHeight: CGFloat = 46
    static let commandBarWidth: CGFloat = 500
    static let defaultSize = NSSize(width: 1000, height: 700)
    static let minSize = NSSize(width: 480, height: 360)
    static let openDuration: TimeInterval = 0.12
}

/// Arc renders Little Arc with the default profile's dark palette whatever the
/// focused space's theme is (observed with the light "Victor" space focused).
enum LittlePalette {
    static let bar = Color(red: 12 / 255, green: 9 / 255, blue: 28 / 255)
    static let pill = Color(red: 37 / 255, green: 34 / 255, blue: 52 / 255)
    static let pillHover = Color(red: 45 / 255, green: 46 / 255, blue: 62 / 255)
    static let iconHover = Color(red: 65 / 255, green: 57 / 255, blue: 70 / 255)
    static let icon = Color(red: 110 / 255, green: 111 / 255, blue: 128 / 255)
    static let iconHot = Color(red: 170 / 255, green: 168 / 255, blue: 180 / 255)
    static let text = Color(red: 163 / 255, green: 161 / 255, blue: 169 / 255)
    static let label = Color(red: 130 / 255, green: 131 / 255, blue: 146 / 255)
    static let button = Color(red: 5 / 255, green: 6 / 255, blue: 37 / 255)
    static let buttonBorder = Color(red: 29 / 255, green: 30 / 255, blue: 55 / 255)
    static let buttonHover = Color(red: 22 / 255, green: 23 / 255, blue: 52 / 255)
    static let badge = Color(red: 23 / 255, green: 24 / 255, blue: 50 / 255)
    static let badgeText = Color(red: 139 / 255, green: 140 / 255, blue: 153 / 255)
    static let popupButton = Color(red: 92 / 255, green: 92 / 255, blue: 113 / 255)
    // Hover tips (measured): navy pill, lavender-white text, pale key caps with blue glyphs.
    static let tooltip = Color(red: 10 / 255, green: 13 / 255, blue: 75 / 255)
    static let tooltipText = Color(red: 222 / 255, green: 223 / 255, blue: 253 / 255)
    static let tooltipBorder = Color(red: 34 / 255, green: 37 / 255, blue: 93 / 255)
    static let tooltipCap = Color(red: 211 / 255, green: 212 / 255, blue: 253 / 255)
    static let tooltipCapGlyph = Color(red: 40 / 255, green: 46 / 255, blue: 252 / 255)
    static let barNS = NSColor(red: 12 / 255, green: 9 / 255, blue: 28 / 255, alpha: 1)
    static let buttonNS = NSColor(red: 5 / 255, green: 6 / 255, blue: 37 / 255, alpha: 1)

    /// The space name in "Open in Victor": the target theme's light foreground
    /// (Arc: semanticColorPalette.dark.foregroundPrimary; Victor → #FCEDBC).
    static func spaceName(_ theme: SpaceTheme) -> Color {
        Color(hex: theme.accent ?? theme.colors.first ?? "#FFFFFF").blendedToward(.white, 0.72)
    }
}

@MainActor
final class LittleWindowController: NSWindowController, NSWindowDelegate, @preconcurrency CraBrowserDelegate {
    unowned let app: AppDelegate
    let state: LittleWindowState
    let actions = LittleWindowActions()
    let commandBar: CommandBarController
    private(set) var browser: CraBrowser?
    private let shell: LittleShellView
    private var favicon: NSImage?
    private var promoted = false
    private var commandPanel: CommandBarPanel!
    private var commandHost: NSHostingView<AnyView>!
    private var commandBarOpenedAt = Date.distantPast
    private var commandObserving = false
    private var popup: LittlePopupPanel?
    private var tooltip: LittleTooltipPanel?
    private var tooltipTimer: Timer?

    var store: SidebarStore { app.store }
    var currentURL: String { browser?.currentURL ?? state.url }
    var hasPage: Bool { !currentURL.isEmpty && currentURL != "about:blank" }

    /// `url` nil makes a popup host: the browser adopts the next window.open
    /// CEF hands it (see `CraBrowserDelegate.browser:popupHostForURL:`).
    init(app: AppDelegate, url: String?) {
        self.app = app
        state = LittleWindowState(targetSpaceID: app.store.focusedSpaceID)
        commandBar = CommandBarController(engine: app.engine, store: app.store)
        let size = app.store.prefs.littleWindowSize.map { NSSizeFromString($0) }
            .map { NSSize(width: max(LittleMetrics.minSize.width, $0.width), height: max(LittleMetrics.minSize.height, $0.height)) }
            ?? LittleMetrics.defaultSize
        let window = LittleWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        shell = LittleShellView(frame: window.contentView!.bounds)
        super.init(window: window)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = LittleMetrics.minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Little Window"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LittlePalette.barNS
        window.contentView = shell
        shell.toolbarHost.rootView = AnyView(LittleToolbar(state: state, actions: actions).environment(app.store))
        shell.onHover = { [weak self] h in
            guard let self, self.state.hover != h else { return }
            self.state.hover = h
            self.scheduleTooltip(for: h)
        }
        shell.openButtonWidth = { [weak self] in self?.state.openButtonWidth ?? 160 }
        placeWindow()

        actions.openCommandBar = { [weak self] in self?.openCommandBar() }
        actions.copyURL = { [weak self] in self?.copy(self?.currentURL ?? "") }
        actions.promote = { [weak self] sid in self?.promote(to: sid) }
        actions.togglePopup = { [weak self] in self?.togglePopup() }
        actions.closePopup = { [weak self] in self?.closePopup() }

        commandPanel = CommandBarPanel()
        commandHost = NSHostingView(rootView: AnyView(CommandBarView(controller: commandBar).environment(app.favicons)))
        commandPanel.contentView = commandHost
        commandPanel.delegate = self
        commandBar.onCommit = { [weak self] s, typed, mode, force in self?.handleCommit(s, typed: typed, mode: mode, forceNewTab: force) }
        commandBar.onClose = { [weak self] in self?.hideCommandPanel() }
        commandBar.spaceName = { [weak self] id in self?.store.space(id)?.title ?? "" }

        let b = CraBrowser(frame: shell.page.bounds, url: url.map { $0.isEmpty ? "about:blank" : $0 }, delegate: self)
        attach(b)
        state.url = (url == "about:blank" ? "" : url) ?? ""
    }

    required init?(coder: NSCoder) { fatalError() }

    private func attach(_ b: CraBrowser) {
        browser = b
        // Embedded (Alloy) hosting: the Chromium view lives inside the page area.
        // Chrome-style hosting delivers a window later (-browser:didCreateHostWindow:).
        let v = b.containerView
        v.frame = shell.page.bounds
        v.autoresizingMask = [.width, .height]
        shell.page.addSubview(v)
        shell.onPageFrame = { [weak self] rect in self?.positionHostWindow(rect) }
        if let w = b.hostWindow { attachHostWindow(w) }
    }

    /// Chrome-style hosting: the page is a frameless Chrome window; attach it
    /// as a child window over the page area and round its bottom corners.
    private func attachHostWindow(_ w: NSWindow) {
        guard let window, w.parent !== window else { return }
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovable = false
        w.hasShadow = false
        w.isOpaque = false
        w.backgroundColor = .clear
        if let cv = w.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = LittleMetrics.cornerRadius
            cv.layer?.cornerCurve = .continuous
            cv.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            cv.layer?.masksToBounds = true
        }
        window.addChildWindow(w, ordered: .above)
        positionHostWindow(shell.convert(shell.page.frame, to: nil))
        w.orderFront(nil)
        // The command bar and the spaces popup stay above the page window.
        if commandPanel.parent === window { window.removeChildWindow(commandPanel); window.addChildWindow(commandPanel, ordered: .above) }
    }

    private func positionHostWindow(_ rectInWindow: NSRect) {
        guard let window, let w = browser?.hostWindow, w.parent === window, !rectInWindow.isEmpty else { return }
        let onScreen = window.convertToScreen(rectInWindow)
        if w.frame != onScreen { w.setFrame(onScreen, display: true) }
        if let cv = w.contentView { cv.layer?.cornerRadius = window.styleMask.contains(.fullScreen) ? 0 : LittleMetrics.cornerRadius }
    }

    private func focusPage() {
        guard let b = browser else { return }
        if let w = b.hostWindow, w.parent === window { w.makeKey() }
        b.setFocused(true)
    }

    /// Where the window lands: centred on the screen under the pointer, cascaded
    /// off other little windows.
    private func placeWindow() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, vf.width - 40)
        frame.size.height = min(frame.height, vf.height - 40)
        let n = CGFloat(app.littleWindows.count)
        frame.origin = NSPoint(x: vf.midX - frame.width / 2 + n * 24, y: vf.midY - frame.height / 2 - n * 24)
        frame.origin.x = min(max(vf.minX, frame.origin.x), vf.maxX - frame.width)
        frame.origin.y = min(max(vf.minY, frame.origin.y), vf.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    /// Arc grows the window from a small rectangle under the pointer to its
    /// full frame in about 120 ms (content laid out at full size, no fade).
    func show() {
        guard let window else { return }
        let final = window.frame
        let mouse = NSEvent.mouseLocation
        var start = NSRect(x: mouse.x - 24, y: mouse.y - 15, width: 48, height: 30)
        start.origin.x = min(max(final.minX, start.minX), final.maxX - start.width)
        start.origin.y = min(max(final.minY, start.minY), final.maxY - start.height)
        // Content stays laid out at the full size (Arc clips it); a Chrome page
        // window would stick out of the growing frame, so it waits until the end.
        shell.frozenSize = final.size
        let host = browser?.hostWindow
        if let host, host.parent === window { host.alphaValue = 0 }   // orderOut would detach the child
        window.setFrame(start, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // NSWindow frame animation (animationResizeTime is overridden to 120 ms).
        window.setFrame(final, display: true, animate: true)
        shell.frozenSize = nil
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        if let host, host.parent === window { host.alphaValue = 1 }
        if hasPage { focusPage() } else { openCommandBar() }
    }

    // MARK: Command bar (Arc: clicking the pill or ⌘L opens the command bar in the window)

    func openCommandBar() {
        guard let window else { return }
        tooltipTimer?.invalidate(); hideTooltip()
        closePopup()
        let prefill = hasPage ? currentURL : nil
        commandBar.highlight = store.focusedSpace.theme.palette.commandHighlight
        commandBar.focusedSpaceID = store.focusedSpaceID
        commandBar.open(mode: hasPage ? .editURL : .newTab, prefill: prefill)
        commandBar.attached = false
        commandBar.panelWidth = min(LittleMetrics.commandBarWidth, window.frame.width - 40)
        positionCommandPanel()
        if commandPanel.parent == nil { window.addChildWindow(commandPanel, ordered: .above) }
        commandBarOpenedAt = Date()
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

    /// Arc puts the bar's top a third of the way down the window.
    private func positionCommandPanel() {
        guard let window else { return }
        let h = CommandBarView.height(forRows: commandBar.result.items.count)
        let w = commandBar.panelWidth
        let wf = window.frame
        commandPanel.setFrame(NSRect(x: wf.midX - w / 2, y: wf.maxY - wf.height / 3 - h, width: w, height: h), display: true)
    }

    private func hideCommandPanel() {
        if commandPanel.parent != nil { window?.removeChildWindow(commandPanel) }
        let panel = commandPanel!
        let bar = commandBar
        // Not tied to self: the window may be closing (promotion), and the panel must still go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            if !bar.isOpen { panel.orderOut(nil) }
        }
        guard window?.isVisible == true else { return }
        window?.makeKeyAndOrderFront(nil)
        focusPage()
    }

    private func handleCommit(_ s: Suggestion?, typed: String, mode: CommandBarMode, forceNewTab: Bool) {
        let query = commandBar.query
        func open(_ url: String) {
            store.recordQuerySelection(query: query, url: url)
            navigate(url)
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
            app.main.showWindow(nil)
        case .archived(let id):
            store.restoreArchived(id)
            app.main.showWindow(nil)
        case .navigate:
            open(typed == query ? (s.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed))
        case .search:
            open(s.url ?? store.settings.searchEngine.searchURL(typed))
        case .history, .topDomain:
            open(s.url ?? "")
        case .command(let id):
            app.perform(id)
        case .switchSpace(let id):
            store.focusSpace(id)
        case .moveToSpace(let id):
            promote(to: id)
        case .moveToFolder:
            break
        }
    }

    private func navigate(_ url: String) {
        state.url = url
        browser?.loadURL(url)
        focusPage()
    }

    // MARK: Tooltips (Arc: navy pill under the control after a short hover, key caps for shortcuts)

    private func scheduleTooltip(for h: LittleHover) {
        tooltipTimer?.invalidate()
        hideTooltip()
        let spec: (String, [String])? = switch h {
        case .puzzle: ("Extensions", [])
        case .link: ("Copy URL", ["⇧", "⌘", "C"])
        case .chevron: ("More Spaces", [])
        default: nil
        }
        guard let spec else { return }
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showTooltip(spec.0, caps: spec.1, for: h) }
        }
    }

    private func showTooltip(_ text: String, caps: [String], for h: LittleHover) {
        guard let window, state.hover == h, popup == nil, !commandBar.isOpen else { return }
        let panel = LittleTooltipPanel()
        let host = NSHostingView(rootView: AnyView(LittleTooltip(text: text, caps: caps)))
        let size = host.fittingSize
        host.setFrameSize(size)
        panel.contentView = host
        let w = window.frame.width
        // Centred under the control; the chevron tip hugs the right edge like Arc's.
        let cx: CGFloat = switch h {
        case .puzzle: w - LittleMetrics.rightMargin - state.openButtonWidth - LittleMetrics.pillGap - 46
        case .link: w - LittleMetrics.rightMargin - state.openButtonWidth - LittleMetrics.pillGap - 15
        default: w - LittleMetrics.rightMargin - LittleMetrics.chevronWidth / 2
        }
        var x = window.frame.minX + cx - size.width / 2
        x = min(x, window.frame.maxX - size.width - 4)
        let y = window.frame.maxY - LittleMetrics.barHeight - size.height + 4
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        tooltip = panel
    }

    private func hideTooltip() {
        guard let t = tooltip else { return }
        tooltip = nil
        window?.removeChildWindow(t)
        t.orderOut(nil)
    }

    // MARK: Spaces popup (Arc: LittleBrowserMoveMenu)

    func togglePopup() {
        if popup != nil { closePopup() } else { openPopup() }
    }

    private func openPopup() {
        guard let window, popup == nil else { return }
        tooltipTimer?.invalidate(); hideTooltip()
        commandBar.close()
        let panel = LittlePopupPanel()
        let view = LittleSpacesPopup(state: state, onPick: { [weak self] sid in self?.closePopup(); self?.promote(to: sid) },
                                     onClose: { [weak self] in self?.closePopup() })
            .environment(store)
        let host = NSHostingView(rootView: AnyView(view))
        panel.contentView = host
        panel.delegate = self
        let rows = min(store.spaceOrder.count, 6)
        let h = LittleMetrics.popupHeaderHeight + CGFloat(rows) * LittleMetrics.popupRowHeight
        let wf = window.frame
        panel.setFrame(NSRect(x: wf.maxX - 8 - LittleMetrics.popupWidth, y: wf.maxY - h, width: LittleMetrics.popupWidth, height: h), display: true)
        window.addChildWindow(panel, ordered: .above)
        popup = panel
        state.popupOpen = true
        panel.makeKeyAndOrderFront(nil)
    }

    func closePopup() {
        guard let panel = popup else { return }
        popup = nil
        state.popupOpen = false
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Promote / close

    /// Move the page into a space (nil = the window's target space) as a Today
    /// tab. The live browser goes with it, so history, scroll position and
    /// logins stay.
    func promote(to spaceID: UUID?) {
        guard let b = browser, hasPage else { return }
        closePopup()
        commandBar.close()
        let sid = (spaceID ?? state.targetSpaceID).flatMap { store.space($0) != nil ? $0 : nil } ?? store.focusedSpaceID
        let tab = store.createTab(url: b.currentURL, title: b.currentTitle, in: sid, select: true)
        if let favicon, let key = FaviconCache.key(for: b.currentURL) { app.favicons.store(favicon, forKey: key) }
        promoted = true
        browser = nil
        app.main.browsers.adopt(b, for: tab.id)
        window?.close()
        app.main.showWindow(nil)
        app.main.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Archive the page to the Library (Arc keeps closed Little Arcs there too).
    func archivePage() {
        guard hasPage, !promoted else { return }
        store.archiveLittleWindowPage(url: currentURL, title: browser?.currentTitle ?? state.title)
        if let favicon, let key = FaviconCache.key(for: currentURL) { app.favicons.store(favicon, forKey: key) }
        promoted = true  // archived once; a later close must not archive again
    }

    /// Menu / key actions while this window is key. Returns false for actions
    /// that are not the little window's (the app handles those).
    func handle(action id: String) -> Bool {
        switch id {
        case "closeTab", "closeWindow": closeWindow()
        case "newTab", "editURL": openCommandBar()
        case "goBack": browser?.goBack()
        case "goForward": browser?.goForward()
        case "reload": browser?.reload()
        case "hardReload": browser?.reloadIgnoringCache()
        case "stop": browser?.stopLoading()
        case "zoomIn": if let b = browser { b.setZoomLevel(b.zoomLevel() + 0.5) }
        case "zoomOut": if let b = browser { b.setZoomLevel(b.zoomLevel() - 0.5) }
        case "resetZoom": browser?.setZoomLevel(0)
        case "copyURL": copy(currentURL)
        case "copyURLMarkdown": copy("[\(browser?.currentTitle ?? state.title)](\(currentURL))")
        case "viewSource": browser?.viewSource()
        case "devTools", "jsConsole", "inspectElement": browser?.showDevTools()
        case "print": browser?.print()
        case "promoteLittleWindow": promote(to: nil)
        // No find bar or capture in little windows; keep them off the main window.
        case "find", "findNext", "findPrevious", "capturePage", "toggleSidebar", "pinTab", "favoriteTab", "renameTab",
             "duplicateTab", "resetTab", "muteTab", "clearToday", "nextTab", "previousTab", "recentTab":
            break
        default: return false
        }
        return true
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// ⌘W / Close Window: the same path as the close button. (performClose is
    /// skipped: it refuses to act while the standard buttons are dimmed.)
    func closeWindow() {
        guard let window, window.isVisible, windowShouldClose(window) else { return }
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        tooltipTimer?.invalidate(); hideTooltip()
        closePopup()
        commandBar.close()
        archivePage()
        if let b = browser {
            b.containerView.isHidden = true
            if let w = b.hostWindow, w.parent === sender { sender.removeChildWindow(w); w.orderOut(nil) }
            b.close()  // -browserDidClose: drops the controller
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if browser == nil { app.removeLittleWindow(self) }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, (notification.object as? NSWindow) === window, !window.styleMask.contains(.fullScreen) else { return }
        if commandBar.isOpen { positionCommandPanel() }
        if popup != nil { closePopup() }
        store.prefs.littleWindowSize = NSStringFromSize(window.frame.size)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        browser?.probeBackgroundColor()
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if commandBar.isOpen { positionCommandPanel() }
        if popup != nil { closePopup() }
    }

    func windowDidResignKey(_ notification: Notification) {
        let w = notification.object as? NSWindow
        if w === popup {
            DispatchQueue.main.async { [weak self] in
                guard let self, let p = self.popup, !p.isKeyWindow else { return }
                self.closePopup()
            }
            return
        }
        guard w === commandPanel, commandBar.isOpen else { return }
        if Date().timeIntervalSince(commandBarOpenedAt) < 0.6 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.commandBar.isOpen else { return }
                self.commandPanel.makeKeyAndOrderFront(nil)
            }
            return
        }
        commandBar.close()
    }

    // MARK: CraBrowserDelegate

    func browser(_ browser: CraBrowser, didChangeTitle title: String) {
        state.title = title
        window?.title = title.isEmpty ? "Little Window" : title
    }

    func browser(_ browser: CraBrowser, didChangeURL url: String) {
        if url.hasPrefix("data:text/html;base64,") { return }
        state.url = url == "about:blank" ? "" : url
    }

    func browser(_ browser: CraBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = loading
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        if !loading { state.progress = 0 }
    }

    func browser(_ browser: CraBrowser, didChangeProgress progress: Double) { state.progress = progress }

    func browser(_ browser: CraBrowser, didFinishLoadingURL url: String, title: String, statusCode: Int) {
        store.recordVisit(url: url, title: title)
    }

    func browser(_ browser: CraBrowser, didLoadFavicon image: NSImage, forURL iconURL: String) {
        favicon = image
        if let key = FaviconCache.key(for: browser.currentURL) { app.favicons.store(image, forKey: key) }
    }

    func browser(_ browser: CraBrowser, didReportThemeColor hex: String) { state.themeColor = hex }
    /// The page window trails the shell during a fast resize; the gap shows the page's colour.
    func browser(_ browser: CraBrowser, didReportBackgroundColor hex: String) {
        shell.page.layer?.backgroundColor = NSColor(Color(hex: hex)).cgColor
    }
    func browser(_ browser: CraBrowser, didChangeStatusMessage message: String) {}

    // Little windows never dock DevTools (CEF opens its own window for them).
    func browser(_ browser: CraBrowser, devToolsPageBounds bounds: NSRect) {}
    func browser(_ browser: CraBrowser, devToolsDocked docked: Bool) {}
    func browser(_ browser: CraBrowser, didChangeFullscreen fullscreen: Bool) {
        guard let window else { return }
        if fullscreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Links that want a new tab open another little window (Arc does the same).
    func browser(_ browser: CraBrowser, requestsNewTabWithURL url: String, inBackground background: Bool) {
        if url.hasPrefix("cra://") { return }  // pages never drive the app
        app.openLittleWindow(url: url, activate: !background)
        if background { window?.makeKeyAndOrderFront(nil) }
    }

    func browser(_ browser: CraBrowser, popupHostForURL url: String, inBackground background: Bool) -> CraBrowser? {
        if url.hasPrefix("cra://") { return nil }  // pages never drive the app
        let w = app.makeLittleWindow(url: nil)
        w.state.url = url
        w.show()
        if background { window?.makeKeyAndOrderFront(nil) }
        return w.browser
    }

    func devToolsHostView(for browser: CraBrowser) -> NSView? { nil }
    func browser(_ browser: CraBrowser, didCreateDevToolsView view: NSView) {}
    func browser(_ browser: CraBrowser, didCreateHostWindow window: NSWindow) {
        attachHostWindow(window)
        if hasPage, self.window?.isKeyWindow == true || window.isKeyWindow { focusPage() }
    }
    func browserDidCloseDevTools(_ browser: CraBrowser) {}
    func browser(_ browser: CraBrowser, handleKeyEvent event: NSEvent) -> Bool { app.handleReservedKey(event) }
    func browser(_ browser: CraBrowser, handleUnhandledKeyEvent event: NSEvent) -> Bool { app.handleUnhandledKey(event) }
    func browser(_ browser: CraBrowser, didUpdateDownload download: CraDownloadInfo) { app.main.browserManager(download: download) }

    func browser(_ browser: CraBrowser, requestsPermissionForOrigin origin: String, permissions: [String], completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(origin) wants to \(permissions.joined(separator: " and "))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        guard let window else { completion(false); return }
        alert.beginSheetModal(for: window) { resp in completion(resp == .alertFirstButtonReturn) }
    }

    func browserDidReceiveFocus(_ browser: CraBrowser) {}

    func browserDidClose(_ browser: CraBrowser) {
        browser.containerView.removeFromSuperview()
        guard self.browser === browser else { return }
        self.browser = nil
        if let window, window.isVisible {
            // The page closed itself (window.close()); the window goes with it.
            archivePage()
            window.close()
        }
        app.removeLittleWindow(self)
    }
}

/// The navy strip on top, the page edge to edge below.
final class LittleShellView: NSView {
    let toolbarHost = FirstMouseHostingView(rootView: AnyView(EmptyView()))
    let page = NSView()
    /// Reports the page area (window coordinates) so a Chrome-style page window can follow it.
    var onPageFrame: ((NSRect) -> Void)?
    var onHover: ((LittleHover) -> Void)?
    var openButtonWidth: () -> CGFloat = { 160 }
    /// While the window grows open, lay out for this (final) size anchored top-left.
    var frozenSize: NSSize? { didSet { needsLayout = true } }
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = LittlePalette.barNS.cgColor
        toolbarHost.sizingOptions = []
        toolbarHost.isOverControl = { [weak self] p in
            guard let self else { return false }
            // p is in the strip's own coordinates (flipped SwiftUI space: y from the top).
            return self.hoverTarget(x: p.x, y: self.toolbarHost.isFlipped ? p.y : LittleMetrics.barHeight - p.y) != .none
        }
        addSubview(toolbarHost)
        page.wantsLayer = true
        page.layer?.cornerRadius = LittleMetrics.cornerRadius
        page.layer?.cornerCurve = .continuous
        page.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        page.layer?.masksToBounds = true
        page.layer?.backgroundColor = NSColor(white: 34 / 255, alpha: 1).cgColor
        page.autoresizesSubviews = true
        addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        // activeAlways: the strip must react while the page window (a child) is key.
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let inBar = p.y > bounds.height - LittleMetrics.barHeight
        onHover?(inBar ? hoverTarget(x: p.x, y: bounds.height - p.y) : .none)
    }

    /// Mirrors LittleToolbar's layout (pill from x 83, 10pt gap, button, 7pt margin).
    private func hoverTarget(x: CGFloat, y: CGFloat) -> LittleHover {
        guard y >= 8, y <= 8 + LittleMetrics.controlHeight else { return .none }
        let w = bounds.width
        let buttonLeft = w - LittleMetrics.rightMargin - openButtonWidth()
        let pillRight = buttonLeft - LittleMetrics.pillGap
        if x >= LittleMetrics.pillLeft, x < pillRight {
            if abs(x - (pillRight - 46)) <= 13 { return .puzzle }
            if abs(x - (pillRight - 15)) <= 13 { return .link }
            return .pill
        }
        if x >= buttonLeft, x < w - LittleMetrics.rightMargin {
            return x >= w - LittleMetrics.rightMargin - LittleMetrics.chevronWidth ? .chevron : .open
        }
        return .none
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(.none)
    }

    override func layout() {
        super.layout()
        let size = frozenSize ?? bounds.size
        let b = NSRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height)
        let fullscreen = window?.styleMask.contains(.fullScreen) ?? false
        let barH = LittleMetrics.barHeight
        toolbarHost.frame = NSRect(x: 0, y: b.maxY - barH, width: b.width, height: barH)
        page.frame = NSRect(x: 0, y: b.minY, width: b.width, height: max(0, b.height - barH))
        page.layer?.cornerRadius = fullscreen ? 0 : LittleMetrics.cornerRadius
        for sub in page.subviews where sub.frame != page.bounds { sub.frame = page.bounds }
        onPageFrame?(convert(page.frame, to: nil))
    }
}

/// Traffic lights at Arc's spots (x 17/39/61, centred on the strip), always in
/// colour like the main window.
final class LittleWindow: NSWindow {
    /// Window buttons stay coloured while inactive (see CraWindow).
    @objc(_hasActiveAppearanceForStandardWindowButton:)
    func hasActiveAppearance(forStandardWindowButton type: UInt) -> Bool { true }
    /// Arc's open animation: ~120 ms from a small rectangle to the full frame.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { LittleMetrics.openDuration }

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
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = standardWindowButton(type), let sv = b.superview else { continue }
            let target = NSPoint(x: 17 + CGFloat(i) * 22 - b.frame.width / 2, y: sv.bounds.height - LittleMetrics.barHeight / 2 - b.frame.height / 2)
            if abs(b.frame.origin.x - target.x) > 0.5 || abs(b.frame.origin.y - target.y) > 0.5 { b.setFrameOrigin(target) }
        }
    }
}

/// The strip's buttons work on the first click even when the page window holds key
/// status, and only the empty parts of the strip drag the window (a press on the
/// pill or the button must not start a window-move session).
final class FirstMouseHostingView: NSHostingView<AnyView> {
    var isOverControl: ((NSPoint) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool {
        guard let window, let isOverControl else { return true }
        return !isOverControl(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}

/// Borderless, non-activating tooltip panel (never takes key status).
final class LittleTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }
}

/// Arc's hover tip: 28pt navy pill, 14pt semibold text, 20pt key caps.
struct LittleTooltip: View {
    let text: String
    let caps: [String]
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(LittlePalette.tooltipText)
            if !caps.isEmpty {
                HStack(spacing: 4) {
                    ForEach(caps, id: \.self) { c in
                        Text(c)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LittlePalette.tooltipCapGlyph)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(LittlePalette.tooltipCap))
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, caps.isEmpty ? 10 : 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LittlePalette.tooltip))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LittlePalette.tooltipBorder, lineWidth: 1))
        .padding(2)
    }
}

/// Borderless child panel for the spaces menu; takes the keyboard for filtering.
final class LittlePopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: LittleMetrics.popupWidth, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }
}

// MARK: - SwiftUI

/// The strip: search pill with puzzle + link icons, split "Open in <Space> ⌘O | ⌄".
struct LittleToolbar: View {
    let state: LittleWindowState
    let actions: LittleWindowActions
    @Environment(SidebarStore.self) private var store
    private var hoverPill: Bool { state.hover == .pill }
    private var hoverOpen: Bool { state.hover == .open }
    private var hoverChevron: Bool { state.hover == .chevron }

    private var human: String { SuggestionEngine.humanURL(state.url) }
    private var targetSpace: Space { store.space(state.targetSpaceID) ?? store.focusedSpace }

    var body: some View {
        HStack(spacing: LittleMetrics.pillGap) {
            pill
            openIn
        }
        .padding(.leading, LittleMetrics.pillLeft)
        .padding(.trailing, LittleMetrics.rightMargin)
        .frame(height: LittleMetrics.barHeight)
        .frame(maxWidth: .infinity)
        .background(LittlePalette.bar)
        .ignoresSafeArea()
    }

    private var pill: some View {
        ZStack {
            Button { actions.openCommandBar() } label: {
                HStack(spacing: 0) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LittlePalette.icon)
                        .frame(width: 34, alignment: .center)
                    Spacer(minLength: 0)
                }
                .overlay {
                    Text(state.url.isEmpty ? "" : human)
                        .font(.system(size: 13))
                        .foregroundStyle(LittlePalette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 80)
                }
                .frame(maxWidth: .infinity)
                .frame(height: LittleMetrics.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                LittleIcon(symbol: "puzzlepiece.extension", size: 15, hover: state.hover == .puzzle) {}
                LittleIcon(symbol: "link", size: 14, hover: state.hover == .link) { actions.copyURL() }
            }
            .padding(.trailing, 2)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hoverPill ? LittlePalette.pillHover : LittlePalette.pill))
        .help(state.url)
    }

    private var openIn: some View {
        let space = targetSpace
        return HStack(spacing: 0) {
            Button { actions.promote(nil) } label: {
                HStack(spacing: 0) {
                    (Text("Open in ").font(.system(size: 13, weight: .medium)).foregroundStyle(LittlePalette.label)
                        + Text(space.title).font(.system(size: 13, weight: .bold)).foregroundStyle(LittlePalette.spaceName(space.theme)))
                        .lineLimit(1)
                    Text("⌘O")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LittlePalette.badgeText)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LittlePalette.badge))
                        .padding(.leading, 6)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: LittleMetrics.controlHeight)
                .background(hoverOpen ? LittlePalette.buttonHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.url.isEmpty)
            .help("Open this page in \(space.title) as a tab (⌘O)")
            Rectangle().fill(LittlePalette.buttonBorder).frame(width: 1, height: LittleMetrics.controlHeight)
            Button { actions.togglePopup() } label: {
                Image(systemName: state.popupOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(LittlePalette.label)
                    .frame(width: LittleMetrics.chevronWidth, height: LittleMetrics.controlHeight)
                    .background(hoverChevron ? LittlePalette.buttonHover : .clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(LittlePalette.button)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(LittlePalette.buttonBorder, lineWidth: 1))
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear
                .onAppear { state.openButtonWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in state.openButtonWidth = w }
        })
    }
}

/// Icon in the pill: 26pt hover square, brighter glyph.
struct LittleIcon: View {
    let symbol: String
    let size: CGFloat
    var hover = false
    var help: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hover ? LittlePalette.iconHot : LittlePalette.icon)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? LittlePalette.iconHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Arc's LittleBrowserMoveMenu: "Search Spaces…" with a chevron-up button, then
/// one 54pt row per space (40pt tile with the emoji on the space colour).
struct LittleSpacesPopup: View {
    let state: LittleWindowState
    let onPick: (UUID) -> Void
    let onClose: () -> Void
    @Environment(SidebarStore.self) private var store
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var spaces: [Space] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = store.orderedSpaces
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        let list = spaces
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(LittlePalette.icon)
                TextField("Search Spaces…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(selected) { onPick(list[selected].id) } }
                    .onExitCommand { onClose() }
                    .onMoveCommand { dir in
                        guard !list.isEmpty else { return }
                        if dir == .down { selected = (selected + 1) % list.count }
                        if dir == .up { selected = (selected - 1 + list.count) % list.count }
                    }
                Button { onClose() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LittlePalette.popupButton))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 9)
            .frame(height: LittleMetrics.popupHeaderHeight)
            ForEach(Array(list.prefix(6).enumerated()), id: \.element.id) { i, s in
                Button { onPick(s.id) } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: s.theme.accent ?? s.theme.colors.first ?? "#888888"))
                            Text(s.emoji).font(.system(size: 20))
                        }
                        .frame(width: 40, height: 40)
                        Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: LittleMetrics.popupRowHeight)
                    .background(i == selected ? LittlePalette.buttonHover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { selected = i } }
            }
        }
        .frame(width: LittleMetrics.popupWidth)
        .background(LittlePalette.button)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LittlePalette.buttonBorder, lineWidth: 1))
        .onAppear {
            focused = true
            selected = max(0, store.orderedSpaces.firstIndex { $0.id == state.targetSpaceID } ?? 0)
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }
}

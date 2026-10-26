import AppKit
import CraCEF

/// One live Chromium browser for a tab. Tabs that have not been opened since
/// launch have no runtime; archiving a tab destroys its runtime.
@MainActor
final class TabRuntime {
    let tabID: UUID
    let browser: CraBrowser
    var progress: Double = 0
    var themeColor: String = ""
    /// What the page paints behind its content ("#RRGGBB", "" until reported).
    var backgroundColor: String = ""
    /// Cra popped this tab's video out because the user left the tab (Arc's
    /// auto Picture in Picture); coming back brings the video home.
    var autoPictureInPicture = false
    var pendingAutoPictureInPicture = false
    /// Chrome-style hosting: the page's own window (nil until created, or for Alloy).
    var hostWindow: NSWindow? { browser.hostWindow }
    init(tabID: UUID, browser: CraBrowser) {
        self.tabID = tabID
        self.browser = browser
    }
}

@MainActor
protocol BrowserManagerDelegate: AnyObject {
    func browserManagerDidUpdate(_ tabID: UUID)
    func browserManager(statusMessage: String)
    func browserManager(download: CraDownloadInfo)
    func browserManager(fullscreen: Bool, tabID: UUID)
    func browserManagerDevToolsHost(for tabID: UUID) -> NSView?
    /// A DevTools pane appeared or closed; the shell decides whether to show the dock.
    func browserManagerDevToolsChanged()
    /// Chrome's docked frontend moved its page placeholder (streamed while its splitter is dragged).
    func browserManagerDevToolsPageBoundsChanged()
    /// Chrome-style hosting: page windows appeared/changed; the shell re-attaches and orders them.
    func browserManagerPageWindowsChanged(focus: Bool)
    func browserManagerHandleKey(_ event: NSEvent) -> Bool
    func browserManagerHandleUnhandledKey(_ event: NSEvent) -> Bool
    func browserManagerFocusedBrowser(_ tabID: UUID)
}

/// Creates, shows, hides and tears down CEF browsers inside a container view.
@MainActor
final class BrowserManager: NSObject, @preconcurrency CraBrowserDelegate {
    let store: SidebarStore
    let favicons: FaviconCache
    let container: NSView
    weak var delegate: BrowserManagerDelegate?
    private(set) var runtimes: [UUID: TabRuntime] = [:]
    /// The focused pane's tab (the one toolbar actions and DevTools apply to).
    private(set) var visibleTabID: UUID?
    /// Every tab on screen, in pane order (one entry outside split view).
    private(set) var visibleTabIDs: [UUID] = []
    /// Split view: the view a tab's Alloy-hosted Chromium view should live in.
    var paneHost: ((UUID) -> NSView?)?
    private var byBrowser: [ObjectIdentifier: UUID] = [:]

    init(store: SidebarStore, favicons: FaviconCache, container: NSView) {
        self.store = store
        self.favicons = favicons
        self.container = container
    }

    func runtime(for tabID: UUID) -> TabRuntime? { runtimes[tabID] }
    var visibleRuntime: TabRuntime? { visibleTabID.flatMap { runtimes[$0] } }

    @discardableResult
    func ensureRuntime(for tabID: UUID) -> TabRuntime? {
        if let r = runtimes[tabID] { return r }
        // An empty split pane has no page yet (Arc shows the tinted card and the command bar).
        guard let item = store.item(tabID), let tab = item.tab, !item.isEmptyTab else { return nil }
        let browser = CraBrowser(frame: container.bounds, url: tab.url, delegate: self)
        return register(browser: browser, tabID: tabID)
    }

    /// Take over a live browser from elsewhere (a Little Window being promoted
    /// to a tab): it keeps its history, scroll position and page state.
    @discardableResult
    func adopt(_ browser: CraBrowser, for tabID: UUID) -> TabRuntime {
        if let host = browser.hostWindow, let parent = host.parent { parent.removeChildWindow(host) }
        browser.containerView.removeFromSuperview()
        browser.delegate = self
        let rt = register(browser: browser, tabID: tabID)
        store.updateTab(tabID, url: browser.currentURL, title: browser.currentTitle)
        return rt
    }

    /// Popup host: a browser shell CEF will fill with window.open content.
    func makePopupHost(for tabID: UUID) -> CraBrowser {
        let browser = CraBrowser(frame: container.bounds, url: nil, delegate: self)
        register(browser: browser, tabID: tabID)
        return browser
    }

    @discardableResult
    private func register(browser: CraBrowser, tabID: UUID) -> TabRuntime {
        browser.userInfo = tabID.uuidString
        let v = browser.containerView
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        container.addSubview(v)
        let rt = TabRuntime(tabID: tabID, browser: browser)
        runtimes[tabID] = rt
        byBrowser[ObjectIdentifier(browser)] = tabID
        if let t = store.item(tabID)?.tab, t.muted { browser.setAudioMuted(true) }
        return rt
    }

    func show(_ tabID: UUID?, focus: Bool) {
        show(tabID.map { [$0] } ?? [], focused: tabID, focus: focus)
    }

    /// Show several tabs at once (split view); `focused` gets keyboard focus.
    func show(_ tabIDs: [UUID], focused: UUID?, focus: Bool) {
        let newSet = Set(tabIDs)
        for previous in visibleTabIDs where !newSet.contains(previous) { leaveTab(previous) }
        let wasVisible = Set(visibleTabIDs)
        var shown: [UUID] = []
        for id in tabIDs {
            guard let rt = ensureRuntime(for: id) else { shown.append(id); continue }
            if !wasVisible.contains(id) { returnToTab(rt) }
            let v = rt.browser.containerView
            // Alloy hosting only: the Chromium view moves into its pane. Chrome-style
            // pages live in their own windows; re-parenting their view makes Chrome
            // spawn stock windows.
            if rt.browser.hostWindow == nil, let host = paneHost?(id), v.superview !== host {
                v.removeFromSuperview()
                host.addSubview(v)
            }
            v.frame = v.superview?.bounds ?? container.bounds
            v.isHidden = false
            shown.append(id)
        }
        for (id, other) in runtimes where !newSet.contains(id) {
            other.browser.containerView.isHidden = true
            if other.browser.hostWindow == nil, other.browser.containerView.superview !== container {
                other.browser.containerView.removeFromSuperview()
                container.addSubview(other.browser.containerView)
            }
        }
        visibleTabIDs = shown
        visibleTabID = focused.flatMap { newSet.contains($0) ? $0 : nil } ?? shown.first
        if focus, let f = visibleTabID, let rt = runtimes[f] { rt.browser.setFocused(true) }
        syncDevToolsVisibility()
        delegate?.browserManagerPageWindowsChanged(focus: focus)
    }

    func browser(_ browser: CraBrowser, didCreateHostWindow window: NSWindow) {
        delegate?.browserManagerPageWindowsChanged(focus: tabID(of: browser) == visibleTabID)
    }

    func unload(_ tabID: UUID) {
        guard let rt = runtimes[tabID] else { return }
        if visibleTabID == tabID { visibleTabID = nil }
        visibleTabIDs.removeAll { $0 == tabID }
        rt.browser.containerView.isHidden = true
        rt.browser.close()
    }

    /// Drop runtimes whose tabs no longer exist (archived, deleted).
    func pruneMissingTabs() {
        for id in runtimes.keys where store.item(id)?.isTab != true { unload(id) }
    }

    func closeAll() { for id in Array(runtimes.keys) { unload(id) } }

    func layoutVisible() {
        for id in visibleTabIDs {
            guard let v = runtimes[id]?.browser.containerView else { continue }
            v.frame = v.superview?.bounds ?? container.bounds
        }
    }

    private func tabID(of browser: CraBrowser) -> UUID? { byBrowser[ObjectIdentifier(browser)] }

    // MARK: Picture in Picture

    /// Arc: "Enable Picture in Picture when you leave a video tab". The request
    /// goes out before the page is hidden, so the video keeps playing in the
    /// floating window; the page answers through didChangePictureInPicture.
    private func leaveTab(_ tabID: UUID) {
        guard store.settings.autoPictureInPicture, let rt = runtimes[tabID], !rt.browser.isInPictureInPicture else { return }
        rt.pendingAutoPictureInPicture = true
        rt.browser.requestPictureInPicture(automatic: true)
    }

    func browser(_ browser: CraBrowser, didChangePictureInPicturePlayback playing: Bool) {
        PictureInPictureChrome.shared.isPlaying = playing
    }

    /// Picture in Picture's "back to tab": select the tab, bring its window up
    /// and put the video back in the page (also when the tab was already selected).
    private func bringToFront(_ tabID: UUID) {
        store.selectTab(tabID)
        container.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runtimes[tabID]?.browser.exitPictureInPicture()
    }

    /// Back on the tab: the video comes home. Arc closes its Picture in Picture
    /// window whenever the tab it came from is in front again, however it was
    /// opened (observed on 1.168: the window went away the moment its source
    /// window became key).
    private func returnToTab(_ rt: TabRuntime) {
        rt.pendingAutoPictureInPicture = false
        if rt.browser.isInPictureInPicture { rt.browser.exitPictureInPicture() }
    }

    func browser(_ browser: CraBrowser, didChangePictureInPicture active: Bool) {
        guard let id = tabID(of: browser), let rt = runtimes[id] else { return }
        if active {
            // The floating window's hover controls act on this tab.
            PictureInPictureChrome.shared.actions = PictureInPictureActions(
                backToTab: { [weak self] in self?.bringToFront(id) },
                togglePlayback: { [weak browser] in browser?.togglePictureInPicturePlayback() },
                skip: { [weak browser] s in browser?.skipPictureInPicture(by: s) },
                close: { [weak browser] in browser?.exitPictureInPicture() })
            PictureInPictureChrome.shared.isPlaying = browser.isPictureInPicturePlaying
            PictureInPictureChrome.shared.videoEntered()
        } else {
            PictureInPictureChrome.shared.videoLeft()
        }
        if active {
            rt.autoPictureInPicture = rt.pendingAutoPictureInPicture
            rt.pendingAutoPictureInPicture = false
            // The request from leaving the tab landed after the user came back.
            if rt.autoPictureInPicture, id == visibleTabID { browser.exitPictureInPicture() }
        } else {
            rt.autoPictureInPicture = false
        }
        delegate?.browserManagerDidUpdate(id)
    }

    // MARK: CraBrowserDelegate

    func browser(_ browser: CraBrowser, didChangeTitle title: String) {
        guard let id = tabID(of: browser) else { return }
        store.updateTab(id, title: title)
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeURL url: String) {
        guard let id = tabID(of: browser) else { return }
        // Our own error page is a data: URL; keep the real address in the model.
        if url.hasPrefix("data:text/html;base64,") { return }
        store.updateTab(id, url: url)
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let id = tabID(of: browser) else { return }
        if !loading { runtimes[id]?.progress = 0 }
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeProgress progress: Double) {
        guard let id = tabID(of: browser) else { return }
        runtimes[id]?.progress = progress
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didFinishLoadingURL url: String, title: String, statusCode: Int) {
        guard let id = tabID(of: browser) else { return }
        store.recordVisit(url: url, title: title.isEmpty ? (store.item(id)?.tab?.savedTitle ?? "") : title)
    }

    func browser(_ browser: CraBrowser, didLoadFavicon image: NSImage, forURL iconURL: String) {
        guard let id = tabID(of: browser), let tab = store.item(id)?.tab else { return }
        let key = FaviconCache.key(for: tab.url) ?? tab.faviconKey
        guard let key else { return }
        favicons.store(image, forKey: key)
        if tab.faviconKey != key { store.updateTab(id, url: tab.url) }
    }

    func browser(_ browser: CraBrowser, didReportThemeColor hex: String) {
        guard let id = tabID(of: browser) else { return }
        runtimes[id]?.themeColor = hex
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didReportBackgroundColor hex: String) {
        guard let id = tabID(of: browser), let rt = runtimes[id], rt.backgroundColor != hex else { return }
        rt.backgroundColor = hex
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeStatusMessage message: String) {
        delegate?.browserManager(statusMessage: message)
    }

    func browser(_ browser: CraBrowser, didChangeFullscreen fullscreen: Bool) {
        guard let id = tabID(of: browser) else { return }
        delegate?.browserManager(fullscreen: fullscreen, tabID: id)
    }

    func browser(_ browser: CraBrowser, requestsNewTabWithURL url: String, inBackground background: Bool) {
        if url.hasPrefix("cra://") { return }  // pages never drive the app
        let sourceSpace = tabID(of: browser).flatMap { store.spaceID(ofItem: $0) }
        let parentIndex = tabID(of: browser).flatMap { id -> Int? in
            guard let it = store.item(id), let p = it.parentID, store.rootContainer(of: id) != nil,
                  case .today = store.rootContainer(of: id)! else { return nil }
            return (store.item(p)?.children.firstIndex(of: id) ?? -1) + 1
        }
        // Links from a today tab open right below it (Arc); otherwise at the top.
        let tab = store.createTab(url: url, in: sourceSpace, select: !background,
                                  parent: parentIndex != nil ? store.item(tabID(of: browser)!)?.parentID : nil,
                                  index: parentIndex)
        if background {
            store.markUnread(tab.id, true)
            ensureRuntime(for: tab.id)  // load it so the title and favicon fill in
        }
    }

    func browser(_ browser: CraBrowser, popupHostForURL url: String, inBackground background: Bool) -> CraBrowser? {
        if url.hasPrefix("cra://") { return nil }  // pages never drive the app
        let sourceSpace = tabID(of: browser).flatMap { store.spaceID(ofItem: $0) }
        let tab = store.createTab(url: url, in: sourceSpace, select: !background)
        if background { store.markUnread(tab.id, true) }
        let host = makePopupHost(for: tab.id)
        if !background { show(tab.id, focus: true) }
        return host
    }

    func devToolsHostView(for browser: CraBrowser) -> NSView? {
        guard let id = tabID(of: browser) else { return nil }
        return delegate?.browserManagerDevToolsHost(for: id)
    }

    private(set) var devToolsViews: [UUID: NSView] = [:]
    var visibleTabHasDevTools: Bool { visibleTabID.flatMap { devToolsViews[$0] } != nil }

    func browser(_ browser: CraBrowser, didCreateDevToolsView view: NSView) {
        guard let id = tabID(of: browser) else { return }
        devToolsViews[id] = view
        delegate?.browserManagerDevToolsChanged()
    }

    func browserDidCloseDevTools(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        devToolsViews[id] = nil
        devToolsPlaceholders[id] = nil
        devToolsDockedState[id] = nil
        delegate?.browserManagerDevToolsChanged()
    }

    /// Chrome's docked frontend reported where the page goes: `bounds` are points with a
    /// top-left origin inside a DevTools window whose content measured `frontendSize`.
    struct DevToolsPlaceholder: Equatable {
        var bounds: NSRect
        var frontendSize: NSSize
    }
    private(set) var devToolsPlaceholders: [UUID: DevToolsPlaceholder] = [:]
    /// False once the user undocked Chrome's frontend into its own window.
    private(set) var devToolsDockedState: [UUID: Bool] = [:]

    func browser(_ browser: CraBrowser, devToolsPageBounds bounds: NSRect) {
        guard let id = tabID(of: browser) else { return }
        // Undocked frontends still report bounds (device mode); only setIsDocked changes the dock state.
        guard devToolsDockedState[id] != false else { return }
        let size = devToolsViews[id]?.window?.contentView?.bounds.size ?? NSSize(width: bounds.maxX, height: bounds.maxY)
        devToolsPlaceholders[id] = DevToolsPlaceholder(bounds: bounds, frontendSize: size)
        delegate?.browserManagerDevToolsPageBoundsChanged()
    }

    func browser(_ browser: CraBrowser, devToolsDocked docked: Bool) {
        guard let id = tabID(of: browser) else { return }
        if !docked { devToolsPlaceholders[id] = nil }
        guard devToolsDockedState[id] != docked else { return }
        devToolsDockedState[id] = docked
        delegate?.browserManagerDevToolsChanged()
    }

    /// CEF's window for the visible tab's DevTools, if any.
    var visibleDevToolsWindow: NSWindow? { visibleTabID.flatMap { devToolsViews[$0]?.window } }

    private func syncDevToolsVisibility() {
        delegate?.browserManagerDevToolsChanged()
    }

    func browser(_ browser: CraBrowser, handleKeyEvent event: NSEvent) -> Bool {
        delegate?.browserManagerHandleKey(event) ?? false
    }

    func browser(_ browser: CraBrowser, handleUnhandledKeyEvent event: NSEvent) -> Bool {
        delegate?.browserManagerHandleUnhandledKey(event) ?? false
    }

    func browser(_ browser: CraBrowser, didUpdateDownload download: CraDownloadInfo) {
        delegate?.browserManager(download: download)
    }

    func browser(_ browser: CraBrowser, requestsPermissionForOrigin origin: String, kinds: UInt, completion: @escaping (Bool) -> Void) {
        // Notification prompts are denied quietly (no modal), like Arc's default.
        if kinds == 8 { completion(false); return }
        var what: [String] = []
        if kinds & 1 != 0 { what.append("camera") }
        if kinds & 2 != 0 { what.append("microphone") }
        if kinds & 4 != 0 { what.append("location") }
        if kinds & 8 != 0 { what.append("notifications") }
        if what.isEmpty { what.append("a browser permission") }
        let alert = NSAlert()
        alert.messageText = "\(origin) wants to use your \(what.joined(separator: " and "))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        guard let window = container.window else { completion(false); return }
        alert.beginSheetModal(for: window) { resp in completion(resp == .alertFirstButtonReturn) }
    }

    func browserDidReceiveFocus(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        delegate?.browserManagerFocusedBrowser(id)
    }

    func browserDidClose(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        browser.containerView.removeFromSuperview()
        byBrowser[ObjectIdentifier(browser)] = nil
        if runtimes[id]?.browser === browser { runtimes[id] = nil }
        if visibleTabID == id { visibleTabID = nil }
        visibleTabIDs.removeAll { $0 == id }
        delegate?.browserManagerDidUpdate(id)
    }
}

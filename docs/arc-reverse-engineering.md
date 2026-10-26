# Arc reverse-engineering findings (for Cra)

Target: /Applications/Arc.app, version 1.168.0 (build 88413), bundle id company.thebrowser.Browser, min macOS 13.
Method: REA CLI (rea-agents 6.4.0) `decode-interface-builder`, `inspect-asset-catalog`; `strings` on the arm64 slice;
Arc's own JSON stores in ~/Library/Application Support/Arc; `defaults read company.thebrowser.Browser`.
No Ghidra/IDA/Hopper on this Mac, so no decompiled logic. Nothing below was observed at runtime.

Legend: [O] observed in shipped artifact or data file, [I] inference, [U] unknown.

## Architecture
- [O] Native Swift app. Framework "ARC" with feature modules (CommandBar, SidebarDataStore, StorableSidebar, Archive,
  SpaceStyleEditor, TypeTravel, LittleBrowser, HoverCards...). UI is AppKit: SidebarViewController, SidebarDockViewController,
  NSCollectionView layouts, CommandBarTextField, SuggestionsView.
- [O] Web content is embedded Chromium ("User Data/Default" is a Chrome profile: History, Cookies, Extensions, Preferences).
- [I] So Arc = native chrome + Chromium engine. Cra uses WKWebView instead (design choice, not a copy).

## Sidebar data model (StorableSidebar.json)
- [O] `sidebar.containers` = [ {global}, {spaces, topAppsContainerIDs, items} ]. Lists are flat [id, object, id, object...].
- [O] SpaceModel: id, title, profile, containerIDs = ["pinned", <id>, "unpinned", <id>], customInfo.iconType {emoji_v2, emoji},
  customInfo.windowTheme = blendedGradient { baseColors[2], overlayColors, modifiers{noiseFactor,intensityFactor,overlay:"grain"},
  wheel: analogous|complimentary, translucencyStyle light|dark } with appearanceBased light/dark variants, plus a
  semanticColorPalette (foregroundPrimary/Secondary/Tertiary, backgroundExtra, maxContrastColor...).
- [O] SidebarItem: id, parentID, title (null unless user renamed; custom title overrides page title), childrenIds[], isUnread,
  createdAt, originatingDevice, data = one of
  - tab { savedURL, savedTitle, savedMuteStatus, timeLastActiveAt, activeTabBeforeCreationID, referrerID?, liveItemID? }
  - list {} = folder (optional customInfo.iconType; optional automaticLiveFolderData for GitHub live folders)
  - itemContainer { containerType: topApps{profile} | spaceItems{spaceID} }
  - [O strings only] easel, splitView, arcDocument, tabGroup also exist.
- [O] Favorites = the "topApps" container, one per profile, shared by all spaces (StorableSidebar.topAppsContainerIDs).
- [O] Every space owns one pinned container and one unpinned ("Today") container; ordering = childrenIds; folders nest via parentID.
- [O] A pinned tab keeps savedURL/savedTitle as its home; strings: resetTab, resetCurrentTab, replacePinnedTab,
  PinnedTabNavigationProfile, renamePinnedTabsEnabled=1.
- [O] Section chrome: UnpinnedSectionDivider/Header (the line between pinned and Today), SidebarClearButton,
  SidebarTidyButton, SidebarPlusButton (new tab button with menu: newTab/newFolder/newEasel/newNote/newSpace),
  PinnedSectionExpansionState, spacesWithCollapsedPinnedSections.

## Window state (StorableWindows.json)
- [O] sidebarWidth 328, sidebarMode "anchored" (binary also has floating, hidden, collapsed), focusedSpaceID, lastFocusedSpaceID,
  expandedItems (folder expansion, per window), itemLastActiveDates, itemCreatedDates, splitViewState, windowContents.

## Spaces
- [O] SidebarDock = space switcher at the bottom (icons/emoji, tooltip), SidebarPagingContainer = horizontal paging between spaces,
  SpaceCreation view, SpaceStyleEditor (color pad, dial, color picker), SpaceIconPicker (emoji), SpaceManagement (reorder),
  focusNextSpace/previous, LinkRouting rules (URL match -> space or Little Arc), per-space profile.

## Archive (StorableArchiveItems.json)
- [O] { archivedAt, reason: manual|auto, source: space{id}|littleArc|standaloneSidebar|unknown, sidebarItem: <copy> }.
- [O] Auto-archive thresholds enum: twelveHours, twentyFourHours, sevenDays, thirtyDays (this Mac: sevenDays, per profile).
- [O] Actions: viewArchive, clearArchive, reopenClosedTab, resetSpace, archiveTab.

## Command bar (ARC_CommandBar.bundle + strings + StorableCommandBarAdditionalRanking.json)
- [O] Entry points: keyboardShortcutT, keyboardShortcutL, keyboardShortcutFocusSidebar, keyboardShortcutCommandOptionG,
  sidebarDoubleClick, sidebarNewTabButton, placeholderClick, littleArcPlaceholderClick, topbar, appMenu*,
  toggleBetweenTypeTravelAndCommandBar.
- [O] Result archetypes: tab (switch to open tab; carries customTitle), chromiumHistory, chromiumSearchWhatYouTyped,
  chromiumSearchSuggestion, chromiumNavigateWhatYouTyped, chromiumSearchHistory, chromiumNavigateSuggestion, chromiumBookmark,
  chromiumSearchOtherEngine, chromiumSearchCalculatorAnswer, topDomain (bundled popularDomains.json), typeTravel
  (menuItem:<id>, focusSpace:<id>, moveToFolder:<id>, openFolder<id>, webContentExtension:<name>), askGPTWhatYouTyped,
  siteSearch (scoped pill), staticQuerySuggestions.
- [O] Ranking signals: recentlySwitchedToTabs (last 10 switch times per tab), queriesToSelectedArchetype (typed prefix ->
  what the user picked, i.e. it learns), typeTravelUsage (frequency + last 15 executions), siteEngagementScore,
  fuzzySearchConfidence, hotWords match %, title/url match % and position, recency, importance, customTitlePrefix boost,
  veryRecentTabOrDocumentBoost, derankCurrentItemURL, dedupByTitleAndHostList (figma, notion, github, zoom...).
- [O] Type-travel triggers e.g. "Go to Sidebar Item 3" / "3. tab" / "3. item".
- [U] Weights of the ranking model (a CoreML tensor, CommandBarRankingTensor) are not recoverable statically.

## Key bindings (StorableKeyBindings.json + strings)
- [O] Action = {identifier, name}; binding = {keyEquivalent, deviceIndependentModifierFlags}, priority, typeTravelTriggers;
  user overrides persisted. item1..item9 = "Go to Sidebar Item N" with flags 1048576 (= Command).
- [O] Action identifiers: newTab, newWindow, newBlankWindow, newSpace, newFolder, newEasel, newNote, closeWindow, archiveTab,
  reopenClosedTab, pinTab, rename, duplicate, resetTab, addressBar, typeTravel, toggleSidebar, showSidebar, focusSidebar,
  toggleToolbar, focusNextSpace, nextTab, previousTab, selectNextTab, cycleNextTab, cycleTabForward, goBack, goForward,
  reloadPage, forceReloadPage, stopLoading, findNext, findPrevious, findAndReplace, zoomIn, zoomOut, resetZoom, fullscreen,
  readerMode, copyCurrentURL, viewArchive, clearArchive, viewHistory, viewDownloads, viewLibrary, viewPreferences,
  developerTools, inspectElements, viewSource, printPage, savePageAs, capturePage, captureFullPage, showLittleArc, peekEmail,
  addSplitView, removeSplitView, muteAllTabs, resetSpace, clearCookies, openTabIn, gptMessage, hideArc, hideOthers, minimize,
  quitArc, moveToSpace, moveToTopApps, removeFromTopApps, replacePinnedTab, renameCurrentTab, duplicateCurrentTab.
- [O] Default key equivalents read from the running Arc's menu bar through Accessibility (AXMenuItemCmdChar/
  AXMenuItemCmdModifiers, 24 Oct 2026). File: New Tab ⌘T, New Window ⌘N, Blank Window ⌃⌘N, New Incognito Window ⇧⌘N,
  New Little Arc Window ⌥⌘N, Restore Last Closed Tab ⇧⌘T, Open Command Bar ⌘L, New Easel ⌃⇧E, Close Window ⇧⌘W,
  Close Tab ⌘W, Capture ⇧⌘2, Save Page As ⇧⌘S, Print ⌘P. Edit: Copy URL ⇧⌘C, Copy URL as Markdown ⇧⌥⌘C,
  Copy URL as Quote ⌃⇧⌘C, Paste and Match Style ⇧⌘V, Find ⌘F, Find and Replace ⌥⌘F, Find Next ⌘G, Find Previous ⇧⌘G,
  Jump to Selection ⌘J. View: Hide Sidebar ⌘S, Hide Toolbar ⇧⌘D, Stop Loading ⌘., Refresh ⌘R, Force Refresh ⇧⌘R,
  Add Split View ⌃⇧=, Close Split Pane ⌃⇧-, Zoom Actual ⌘0, Zoom In ⌘+, Zoom Out ⌘-, View Source ⌥⌘U,
  Developer Tools ⌥⌘I, Inspect Elements ⌥⌘C, JavaScript Console ⌥⌘J, Enter Full Screen ⌃⌘F. Spaces: Next ⌥⌘→,
  Previous ⌥⌘←, space N ⌃N. Tabs: Pin/Unpin ⌘D, Next Tab ⌥⌘↓, Previous Tab ⌥⌘↑, Clear Today ⇧⌘K, Go to Tab N ⌘N,
  Toggle recent tabs ⌃Tab. Archive: Go Back ⌘[ (shown as ⌘Æ on a Danish layout) / ⌘←, Go Forward ⌘] / ⌘→,
  View History ⌘Y. Window: Minimize ⌘M, Open Library ⇧⌘L, View Downloads ⇧⌘J.

## Visual reference (Arc 1.168, measured at 2x from window captures)
- [O] Sidebar 328pt wide. Row 1: traffic lights, sidebar toggle right after them (~93pt), nav ← → ↻ right-aligned when a
  tab is selected and the toolbar shows the URL; with no tab the nav moves into the toolbar and the toolbar shows a
  centered "Search or Enter URL…". Favorites: 4 tiles, ~44pt tall, active tile gets a dashed outline. Space header: emoji +
  name, 13pt medium, secondary color. Rows 40pt pitch, 14pt titles, 16pt favicons, custom-titled/navigated pinned tabs show
  the host as an 11pt second line, folders use a blue folder glyph, nested rows indent ~18pt. Bottom row: library icon
  left, tiny space emoji centered (inactive dimmed), + right.
- [O] Content: rounded card inset ~8-10pt with the toolbar strip (42pt: lock + monospaced URL, copy link, extensions,
  capture, DevTools, sidebar toggle) on top; no card at all when no tab is selected.
- [O] Command bar: ~766pt wide, vertically centered, dark translucent in dark mode. Input row 60pt with the top match's
  favicon; rows 50pt single-line "Title — url"; the completion row comes first, then the typed query, then matches; open
  tabs show "Switch to Tab" + arrow box (other-space tabs show the space name); the selected row is tinted with the
  space color. ⌘L with the toolbar visible edits inline: dropdown hangs under the toolbar across the content width.

## Dia 1.54 (company.thebrowser.dia)
- [O] ~/Library/Application Support/Dia/StorableProfileContainers.json: containers per profile with `window` or
  `favorites` kinds; tabs[].contents[].variant = webContent{_0:{title,url}} | newTabPage. StorableAutoArchive.json:
  containers[].archivedTabs (empty here). Chromium profile at User Data/Profile 7 with Bookmarks whose bookmark-bar
  folders mirror Arc spaces ("Favorites", "Victor", "JYSK").

## Other observed features (not in Cra's first scope)
- Little Arc (LittleBrowser), Peek, Easels, Boosts, split view, hover cards, site control center, sidebar banners,
  sync via CloudKit + Firebase, Chromium extensions, "Tidy", Ask Arc.

## Rendering recipe fitted to Victor's Arc captures (24 Oct 2026)
- [O] Light "Victor" theme (isVibrant, intensity 0.25) renders as #93926A–#AA9470 on this desktop: gradient at 25% over the
  blurred desktop. Cra reproduces it with a behind-window NSVisualEffectView, a 22% white lift and gradient alpha = intensity.
- [O] Dark "JYSK" theme renders #292538 from base #01021F/#1A001F: about 27% of the colour over #2B2632.
- [O] Toolbar strip = first theme colour at 46% (#72601D), URL #E4E0D4 12pt monospaced starting 40pt from the card edge.
- [O] Title row centre 24pt (traffic lights at x 19/43/67, sidebar toggle at 93, nav ← → ↻⌄ at 236/270/299/314).
  Favorites tiles 70×47 with 8pt gaps, first row at y≈45. Space header centre y≈118, rows 41pt pitch, favicon centre x=26,
  text x=45. With no tab selected the content area is a faintly lighter card with a 40pt toolbar strip and a hairline.

## Calibration update, 24 Oct 2026 (afternoon)

Method that finally worked: put a full-screen solid window (white, then black) directly
behind each browser, capture the same screen region, and fit per channel
`out = c + k · backdrop`. `screencapture` output samples as sRGB (a solid #72601D window
reads back as #72601D), so no P3 conversion is needed. Window-id captures (`-l`) show
Arc's sidebar without its backdrop (equal to its inactive look) and include the window
shadow unless `-o` is passed.

Measured on the "Victor" theme (Arc base #F8D558 / #A4F454, overlay → #FF7567, intensity 0.25):

| | over white | over black |
|---|---|---|
| Arc sidebar, top | 206 200 160 | 124 118 77 |
| Arc sidebar, bottom | 212 181 141 | 154 124 82 |
| Cra (final) top | 199 192 152 | 124 117 76 |
| Cra (final) bottom | 213 184 142 | 154 125 82 |

Cra's recipe for light vibrant themes: `NSVisualEffectView` `.hudWindow`, dark appearance,
`state` driven explicitly from app activation (`.active` / `.inactive`; the key-window
heuristic left the blur half flat), no white lift while active, 0.75 lift while inactive.
Gradient top → bottom, stop opacity `intensity·1.8 → intensity·2.33`; stops from the Arc
theme: top = mix(mix(base0, base1, 0.15), white, 0.30), bottom =
mix(mix(base0, overlayEnd ?? base1, 0.30), white, 0.20). Over a dark backdrop Cra is within
2/255 of Arc at every height; over pure white the top is 7–8 darker (the HUD material
passes ~55 % of the backdrop, Arc's blur a little more). Dark vibrant themes keep the
earlier `.underWindowBackground` + 15 % lift calibration.

Toolbar band is opaque and theme-derived (same colour over any backdrop):
light = HSB(h, s + 0.10, v · 0.46) of the raw base colour (#F8D558 → #725F1D; Arc #72601D),
dark = HSB(h, s · 0.6, v · 0.8) (#010220 → #0A0B19; Arc #0E0B16). Pages with a
`theme-color` meta use that colour instead (Kildash #1A1917, Messenger white).

Other measured details: window buttons are muted grey discs (bg −10 %) until the pointer
reaches the sidebar's title row; favicons 16 pt centred 25.75 pt from the window edge; space
header 14 pt medium with no top padding above it; favorites tiles 72 × 47 with 8 pt margins
and gaps; the yellow/black dashed ring (2 pt, systemYellow, 6/6 black dashes) is Arc's
keyboard-focus indicator, shown on a tab chosen without the mouse (it appeared on every
tab selected through AppleScript, never on clicked ones). Host subtitles under pinned
tabs appear only when the tab left the pinned host (Phantom at /signin shows none); the
"Ahrefs / ahrefs.com" row in Arc stays unexplained (same host, same URL, loaded).

### DevTools docking (CEF 154 note)

`ShowDevTools` with a `SetAsChild` window info (which forces Alloy style on macOS) hits a
CHECK inside CEF 154 regardless of the parent view (tested with the real host and with a
hidden temp window). An Alloy-style top-level DevTools window works, so Cra creates that
hidden (`windowInfo.hidden`), then attaches CEF's window as a borderless child window over
the dock area and keeps its frame in sync from `ShellView.layoutContentChildren`. Moving the
DevTools NSView into Cra's window would be unsafe: CEF closes `view.window` when DevTools
closes.

### Measuring while the Mac is in use (lessons)

A TCC prompt left behind by a Cra instance launched from the agent's shell blocked every
GUI helper spawned from that shell (they never reached `applicationDidFinishLaunching`),
which silently invalidated three colour runs; `killall UserNotificationCenter` cleared it.
Run the app from ~/Applications (scripts/build.sh installs there) so no prompt appears.
Animations were verified with `screencapture -V` recordings and a per-frame difference
tool: space switch 11 consecutive 60 Hz frames, sidebar hide 10 frames with a fast start
and soft landing, command bar fade-in 7 frames; the 80 ms fade-out still lands in one frame.

### DevTools dock, final shape (24 Oct, evening)

Arc shows Chrome's docked DevTools (close button, device toggle, rounded card corner).
In CEF 154 the docked frontend (`can_dock=true`) reserves a 150 px "inspected page"
placeholder inside its own window and, after a second navigation, loses its target
connection (empty Elements panel, blue toolbar). Cra therefore keeps the undocked frontend
(fills the pane, stays connected) and injects a plain HTML close button after the ⋮ menu in
the main toolbar; that button and `InspectorFrontendHost.closeWindow()` reach the shell as a
console message, which calls `CloseDevTools()`. The CEF window is non-opaque with its right
corners masked to the card radius. Still missing versus Arc: the device-mode toggle, which
the frontend only offers when it can dock.

### Developer Mode, shortcuts, extensions (24 Oct, evening)

Arc's View ▸ Developer submenu (read via Accessibility): View Source ⌥⌘U, Developer Tools
⌥⌘I, Inspect Elements ⌥⌘C, JavaScript Console ⌥⌘J, "Turn off Developer Mode for this
site" ⌃D. ⇧⌘D is Hide Toolbar and ⌘D is Pin/Unpin Tab. Developer Mode is per site and
swaps the toolbar: default = nav buttons left, centred friendly URL (host bright, path dim)
behind a link glyph, sidebar toggle right; developer = lock + full monospace URL left,
copy/capture/DevTools/source icons right, nav buttons in the sidebar's title row. Cra
stores the hosts in `AppSettings.developerHosts`.

Extensions: CEF 154 has no extension API for Alloy-style browsers. A spike
(`cra://debug?chromeSpike=<url>`) proved the alternative: a Chrome-style Views window
(`CefWindow` + `CefBrowserView`, `GetChromeToolbarType = CEF_CTT_NONE`, frameless, runtime
style CHROME) attached as a child window over the content area loads unpacked extensions
from `~/Library/Application Support/io.github.rainmiku.cra/Extensions/*` via `--load-extension` (an MV3
content script rendered its banner). Chrome style also docks DevTools natively. Moving the
page browsers to that hosting is the route to extensions; one Chrome-style window per tab.

## Split View (Arc 1.170.0, 24 Oct 2026, evening)

Method: REA CLI 6.4.0 `inspect-macho` (Evidence ev_84b238…, arm64 SHA-256 25af5f4e…) and `demangle-swift`
(ev_026c6350…); REA's `inspect-native-dispatch-metadata` refuses the 80 MB executable (64 MiB budget). The
model below comes from parsing the arm64 slice's Swift reflection metadata (`__swift5_types` /
`__swift5_fieldmd` / `__swift5_proto`, nominal types with their stored properties and enum cases) and
`otool -oV` Objective-C class data (selectors, ivars), plus the user's own
~/Library/Application Support/Arc/StorableSidebar.json (21 split items) and StorableWindows.json.
No decompiler, so property names and types are observed; the algorithms are inferred from them.

### Where it lives
- [O] Everything is in Arc's native Swift shell, not in Chromium. ArcCore (Chromium) only carries upstream
  Chrome's own `tabs.createSplit` / `splitViewId` extension API and "Cannot create split view with
  non-adjacent tabs" strings; the Arc UI never references them.
- [O] Generic engine: `ARCUI.SplitViewController: NSViewController` (module ARCUI, file
  ARCUI/SplitViewController.swift) with `SplitViewControllerLayout` (pure layout types) and
  `SplitViewContentPaneView`. It is NOT built on NSSplitView: no Arc class implements any
  `splitView:…` delegate selector (the NSSplitViewDelegate selectors in the binary are protocol metadata
  only). The one NSSplitView subclass, `WebContentViewControllerSplitView` (private to
  WindowContentViewController, overrides mouseDown/mouseUp/viewDidEndLiveResize, `onDidEndLiveResize`),
  is a per-pane inner split, not the pane layout. [I]
- [O] Arc-specific glue: `Arc.WindowContentsContainerViewController: XiblessViewController<NSView>`
  conforms to `SplitViewControllerDelegate`, owns one lazy `splitViewController`, a
  `LayoutConstraintsMap<SplitViewConstraintType>` (leading, trailing, top, bottom, minHeight) and a lazy
  `splitViewTopConstraint`. Each pane is an `Arc.WindowContentViewController` (conforms to
  `SplitViewContentPaneWithInsets`); an empty/drop pane is `SplitViewContentPlaceholderView` (NSView with
  `contentInsets`, a `BorderView` with `borderColor`, also `SplitViewContentPaneWithInsets`).
- [O] State is TCA (ComposableArchitecture): `Store<WindowState, WindowAction>` with view stores; feature
  modules WindowContents (`SplitViewState`, `SplitViewLayoutCache`, `WindowSplitViewLayout`,
  `WindowContentPresentationDisposition`), SharedWindowFeature (`WindowAction.SplitViewAction`),
  BaseModels (`SidebarSplitViewData`, `SplitViewPaneMenuOperation`), SidebarUI (`SplitViewCellState`).

### Data model
- [O] Sidebar: a split is a sidebar item like a folder. `SidebarItemData.splitView(SidebarSplitViewData)`
  with `itemWidthFactors: [Identifier<SidebarItem>: CGFloat]`, `layoutOrientation: horizontal|vertical`,
  `timeLastActiveAt: Date?`, `customInfo: { iconType: SidebarCustomIcon }?` (user icon, used together with
  the item `title` when renamed), `focusItemID: Identifier<SidebarItem>?`. The tabs are the item's
  `childrenIds` (order = pane order, left→right / top→bottom). JSON on this Mac:
  `{"data":{"splitView":{"itemWidthFactors":[<id>,0.3835,<id>,0.6165],"layoutOrientation":"horizontal",
  "focusItemID":<id>,"timeLastActiveAt":…,"customInfo":null}},"childrenIds":[…],"parentID":<container>,…}`.
  All 21 local splits: 2 children, horizontal, parent = a space's pinned/unpinned container (not inside
  folders here), title/customInfo never set. Untouched splits store a single factor `[firstChild, 0.5]`;
  after a drag both factors are stored and sum to 1.0. One zombie split with 0 children exists; the
  binary logs "Noticed zombie split view (without any children)" (`ZombieSplitSeenLocation`:
  rawUpdate/appliedChange/publishedValue) and repairs it on sync. [I] Missing factors = equal share of
  the remainder.
- [O] Window: `WindowContents.State { windowContents: [WindowContentID: WindowContent], splitViewState,
  modalWindowContentV2State, windowContentSidebarItemMap: BidirectionalMap<WindowContentID,
  Identifier<SidebarItem>> }`. `SplitViewState { windowContentIDs: OrderedSet<WindowContentID>,
  layoutOrientation, interactionState, focusedContentID }`; only `windowContentIDs` + `focusedContentID`
  are Codable (StorableWindows.json `splitViewState`), orientation and widths are rebuilt from the
  sidebar item. `InteractionState { activePaneEditStyles: Set<.dragAndDrop>, proposedWindowContentDropTarget:
  WindowContentID?, isResizingPanes }`. Legacy `SplitViewState_Legacy { windowContentIDs }`.
- [O] Per-window width cache: `WindowSplitViewLayout { paneWidths: [CGFloat] }` kept by
  `SplitViewLayoutCache { storeLayoutForWindowID, layoutForWindowID }` (a TCA DependencyKey) and
  handed to the view as `restorableSplitViewLayout`; `SplitViewWindowContentContext { numPanes,
  restorablePaneWidths: [CGFloat]?, splitViewLayoutOrientation }` is what the container passes to
  `SplitViewController`.
- [O] Container view state (`WindowContentsContainerViewController.ViewState`): `splitViewWindowContentIDs:
  OrderedSet<WindowContentID>`, `focusedContentID`, `splitViewLayoutOrientation`, `restorableSplitViewLayout`,
  `canDragOntoSplit`, `isDraggingToCreateSplitView`, `shouldShowInteractivePaneInsertionHandle`,
  `contentInsets`, `contentCornerRadius`, `hiddenScrimEdges`, `sidebarPresentation`.

### The layout engine (ARCUI.SplitViewController)
- [O] Properties: `draggerHandleWidth`, `draggerHandleHitTargetOutset`, `minimumPaneWidth`,
  `layoutOrientation`, `displayInteractivePaneInsertionDraggerHandle`, `allowInteractivePaneInsertion`,
  `verticalLayoutOrientationFromDragAllowed`, `shouldDisplayDraggerPaneForSecondaryAxis`,
  `isDragDropHapticFeedbackEnabled`, weak `delegate`, `contentPanes: OrderedDictionary<Identifier<ContentPane>,
  ContentPane>`, `paneResizeState?`, `dragDestinationState?`, `dragSourceState?`,
  `dragInfoSubject: PassthroughSubject<NSDraggingInfo, Never>`, lazy `minimumWidthConstraint`.
- [O] `SplitViewControllerLayout.ContentPane { id, view: NSView & SplitViewContentPane, trailingDraggerHandle,
  bottomDraggerHandle: DraggerHandle { view: NSView & SplitViewControllerDraggerHandleType }, widthFactor: CGFloat,
  resizeStyle: flexible|fixed, displayState: collapsed|expanded, inFlightTransition: StateTransition?,
  content: .dropRegion(NSView) | .viewController(SplitViewContentPaneContentViewController) }`.
  `StateTransition { identifier: UUID, targetState, style: .animated(removePaneOnCompletion: Bool) | .immediate,
  draggerHandleWidth: CGFloat? }`. `ContentPanePair { leading, trailing? }`.
- [O] `SplitViewControllerLayout.Context { contentPanes, containerSize, backingScaleFactor, minimumPaneWidth,
  draggerHandleWidth, displayInteractivePaneInsertionDraggerHandle, shouldDisplayDraggerPaneForSecondaryAxis,
  layoutOrientation, yAxisOriginAtTop }` → frames are a pure function of the context (pixel-snapped via
  backingScaleFactor). [I] Each pane gets `widthFactor × (container − handles)` along the main axis, clamped to
  `minimumPaneWidth`; every pane carries its own trailing (horizontal) and bottom (vertical) handle view, the
  last one hidden or used as the "insert a pane here" handle when `displayInteractivePaneInsertionDraggerHandle`.
- [O] Resize: `PaneResizeState { initialClickLocationInDragHandle: CGPoint, canSnapToCenter, isCenterSnapped }`
  driven by `handleDraggerPanGesture:` (NSPanGestureRecognizer) and `handleDraggerDoubleClickGesture:`
  (double-click a handle = reset to equal widths, [I]). Dragging snaps to the 50/50 centre when allowed.
  Pane add/remove animates via `StateTransition` (collapsed ↔ expanded, remove on completion).
- [O] Panes are hosted in `SplitViewContentPaneView: NSView { contentView, contentConstraints:
  LayoutConstraintsMap<NSLayoutConstraint.Attribute>, lockContentWidth: Bool, lockedContentAlignment:
  leading|center|trailing, userInteractionEnabled }` (overrides hitTest). [I] While a handle is being
  dragged the web content keeps its old width and is pinned to one edge instead of relayouting Chromium on
  every mouse move; `userInteractionEnabled=false` blocks the page from eating the drag.
  `WindowContentViewController` adds `ContentResizeMode { intrinsic, throttle, locked }`,
  `pendingResizeFrames`, `resizeTimer`, `lockedContentSize`, `contentResizeThrottleSubscription`; the
  container has `isAnimatingResize` and `ContentSizeThrottleFlags` (OptionSet).
- [O] Handles: Arc's `SplitViewDraggerHandleView: FlippedView` (vertical divider: lazy `handle` NSView pill,
  `backgroundView: WindowBackgroundContainerView?` so the space theme shows through the gap, `isHighlighted`,
  `draggableArea: NSTrackingArea`, `draggableRegion: CGRect`, `resetCursorRects`, mouseEntered/Exited,
  `contentAppearance`) with `ViewState { displayBackgroundView, windowBackgroundConfiguration,
  contentOverBackgroundAppearance, isHandleVisible, metalWindowBackgroundRenderingEnabled }`;
  `SplitViewBottomDraggerHandleView` for vertical layouts adds `handle: .dragger | .scrimLoader` and
  `isContentBelowLoading` (the handle doubles as a loading scrim). ARCUI ships a plain
  `SplitViewControllerDefaultDraggerHandleView`.

### Drag and drop (how a split is created with the mouse)
- [O] `SplitViewController` is both `NSDraggingSource` and `NSDraggingDestination` (draggingEntered/Updated/
  Exited/Ended, prepareForDragOperation, performDragOperation, wantsPeriodicDraggingUpdates,
  updateDraggingItemsForDrag, draggingSession:…). `DragSourceState { contentPaneID, initialIndex,
  initialWidthFactor, contentPaneSnapshot: NSImage?, contentPaneSize }` = reordering a pane by dragging its
  toolbar (snapshot image as drag preview). `DragDestinationState { operation: NSDragOperation,
  isDraggingInView, proposedTarget: DropTarget?, isDraggingContentPane }`.
- [O] `DropTarget = .replaceContent(index) | .insertContent(index)`; `ProposedDropTargetInfo { target,
  dropRegionInsertionIndex: Int?, existingDropRegion: ContentPane?, layoutOrientation }`. [I] Hovering near an
  edge inserts a temporary `.dropRegion` pane (placeholder view, animated open) at that index; hovering over
  the middle of a pane proposes replacing it; `verticalLayoutOrientationFromDragAllowed` lets a drop on the
  top/bottom edge flip the layout to vertical.
- [O] What can be dropped (`WindowContentsContainerViewController.SplitViewDragItem`): `.sidebarItem(id)`
  or `.url(URL)`. Actions: `onDropSidebarItem(itemID, target, layoutOrientation, maybeMoveDecision)`,
  `onDropURL(url, target, layoutOrientation)`, `onDidUpdateSplitViewProposedDropTarget(WindowContentID?)`,
  `onDidBegin/EndSplitViewInteractivePaneEditingWith(.dragAndDrop)`.
- [O] Sidebar side: dragging a tab over another tab's left/right half (`SidebarDropTargetRegion = left|right`,
  `TabSplitViewPosition = left|right`) shows `SplitDragPreviewView` (title, favicon, "tab info" and "empty"
  background containers) after `splitDropTargetDelaySatisfied`; dropping makes a split item. Flags:
  `drag-to-combine-tabs-into-split-enabled`, `sidebar-drag-to-split-preview-ui-enabled`, `win-drag-to-split-enabled`.
  Onboarding copy: "Drag a tab from your sidebar into the middle of the screen to create a Split View."

### Commands, menus, entry points
- [O] `WindowAction.SplitViewAction`: `addPanel(index: InsertionLocation, showCommandBar: Bool)`,
  `movePanel(from:to:)`, `onDropSidebarItem`, `onDropURL`, `onDidBeginWindowContentsSplitViewPaneResize`,
  `onDidEndWindowContentsSplitViewPaneResize(WindowSplitViewLayout)`, `onDidUpdateSplitViewProposedDropTarget`,
  `onPaneCreated(source)`, `onPaneClosed`, `onDidRestoreSplitViewState`, `containerDelegate(…)`,
  `panelAction(ContentToolbarAction)`. Container delegate: `onDidAddItemsToContainer`,
  `onDidMoveItemsWithinContainer`, `onDidRemoveItemsFromContainers(itemIDs)`, `onDidAdjustLayoutOrientation`.
- [O] Where a new pane goes: `WindowContentPresentationDisposition.splitView(SplitViewTarget)` with
  `.paneAtIndex(Int) | .newPane(InsertionLocation) | .pane(WindowContentID) | .replaceAllPanes |
  .firstEmptyOrNewPane`; `InsertionLocation = .index(Int) | .after(id) | .before(id) | .last | .afterFocusedPane`.
- [O] Pane menu (`SplitViewPaneMenuOperation`, each `.enabled|.disabled`): moveLeft, moveRight, addPaneLeft,
  addPaneRight, addPaneTop, addPaneBottom, separate, copyLink, flipLayoutOrientation. Toolbar menu items
  (`ContentPanelSplitViewMenuItemType`): move/add/separate/copyLink × horizontal/vertical, flipToVertical,
  flipToHorizontal. Sidebar context menu on a split: `childItem(id, .separateFromSplitView)`, `separateAllItems`,
  `addPanel`, `flipLayoutOrientation`. Toolbar hover actions: separate, close, addHorizontal, addVertical,
  move, copyLink (`split-view-actions-hover-button-enabled`).
- [O] Menu strings: "Add Vertical Split View", "New Bottom Split", "Add Bottom Split", "Convert to
  Horizontal/Vertical Split View", "Flip to horizontal/vertical split view", "Close Split View Pane", "Separate Tab
  from Split", "Remove Tab from Split View", "Open in Split View", "Add to Split View", "Share Split View",
  "Multitask with Split View", "Switch to next/previous Split View", "Jumps to the first…fourth Split View page".
  Type-travel candidates: AddLeft/Right/Top/BottomSplit, ConvertToHorizontal/VerticalSplitView,
  NewVerticalSplitViewPane. Key bindings (see above): Add Split View ⌃⇧=, Close Split Pane ⌃⇧−.
- [O] Entry sources tracked (`SplitViewEnteredSource`): plusButton, windowContent, dragAndDrop, menu,
  contextMenu, alternateClick (option-click a tab), typeTravel, tabCreation, easel, navigationBar, tabHoverMenu.
  Option-click on a split child's close button un-splits (`option-click-split-tab-close-button-to-unsplit-enabled`).
- [O] Limits: errors `splitViewMaximumPanesExceeded`, `splitViewTargetOutOfRange`,
  `unableToInsertSplitViewContainer`, `missingSplitViewContainer`; `ModalParentSplitState { parentIsSplitCompatible,
  numberOfPanels, maximumNumberOfPanels, layoutOrientation }`. [I] Max is 4 panes (shortcuts stop at "fourth").
  Toolbar `shouldShowSplitViewClose` only in a split; `maximizeCurrentSplitViewPane:` exists (notification token).

### Sidebar cell
- [O] `SplitViewCellView: SelectableCellView<SplitViewCellState>` with `SplitViewCellState { sidebarItemID,
  isCurrentItem, isContentVisible, isKeyDraggedItem, isHighlighted, isMultiSelected, shouldDim, canResetTab,
  layoutStyle: .childItems(OrderedDictionary<id, ChildItemState>) | .customInfo(CustomInfo), colorPalette,
  closeItemShortcut, lastUpdatedLocally, hasLeadingRecordingIndicator, dropTargetRegion?, closeButtonConfiguration,
  closeButtonAction, shouldPerformUserAttentionAnimation }`. `ChildItemState { itemID, iconType: FaviconType?,
  title, isGroupSelected, isRecording, closeButtonConfiguration, optionClickSplitTabCloseButtonToUnsplitEnabled,
  newSplitSeparationMechanismsEnabled }`. `CustomInfo { title, isEditingTitle, icon: .childItemCount(Int) |
  .customIcon(SidebarCustomIcon) }`.
- [O] Views: `SplitViewCellChildrenContainerView` (one `SplitViewCellChildItemView` per tab, `separatorLayers:
  [CALayer]` between them, `isGroupHovered`, `InsetSpec { defaultInset, extendedInset }`), each child with
  favicon + title + its own close button and recording dot; renamed splits show `SplitViewCellCustomInfoView`
  (icon or item-count badge `SplitViewCellItemCountIconView`, editable title, hover subtitle). Icons:
  icon-split-add-left/right/top/bottom, icon-split-horizontal/vertical, icon-split-move-*, icon-separate-from-split,
  icon-split-share-*, icon-split-x; colour asset SplitViewLeftBackground.

### Plan for Cra (design, not observation)
1. Model: add `ItemData.split(SplitData)` to SidebarModel with `widthFactors: [UUID: Double]`,
   `orientation`, `focusTabID`; children = the pane tabs (reuse `childrenIds`/`parentID` like folders). Store
   per-window `splitState { paneTabIDs, focusedTabID }` in WindowPrefs; rebuild widths from the item.
2. Engine: a `SplitPaneLayout` value type (panes with widthFactor, min width, handle width, orientation,
   pixel snap) → frames; a `SplitContainerView` in ShellView's `webContainer` that owns one pane view and one
   handle view per visible tab. Cra's CEF browsers are child windows positioned by
   `MainWindowController.positionPageWindows`, so each pane needs its own screen rect: change
   `BrowserManager.show` to a set of visible tabs and `onWebFrame` to deliver per-tab rects.
3. Resize: pan on the handle updates factors; during the drag freeze each page window's size (Cra already
   has `frozenWebBounds`) and only move it, resize once on mouse-up (Arc's lockContentWidth/throttle);
   double-click = equal widths; snap at 50/50.
4. Creation: ⌃⇧= adds an empty pane (placeholder with dashed border + command bar); drag a sidebar tab onto
   the content card: edges insert, centre replaces; option-click a tab adds it as a pane; context menu
   "Open in Split View"; "Separate", "Flip orientation", "Close pane".
5. Sidebar: a grouped row showing each pane's favicon+title with hairline separators, group selection
   highlight, per-child close, rename → icon/count badge.

### Chrome-style page hosting (24 Oct, night)

Pages are now Chrome-style CEF browsers (`CefBrowserView` in a frameless `CefWindow`,
`GetChromeToolbarType = CEF_CTT_NONE`), one window per loaded tab, attached as child
windows over the content card and positioned from `ShellView.onWebFrame` (animated with the
sidebar through `onAnimateWebFrame`). The status bubble, toasts and find bar moved into a
transparent overlay panel above the page windows. This is what makes Chrome extensions work:
folders under `~/Library/Application Support/io.github.rainmiku.cra/Extensions` are passed with
`--load-extension` at start-up (verified with an MV3 content script on a real tab). Popups
come through `GetDelegateForPopupBrowserView`/`OnPopupBrowserViewCreated` and are hosted
the same way; Chrome's DevTools popup is caught with `OnBeforeDevToolsPopup` and docked by
the shell like before. Chrome's session restore had to be switched off
(`--no-startup-window`, crash-restore bubbles hidden) because it resurrected a killed
session's window as a framed Chrome window. The old embedded (Alloy) hosting stays behind
Settings → "Chrome engine for pages" for comparison; it has no extension support in CEF 154.

### Animation timing, Arc vs Cra (measured 24 Oct, VFR screen recordings)

Space switch: Arc ≈ 0.17 s of visible motion (4 distinct frames), Cra ≈ 0.18 s (11 frames
at 60 Hz, `.snappy(0.24)`). Sidebar hide: Arc changes the sidebar strip in 2 frames
(≈33 ms) and settles over ≈150 ms; Cra now runs a 0.14 s ease-out (≈4 frames of motion plus
a short settle), down from 0.22 s. Command bar: Cra fades in over 7 frames; Arc's bar also
appears in a single frame.

### Final state (24 Oct, late)

With a 3 % lift the sidebar sits within ±6/255 of Arc at every sampled height over both
white and black backdrops (top over white: Cra 201 194 154 vs Arc 206 200 160; top over
black: 128 121 80 vs 124 118 77). Sidebar hide now completes in 2–3 frames like Arc's
(0.08 s ease-out); the command bar appears and disappears in a single frame, like Arc's. What cannot be matched
from Cra's side: Arc's signed-in favorites and page state, its "Ahrefs / ahrefs.com"
subtitle (no visible rule), and the DevTools device-mode toggle (Chrome only offers it when
it docks the frontend itself, which CEF does not allow for these windows).

## Chrome metrics re-measured (Arc 1.170.0, 24 Oct 2026, evening, window-id captures)

Measured with `screencapture -l<id>` of Arc's main window against Cra's shell window at the
same 1728×1084 frame, probing pixel runs at 2x:
- Content card: 10 pt inset (card top at y=20 px), corner fits a circular 12 px radius
  → `contentCornerRadius` 6 pt (was 10). The card starts at the sidebar's right edge with
  no gap; Victor's Arc sidebar was 284 pt wide in this capture.
- Toolbar strip (default mode, Messenger, theme-color white): 32 pt tall (y 20–83 px),
  1 px hairline #F2F2F2 under it at 42 pt from the window top. The earlier "40/42 pt" figure
  included the card inset. Nav glyph centres 21 / 58 / 94 pt from the card's left edge.
- Favorites tiles: 47 pt tall, 8 pt gaps, corners fit a circular 26 px radius (13 pt).
  Inactive tile = sidebar colour × 0.955 (black ≈ 4.5 %); active tile = white ≈ 38 % over
  the sidebar (same as the hover fill) with a 2 pt rim of black ≈ 17 % inside the edge.
  No dashed ring on a clicked tab (the yellow/black ring stays keyboard-only).
- Sidebar glyphs (sidebar toggle, library, +) render at ≈ 26 % black over the sidebar
  (toggle 179/173/144 over 229/221/184); Cra had them at 58 %. Arc's library icon is a
  filled box with a confetti puff above it; Cra uses `archivebox.fill` (no puff).
- Not verified here: hover fills and animation timings. Window-id captures cannot show
  hover states, and the Mac was in use (Dia full screen in front), so no pointer was moved.

### Little Arc (24 Oct, night) → Cra's Little Windows

Observed live in Arc 1.168 (`open -a Arc <url>` with Arc in the background opens a Little
Arc; window captured with `screencapture -l`, hover states by moving the pointer with
`cliclick m:`, the open animation with `screencapture -V` at 60 fps, colours probed per
pixel). StorableWindows.json records each one as `little { profile: {default: true},
session: { entryPoint: { externalLink } }, preferredFrame }`; closed ones land in the
archive with source `littleArc`; `LittleBrowserWindow_size` keeps the last size.

Window 1688×1010 (Victor's size), corners 10pt. One 46pt strip, no sidebar, page edge to
edge below it. Colours are the default profile's dark palette even with the light "Victor"
space focused (bar #0C091C = JYSK's toolbar colour, so the strip is theme-derived but not
from the focused space; Cra uses the measured values as a fixed palette):
- traffic lights at x 17/39/61, 12pt muted grey discs (#565660) that colour only while the
  pointer is over them;
- search pill x 83 → 10pt before the button, y 8…38 (30pt, radius 8), fill #252234, hover
  #2D2E3E; magnifier 13pt at x 100; URL host 13pt #A3A1A9 centred; puzzle (extensions)
  and link (copy URL) icons 16pt #6E6F80 centred 46pt / 15pt from the pill's right edge, hover
  = 26pt rounded square #413946 with a brighter glyph;
- "Open in **Victor** ⌘O | ⌄" button, 7pt from the right edge, 30pt tall, radius 7, fill
  #050625 with a 1px #1D1E37 border; "Open in" 13pt medium #828392, the space name 13pt
  bold in the target theme's light foreground (Victor → #FCEDBC), ⌘O badge 33×16 radius 4
  #171832 / text 11pt #8B8C99; 1px divider, 29pt chevron part; each half lightens to
  #161734 on hover;
- clicking the pill (or ⌘L / ⌘T) opens Arc's command bar inside the window, 500pt wide,
  its top a third of the way down, URL prefilled and selected;
- the chevron opens LittleBrowserMoveMenu: a 240pt navy popover (#050625, 1px #1D1E37
  border, radius 12) hanging from the window's top-right corner: "Search Spaces…" row with a
  28pt chevron-up button (#5C5C71), then 54pt rows (40pt radius-9 tile in the space colour
  with the emoji, 15pt semibold name), highlighted row #161734; typing filters, ↩ moves the
  tab there;
- ⌘O ("Open in <space>") moves the page into that space; ⌥⌘N makes an empty Little Arc;
  Window ▸ Close Little Arc Windows exists;
- opening: the window grows from a small rectangle under the pointer to its full frame in
  ~120 ms (6–7 frames), content laid out at full size, no fade.

Second pass (25 Oct, morning), hover details: the traffic lights are #686871 discs while the
window is key and the pointer is elsewhere; the puzzle, link and chevron controls show Arc's
own tooltip after ~0.4 s, a 28pt pill (#0A0D4B, 1px #22255D border, radius 10) hugging the
strip's bottom edge, 14pt semibold #DEDFFD text, shortcut key caps 20pt (#D3D4FD, glyphs
#282EFC): "Extensions", "Copy URL ⇧ ⌘ C", "More Spaces" (the latter right-aligned to the
window edge). The "Open in" halves have no tooltip. Cra reproduces all of it in
LittleWindowController (LittleTooltip); hover is tracked by AppKit with an activeAlways
tracking area because SwiftUI's onHover sleeps while the Chrome page window is the key
window.

### Live re-fit against Victor's full-screen screenshots (24 Oct, 20:21)

Victor's side-by-side screenshots (Cra and Arc both at 1728×1084, each with the other
browser behind it) showed Cra's sidebar 6–17/255 darker and more saturated than Arc's at
every height except the very top, and Cra's row text pure black where Arc's is warm.
Sampled at x=500 px (2x), y = 160 / 700 / 1200 / 1700:
- Arc live: 134 131 98 · 149 139 102 · 151 136 99 · 163 139 103
- Cra before (lift 0.03): 128 121 86 · 137 125 89 · 143 127 91 · 146 126 90
- Cra after (lift 0.12): 139 134 100 · 152 141 106 · 160 143 108 · 162 141 108
Changes: `CraTuning.liftActive` 0.03 → 0.12; light-theme `textPrimary` = first theme colour
at 13.5 % brightness (`SpaceTheme.inkColor`, Victor → 33/28/11; Arc samples 32/26/0);
`textSecondary` black 0.58 → 0.50 (Arc's space header samples 75/74/57 over 150/138/100).
Folders: Arc draws `folder.fill` in the theme colour pulled 80 % to white (250/238/194)
under a `folder` outline in the toolbar colour (107/87/9); the old blue folder was wrong
for this theme. The blur reads ~70/255 lighter for the first second after launch (vibrancy
not yet active), so sample only after the window has settled.

### Picture in Picture (24 Oct, late evening)

Method: `strings` on Arc 1.168 and its ArcCore framework, `assetutil --info` on
ARC_PictureInPicture.bundle, Arc's defaults, and window captures / 120 Hz screen recordings of
Arc's PiP window driven with synthetic mouse events (file:// test page, w3schools mov_bbb.mp4,
the Extensions ▸ Picture in Picture menu item and the page's own `requestPictureInPicture()`).

- [O] Arc wraps Chromium's video PiP: ArcCore has `arc::VideoPiPCoordinatorImpl(content::
  VideoPictureInPictureWindowController*)`, the Swift `PictureInPicture` module has
  PIPWindowController/PIPWindowContent/PIPOverlayHostView, Controls with PlayControls and
  MeetingControls view models, DocumentPiPWindowController for document PiP, and
  WindowState+GoogleMeetAutoPiP (injected JS that clicks Meet's own PiP menu item).
- [O] Strings: setting "Enable Picture in Picture when you leave a video tab"; menu "Picture in
  Picture" under Extensions (no shortcut); command bar "Open Picture in Picture"; tooltips
  "returns to the original tab", "closes the pip window", "minimizes the pip window", "Skip back /
  ahead 15 seconds", "Drag upwards to seek precisely", "Keep Window on Top", "Open automatically";
  assets GoBack/GoForward (54 pt) and meet-pip-chat-(un)selected. Feature flags useChromiumAutoPiP,
  useChromiumAutoPiPForGMeetOnly, disableAutoPipGlobally, autoPictureInPictureOnWindowOccluded.
  Analytics: pictureInPictureModalShown/Closed/Minimized/BackToTab, pictureInPictureSharedTabSwitched.
- [O] Window: level 3 (NSFloatingWindowLevel), borderless, no title bar, standard window shadow,
  corners whose alpha ramp is 41/93/138/174/197/216/226/235/241/247/251 over x = 7…17 px at 2x and
  3.5 px on the diagonal = a 6 pt continuous corner. 782×440 for a 16:9 video on this 1728×1117
  display, first shown 10 pt from the top and right of the visible frame. `LastPiPPosition`
  (defaults, JSON) stores `{"screen":{"_0":{"topRight":{}},"_1":[782,440],"_2":0}}` and switches to
  `{"absolute":{"_0":[[x,y],[w,h]]}}` (bottom-left origin) once the window has been handled.
- [O] Appears in a single frame (120 Hz recording: luminance over the window area jumps from
  20.7 to 138.5 between two consecutive frames; no scale or fade).
- [O] Nothing is drawn on hover, click or Space-pause: captures at 0, 0.3, 0.8, 2 s after
  entering with slow and fast pointer sweeps, after clicking the window (it becomes key; a 10×10
  helper window appears at 0,1107) and after pausing with Space are pixel-identical to idle apart
  from the video. The tooltips above prove controls exist; whatever reveals them was not found
  with synthetic input, so Cra draws nothing on hover either. [U] Their layout.
- [O] Closes as soon as the window its tab lives in becomes key again (also for a PiP the page
  started itself). The AX tree of the window is empty (AXSystemDialog, no children).
- [O] Arc's Extensions ▸ Picture in Picture does nothing on a page whose video has not started.

Cra: Chromium's PiP window (class NativeWidgetMac…, title "Picture in Picture", level 3, default
384×216 bottom-right, Chrome's hover controls) is reshaped by `PictureInPictureChrome`: opaque off,
6 pt continuous corner mask on the content view, Arc's frame, and a transparent child window on top
that swallows the pointer (so Chrome's controls never appear) and does dragging / aspect-locked edge
resizing; the frame is remembered in UserDefaults like Arc's LastPiPPosition. Measured on Cra: the
corner alpha ramp and the shadow extents are identical to Arc's capture, pixel for pixel.
One residual difference: Chrome paints its origin strip ("File on your device", top gradient)
inside the compositor layer for about two seconds when the window first appears (present at
1.5 s, gone at 2.5 s in quarter-second captures); it is drawn whether or not the window is
resized or focused, so it cannot be suppressed from CEF. After that nothing is drawn, as in Arc.

Chromium only enters PiP from a page holding a user activation. `CefBrowserHost::SendKeyEvent`
never reached the page in Chrome-style hosting (CEF 154), so Cra sends an F19 key down/up straight
to Chromium's `RenderWidgetHostViewCocoa` (the view AppKit gives real key presses to); the page sees
`keydown F19` with `navigator.userActivation.isActive = true`, and the injected script requests PiP
once activation is reported. Test videos must be open codecs (VP9/Opus WebM): the CEF build has no
H.264/AAC, so an MP4 never loads metadata.

### Hover, toolbar colour, library glyph (24 Oct, late evening)

- Row hover (pointer moved onto "Google Search Console", screen capture, same backdrop):
  Arc 220/210/171 → 210/200/163, i.e. the row darkens by ≈4.5 % black. Cra's `hoverFill`
  was white 38 % (lightening); now black 4.5 % on light themes. The active favourite keeps
  its white 38 % fill explicitly.
- Toolbar colour: Arc tints the bar from the page (theme-color meta, else the page
  background). Cra's probe had an unreachable body/html fallback (a `__none__` sentinel was
  set first), so pages without a meta tag got the space tint. Fixed: meta → body
  background → html background → white. Cra's New Tab page now gives a 34/34/34 bar.
- Library glyph: `LibraryButton` composes `archivebox.fill` with a cloud, dot and triangle
  puff; Arc's box has no lid line, otherwise the same silhouette at 14 pt.
- `liftActive` settled at 0.10 (0.12 read 2–9 lighter than Arc mid-sidebar).

### Split View, observed live (Arc 1.170, 24 Oct 2026, late evening)

Window captures of Arc's main window while driving it (menu clicks, synthetic drags), compared with Cra's
isolated test instance; composites in docs/screenshots/compare-*.png.
- [O] "Add Split View" on a selected tab: the new empty pane appears fully laid out within one frame (window
  frames at 27 fps); the command bar fades in over the new pane, horizontally centred on it but kept inside the
  window (right margin ~80 pt), with Arc's "Search or Enter URL…" new-tab bar, not the edit-URL bar.
- [O] Pane cards: 10 pt gap, both cards rounded; each pane has its own toolbar with ← → and a close ✕ at the
  right (no refresh button); the focused pane additionally shows a split-options button (rectangle.split
  glyph) just before its ✕. The URL is centred; in narrow panes the link glyph is dropped.
- [O] The empty pane is the window gradient plus a white veil of about +9/+11/+12 per channel (≈ 0.2 alpha),
  with a hairline under its toolbar.
- [O] Hovering the gap between panes shows no handle. Dragging from the gap did not resize in our runs: Arc
  entered its pane-drag mode (whole window content scaled down, a translucent drop region with a thin border
  opened at the target slot) and on release a duplicate pane was inserted. Divider resize therefore remains
  [U] for exact feel; Cra resizes with a plain pan, snaps at 50/50 and resets on double-click (from the
  recovered PaneResizeState).
- [O] Dragging a sidebar tab over the content: the entire window content shrinks (~0.92) and a lighter,
  bordered drop-region card opens at the edge nearest the pointer; dropping inserts the tab as a pane.
- [O] Splitting a favorite (YouTube) with a dropped pinned tab (Umami) left both in their sections and created
  a Today split item showing "YouTube | Umami"; a second drop produced "YouTube | Umami | Umami" (copies, not
  moves). While a new pane is still empty the sidebar shows it as a plain "New Tab" row in Today; the split
  cell appears once the pane has a page.
- [O] Sidebar split cell: one row, white rounded selected background, child segments (favicon + title) separated
  by hairlines, ✕ per child on hover.
- Cra status (this session): item model, store operations, multi-pane shell with per-pane toolbars and page
  windows, divider resize/snap/reset, Add/Close/Separate/Flip actions + View menu + ⌃⇧= / ⌃⇧−, command bar over
  the new pane, pinned/favorite anchors become Today copies, sidebar split row with per-child close and
  Option-click to unsplit, drop-on-row-right-half to split. Not yet: the drop-region placeholder over the
  content (CEF page windows receive the drag), the window shrink effect, and a 1:1 divider feel.

### DevTools docking, Arc's way (25 Oct)

Evidence from Arc 1.170.0: the ArcCore framework (REA `inspect-macho`, sha256 0a51a5c7…) carries
Chrome's stock DevTools embedder strings (`&can_dock=true`, `setInspectedPageBounds`, `setIsDocked`,
`currentDockState`, `devtools_app.html`), and Arc's profile Preferences hold the frontend's own dock
and device-mode state (`currentDockState`, `emulation.device-mode-value`, `emulation.show-device-mode`).
Arc's main window exposes one AXSplitGroup around the page's web area. So Arc does no custom docking.
It runs Chrome's DevToolsWindow: the frontend runs with `can_dock=true`, draws the splitter, the
dock-side menu and the device toolbar itself, and tells the browser where the page goes
(`InspectorFrontendHost.setInspectedPageBounds`); the browser lays the page over that rect.

Cra does the same with CEF 154, which only offers DevTools as an undockable popup:

- The Chrome-style DevTools popup is reloaded once with `can_dock=true` (CraCEF `DevToolsClient::Prepare`).
- `setInspectedPageBounds` and `setIsDocked` are mirrored to the shell as console messages
  (`__cra_devtools_bounds:` / `__cra_devtools_docked:`); `setIsDocked` is acknowledged in JS and never
  reaches Chrome, so Chrome does not try to move the contents itself.
- The DevTools window spans the card body under the page; the page window is laid over the reported
  placeholder (`MainWindowController.pageRect(forBody:tab:)`), which keeps the placeholder's edge
  offsets while the card resizes. Splitter drags stream a new rect every frame (verified: 15 updates
  in 0.45 s, page reflowed live). Device mode, dock right/bottom/left all work; "Undock into separate
  window" turns the DevTools window into a normal floating window and the page fills the card again.
- Frontend helper popups (`device_mode_emulation_frame.html`) are blocked; a popup whose client is
  not a page client is no longer cast blindly (that cast crashed Cra on undock).

Two hosting bugs found on the way, both affecting every page, not just DevTools:

- Chromium lays its frameless window's content view 22 pt below the top (room for a hidden title
  bar), which left a white band above every page. The shell now sizes the content view to the window.
- Chromium's frame view derives from NSThemeFrame, so macOS clipped page windows to its ~18 pt window
  corner radius even when borderless (rounded page corners under the toolbar and against DevTools).
  `ChromiumWindowCorners` overrides the frame view's corner queries for docked page/DevTools windows
  only; the content layer's mask then gives the card's 6 pt bottom corners.

Debug aids: `defaults write io.github.rainmiku.cra devToolsLog -bool YES` logs the DevTools life cycle to
`$TMPDIR/cra-devtools.log`; `cra://debug?devtoolsjs=<script>` runs a script in the current tab's
DevTools frontend (used to toggle device mode, dock sides and drag the splitter in tests).

### Sidebar icons and the Ahrefs subtitle (25 Oct)

- Arc's `SidebarItemsFaviconCache` names each 32x32 PNG `md5(sidebar item id)` (218 of 226 tabs matched);
  Cra's Arc importer already copies these. Once a tab loads, both browsers show the live page's icon,
  so Gmail/Calendar favourites show Google's "G" in Cra only because Cra is not signed in to Google
  (the tabs sit on accounts.google.com). Signing in inside Cra fixes it; nothing to fake.
- Arc shows "ahrefs.com" under the renamed Ahrefs pin and nothing under TradeTracker. Arc's stored
  data for both is alike (custom title, savedURL equal to the live URL, no extra keys), the pointer
  was not hovering, so the rule depends on live state Arc does not persist; still unknown. Cra shows
  "id.tradetracker.com" under TradeTracker because, signed out, that tab redirects to the login host.

Chrome runtime session restore (25 Oct): after a run that did not quit cleanly (SIGTERM from a
test script, a crash) the profile keeps `profile.exit_type = "Crashed"` plus Default/Sessions, and
the Chrome runtime restores the last session into a stock Chrome window (title bar, location bar,
1200×1084 at 22,33) as soon as the first browser is created; marking the profile clean alone does
not stop it. CraCEF now deletes Default/Sessions and writes exit_type Normal before CefInitialize
(verified: SIGTERM, relaunch, no stray window). Verification captures for PiP live in
build/pip-verification (arc_/cra_ idle, hover, shadow, and compare_*.png).

### Same-backdrop calibration, 25 Oct 2026 (CraVis test instance, solid white/black behind)

Method: a renamed copy of build/Cra.app (`CraVis`, own `CRA_DATA_DIR` with Victor's prefs)
launched from the shell with `CRA_TUNING="lift=…&alpha=…&alphaTop=…&alphaBottom=…&material=N"`,
a full-screen solid window ordered directly behind the measured window, `screencapture -R`
of the sidebar strip, pixel runs at x=500 px (2x), y = 160/700/1200/1700/2100.
- Arc 1.170, Victor theme — white: 204/197/164 · 215/208/167 · 218/201/160 · 219/193/159 ·
  218/188/154; black: 123/116/83 · 139/124/90 · 146/129/89 · 154/128/94 · 159/129/95.
  So Arc = c + k·backdrop with k 0.32 (top) → 0.23 (bottom).
- Material responses with the gradient and lift off (black / white at 2x): hudWindow dark
  27 / 160 (passes 52 %), fullScreenUI dark 30 / 139, popover dark 33 / 121, menu 37 / 101,
  titlebar 52 / 97, selection 41 / 106, sidebar & underWindowBackground dark 41 / 83,
  hudWindow light 113 / 226, sidebar & underWindowBackground light 194 / 218, windowBackground
  and contentBackground opaque. Nothing passes more than hudWindow dark, and nothing bright
  passes much at all, so Arc's 32 % with a 123-level intercept is not reachable exactly.
- Final: hudWindow dark, lift 0.14, gradient opacity intensity×1.44 (0.36) at the top and
  ×2.22 (0.56) at the bottom, stops = the theme colours unchanged. Cra — white: 190/185/157 ·
  204/193/161 · 208/192/159 · 208/188/154 · 211/188/152; black: 118/114/87 · 135/124/94 ·
  144/128/96 · 150/132/98 · 157/135/99. Within 5 of Arc over black, 7–15 darker over pure
  white (≈6–8 over a mid-tone desktop). An additive (CIAdditionCompositing) lift was tried
  and misbehaves over the vibrancy layer (k jumped to 0.48); keep the alpha-white lift.
- Hover (pointer moved, same backdrop): Arc row 220/210/171 → 210/200/163, favourite tile
  207/194/166 → 197/184/158; Cra row 207/198/160 → 198/189/154 (same Δ), tile hover now
  black 9 % (was equal to the resting tile).
- Toolbar: white until the page reports a colour (meta theme-color, else body/html
  background, else white), as Arc.
- Sidebar toggle (⌘S) recorded at 60 fps with `screencapture -V`, per-frame mean |Δ| on the
  sidebar strip: Arc moves for 5 frames (108, 34, 15, 6, 1 → 66 % of the travel in the first
  frame, then a soft landing); Cra 5 frames (59, 160, 35, 13, 10; the first value is a
  frame cut by the keypress, so 79 % in the first two frames). Same length, same ease-out.
- Toolbar on the same page (example.com, 25 Oct): Arc's bar reads 34/34/34, i.e. the page's
  own colour, not a fixed white; Cra derives it the same way (meta → body → html → white).
- Final sidebar numbers (balanced): black 120/116/89 · 135/124/94 · 144/128/96 · 152/133/99
  · 160/137/100; white 193/188/159 · 204/193/162 · 209/193/159 · 211/191/156 · 214/190/155.
  Blend-mode lifts (CIAdditionCompositing above or below the gradient) blow out: in-process
  compositing never sees the window-server blur, so only alpha blending composes correctly.
- Same page in both (example.com via `cra://navigate` in the test instance, AppleScript
  `make new tab` in Arc): Cra's bar 34/34/34 over rows 20–100 px, Arc's 34/34/34 over 20–83
  with its 1 px 45/45/45 hairline. Library glyph redrawn as a lid-less 13×10 box with a slot
  under the confetti puff.

### Sidebar scrolling (Arc 1.170, 25 Oct 2026, AX tree + window-id captures)
- [O] Only the space's tab list scrolls. The AX tree puts favorites (window y 36–99) and the space page
  (y 99+, a 568pt-wide horizontal pager group) side by side; inside the page the header row (y 99–135) sits
  above an `AXScrollArea` 284×899 at y 135–1034 that holds the `sidebarAllTabList` outline. Scrolling it
  (AX scroll-bar value 0 / 0.5 / 1) leaves favorites and the "Victor" header in place.
- [O] Outline: a 3pt top spacer row, 41pt rows, the pinned/today divider as a 17pt row, and ~121pt of
  empty list after the last row (at full scroll the last row ends 121pt above the dock).
- [O] Edge hairlines: full sidebar width, 1pt, ~5% black over the light theme (227 → 216), top one at
  y 135 shown only while the list is scrolled away from the top, bottom one at y 1033 shown only while
  rows are hidden below the viewport (the trailing empty space does not count). Both fade over roughly
  0.2–0.3s (window captures 0.2s apart showed partial strength in the first frame).
- [?] Dark-theme hairline colour (no dark Arc sidebar on screen; Cra uses 7% white) and whether Arc keeps
  each space's scroll offset across space switches (Cra currently resets to the top).
- Cra: favorites and `SpaceHeader` are outside the `ScrollView`; its viewport measures 0,168 284×899 in
  AX, identical to Arc, and the hairlines land on the same pixel rows (270/271 and 2066/2067 @2x).
- Toolbar hairline: Cra now draws Arc's 1 px line under the bar on the card (white 5 % on
  dark bars, black 5 % on light ones); on example.com Cra reads 34 with 45 at rows 82–83,
  Arc 34 with 45 at rows 84–85 (Cra's line sits inside the 32 pt strip, Arc's just under it).

### Backdrop-layer blur for light vibrant themes (25 Oct 2026, final)

The system materials could not reproduce Arc's intercept and slope together, so
`ShellView` now blurs light vibrant themes through an untinted `CABackdropLayer`
(`CIGaussianBlur` radius 28) under a black dim layer and a white lift gradient; the
`NSVisualEffectView` path stays for dark themes and as a fallback if the class is missing.
Raw layer response over the same solid backdrops: black 6, white 240 (passes 92 %).
Model: out = a·G + (1−a)·[L·255 + (1−L)(1−D)·blur]. Baked: D 0.23, L 0.21 (top) → 0.18
(bottom), gradient opacity intensity×1.65 (0.42) → ×2.30 (0.58). Measured on the baked
build, five heights, R/G/B:
- white — Arc 204/197/164 · 215/208/167 · 218/201/160 · 219/193/159 · 218/188/154;
  Cra 201/196/165 · 213/202/168 · 219/203/167 · 218/198/161 · 217/193/156.
- black — Arc 123/116/83 · 139/124/90 · 146/129/89 · 154/128/94 · 159/129/95;
  Cra 126/121/90 · 140/129/95 · 149/133/97 · 154/134/97 · 155/131/94.
Every channel within 8 levels, red within 4, at every height over both backdrops.
`CRA_TUNING` keys for the path: `dim`, `lift`, `liftBottom`, `alphaTop`, `alphaBottom`.
- Baked constants after the last fit: dim 0.19, lift 0.16 → 0.18, gradient opacity
  intensity×1.70 (0.43) → ×2.35 (0.59). Measured (c7 run): white 207/202/169 · 217/206/171 ·
  217/201/165 · 218/198/162; black 125/120/87 · 138/127/92 · 143/127/91 · 152/132/96 at
  y = 160/700/1200/1700 (y = 2100 sits under the Dock and is unreliable). Arc re-measured
  over black twice: identical to the level, so the capture noise floor is ≈1.
- Sidebar hidden (⌘S): Arc keeps the rounded card in its 10 pt inset (card edge at 20 px
  after the hide) and puts a sidebar toggle first in the bar, centred 30 pt from the card
  edge, then ← → ↻ at 37 pt pitch. Cra used to go edge to edge; it now keeps the inset and
  shows the toggle. Hide trajectory (card edge, px per 60 fps frame): Arc 568 → 204 → 90 →
  42 → 24 → 20; Cra 568 → 202 → 70 → 32 → 22 → 20 (duration 0.08 s, curve 0.2/0.85/0.25/1).
- Confirmation on the installed build (baked3 run, y = 160/700/1200/1700): white
  203/199/166 · 216/205/170 · 217/201/166 · 220/199/163 vs Arc 204/197/164 · 215/208/167 ·
  218/201/160 · 219/193/159; black 121/117/84 · 137/126/91 · 143/127/92 · 154/133/97 vs
  Arc 123/116/83 · 139/124/90 · 146/129/89 · 154/128/94. Max |Δ| 6, median 2, noise ≈1–2.
- Hide easing refitted to Arc's per-frame progress (66 / 87 / 96 / 99 %): duration 0.085 s,
  curve 0.15/0.7/0.3/1. Two Cra recordings: 568 → 200 → 74 → 36 → 22 → 20 and 568 → 200 →
  74 → 26 → 20; Arc 568 → 204 → 90 → 42 → 24 → 20. Run-to-run spread between the two Cra
  takes (10 px on frame 3) is the keypress phase relative to the 60 Hz capture, so the
  remaining Arc/Cra gap on frames 2–3 (16 / 6–16 px) is at the measurement's resolution.

### Sidebar translucency, re-fitted 25 Oct 2026 (11:30)

The CABackdropLayer path had been calibrated while its blur filter was inert (a CIFilter in
`filters` is ignored for the backdrop capture), so the window behind showed through sharply.
With Core Animation's own gaussianBlur (radius 40) in place, Arc 1.170 (active, Victor theme,
upper sidebar, same screen) measures 184/177/137 over 50 % grey stripes and 213/206/167 over
white: pass-through k ≈ 0.21, ≈158/151/111 over black. Cra with lift 0.35→0.37 and dim 0.36:
185/175/140, 213/203/168, 159/149/114 (k 0.21). Arc's blur also erases a 60 pt stripe pattern
completely; Cra's does too (residual amplitude ≤ 1/255).

### Picture in Picture hover controls (25 Oct)

Victor reports Arc's PiP shows buttons on hover (back to tab, play/pause, close). None of the
captures above could reproduce them: every earlier test window was Little Arc (a URL opened
from outside Arc), and "Extensions ▸ Picture in Picture" is Google's Picture-in-Picture
extension, not Arc's own feature. A regular Arc tab playing audible video (−60 dB tone) and
then left with ⌃Tab did not open Arc's auto PiP on this Mac either, so the setting is likely
off here; it is not stored in any readable file (Arc's Storable*.json, Chromium Preferences or
defaults). [U] Arc's control layout and styling.

Cra's controls, built from Arc's control inventory (strings above): close (top-left, "closes
the pip window"), back to tab (top-right, "returns to the original tab", `pip.exit`), play/pause
centred between "Skip back 15 seconds" / "Skip ahead 15 seconds". White SF Symbols, translucent
disc on hover (white 20 %, 32 % pressed), a black scrim (45 % at the edges, 15 % in the middle)
that fades in over 0.15 s when the pointer enters and out over 0.25 s when it leaves or rests for
2.5 s. Verified in a scratch Cra: controls appear on hover, pause stops the video (frame counter
froze 5 frames after the click), back to tab brings the source window up and returns the video.
Captures: build/pip-verification/cra_ctrl_*.png. To be calibrated against a capture of Arc's
hovered PiP.
- Inactive window (25 Oct, 12:10): Arc drops the backdrop and shows a flat 149/143/104 regardless
  of what is behind. Cra used to switch to a 0.75 white lift (244/234/199 over white, 211/201/166
  over black), which made the sidebar flip between dark-translucent and pale on every app switch.
  Now dim 1.0 + lift 0.28 while inactive: 149/139/104 over both white and black.

## Dia import onboarding (Dia 1.54.2, 25 Oct 2026)

Source of Cra's import window (Sources/Cra/UI/Onboarding). Evidence: strings and Swift reflection
metadata (`__swift5_fieldmd`) of `Dia.app/Contents/MacOS/Dia`, asset catalogs read with
`Bundle.image(forResource:)` / `NSColor(named:bundle:)`, and window captures of Dia's own flow
opened from Dia ▸ Import from Another Browser… (stopped before "Begin Importing", nothing imported).

- [O] Views (module `Onboarding`): `ImportView`/`ImportContentView` hosts `ImportSelectionView`
  (collection of `ImportBrowserItemView`: icon, label, radio button, spinner, "N of M spaces"
  profiles button), `ImportProfilesView` (space/profile checkboxes), `ArcPreviewContentView`
  (`SpaceCheckboxView` rows + `DiaSidebarPreviewView`: favourites cells, header label, tab-group
  rows), `ImportProfilePickerView` ("Unlock your data for import", keychain), `ImportProgressView`
  (`CategoryItemView` tiles, paced by `ImportProgressController.progressUIIntervals`) and
  `ExtensionsView` (`BrowserExtensionCheckBox`: icon, name, checkbox, install spinner;
  `ExtensionsController` installs from the Web Store and tracks installed/failed IDs).
- [O] Copy: "Import now to get connected" / "Import once and stay in your flow. Your apps, tabs,
  passwords, bookmarks and extensions come with you."; "Select spaces to import" / "We'll import
  your Arc spaces, tabs, and folders to Dia."; "Customize which spaces to bring over to Dia";
  "Import your extensions" / "Pick your essentials. You can always add more extensions later as
  you settle in with Dia."; "Importing from %@" / "Hold on while we fetch your data"; "Some import
  steps failed:", "%@ import failed".
- [O] Geometry (dark, 2x captures, AX frames): window 928×544, no title bar, close ✕ 26×22 at
  (887,16). Left column x 32, width 440: serif title (Exposure-550) top 56, cap height 20.5,
  713 px wide; subtitle 15 pt SF, line pitch 21.5, top 104; browser cards 215×80 in a grid at
  y 174 with 10 pt gaps, no fill, hairline #5E5E5E (selected #9D9D9D), corner ≈22–24 continuous,
  logo 52×52 at (19,14), label 16 pt at x 82, radio 24 pt (ring 1.5 pt #505050; selected white
  ring + 17.5 pt disc) centred at x 173.5. Primary button 442×42 at y 470, #E0E0E0, 13 pt
  semibold black with a return glyph, disabled text #7F7F7F on the same fill. Secondary + primary
  pair: 146 + 290 pt, 6 pt apart. Art panel (painted `Rebrand*Screenshot`) from x 451, its left
  edge feathered with spray noise.
- [O] Colours (light / dark): ButtonPrimaryBackground black .85 / white .85; ButtonDefaultBackground
  .08 / .08; RebrandAppTitleText .85; RebrandBodyText .55; RebrandRowBackground black .015 / white
  .08; RebrandRowBorder .08 / .16; ImportSelectionCaption .3 / .4; ImportProgressItemBorder .1;
  LoadingSubtitle .3 / .4; Background white / black.
- [O] Extensions in Arc and Dia: `User Data/<profile>/Secure Preferences` → extensions.settings;
  location 1 (Web Store) manifests keep `key`, so a copy loaded with --load-extension keeps its ID.
  Cra copies the version folder to `<data dir>/Extensions/<id>` (location 8 in Cra's prefs);
  verified: 21 of Arc's extensions load with Arc's IDs. [U] Extension storage (Local Extension
  Settings) is not copied, so sign-ins inside extensions start fresh.
- Not reproduced: the Arc space step and the extensions step were not opened in Dia (the menu flow
  goes browser → "Unlock your data" → import; the space and extension steps belong to first-run
  onboarding), so their layout follows the reflection metadata and the measured browser step.
  Exposure and Dia's paintings are not shipped; Cra uses New York and draws its own art (badge
  ring after `RebrandImportScreenshot`, window mock after `RebrandArcImportPreviewScreenshot`).

## Default browser (Arc menu, Dia 1.54.2 onboarding, 25 Oct 2026)

Source of `SystemIntegration`, the onboarding's `.defaultBrowser` step and Settings ▸ General.
Static only: strings and `__swift5_fieldmd` of `Dia.app/Contents/MacOS/Dia`, art from
`BoostBrowser_Unboxing.bundle` (`Bundle.image(forResource:)`); Dia's onboarding was not re-run.
- [O] Arc app menu (user screenshot): Settings… ⌘, / Share Arc / Set as Default Browser with ⌘♡
  as its key equivalent (no key types ♡), then a separator before Import from Another Browser….
- [O] Dia's onboarding `Flow` enums list `newDefaultBrowser` ahead of `disclosure`, `import` and
  `importProgress`; Cra shows the step first on a fresh install, before the import.
- [O] `NewDefaultBrowserContentView`: two-line title "Fast, secure, and packed with all your browser
  essentials", rows `setAsDefaultRow`, `addToDockRow`, `launchAtLoginRow` (plus a trial checkbox
  Cra drops), each a `DefaultBrowserCheckboxRow` (checkBox over `rebrandBackgroundView`), and a
  button bar. Copy: "Set Dia as default browser" / "Open links and web pages in Dia by default";
  "Add Dia to Dock" / "Quick access to Dia whenever you need it"; "Open Dia at login" /
  "Automatically open Dia when you sign in".
- [O] `NewDefaultBrowserController` uses DefaultBrowserClient, DockClient (`getDockData`,
  `writeDockData`, `addCurrentApp`, order `beforeDefaultBrowser` / `afterDefaultBrowser`) and
  LaunchAtLoginClient; `Options` = defaultBrowser, addToDock, launchAtLogin; `isShowingPrompt`
  while the system dialog is up. Cra inserts its Dock tile after the current default browser's.
- [O] Art `RebrandDefaultBrowserScreenshot` (476×544 pt): the app tile (144 pt) raised out of a
  glass Dock strip (y 205–372) between two blank tiles (106 pt), running dot at (266, 338), on a
  warm painting. Cra draws it with its own icon and shows the current default browser as the
  left neighbour.
- [U] Which checkboxes Dia ticks by default, its skip button title and which Dock order it uses.
  Cra ticks default browser and Dock, leaves login off, and labels the secondary button Skip.

## Dia onboarding steps and multi-browser import (Dia 1.54.2, 25 Oct 2026)

Source of the full first-run flow (`ImportFlow`, `OnboardingSteps`) and the importers
(`BrowserSources`, `ChromiumImporter`, `FirefoxImporter`, `SafariImporter`, `CredentialImport`).
Static evidence: `__swift5_fieldmd`/`__swift5_reflstr` of `Dia.app/Contents/MacOS/Dia` (parser in
scratch `fieldmd.py`), its localization strings, and the SQLite/Keychain layout of installed
browsers on this Mac read read-only. Dia's onboarding itself was not re-run past the browser step.

- [O] Dia's onboarding `Flow` order: `newDefaultBrowser, connectedApps, atlassianFirstParty,
  disclosure, import, importProgress, importPasswordsAndCookiesResult, pinnedTabs, personalization,
  safariExportedData, extensions, outro` (`OnboardingStepName` adds welcome/auth/account). Cra runs:
  cover → default browser → privacy (disclosure) → import (source → Safari export / unlock → spaces →
  extensions → progress → passwords result) → pinned tabs → personalization → outro. Cra drops Dia's
  AI-tied steps (connected apps, Atlassian, ChatGPT memory opt-in, the "try for a week" trial).
- [O] Cover (`Auth flow cover page`): wordmark, one-line pitch, "Get Started" + "Sign In". Cra uses
  its own site tagline ("A calmer way to browse").
- [O] Privacy (`DisclosureView` / `DisclosureContentView`: `adBlockerRow`, `shareDataRow`): title
  "Privacy in Dia, you're in control"; "Block third-party ads and trackers" / "You won't see them.
  And they won't see you." Cra keeps the ad-blocker row (see "Third-party ad and tracker blocking")
  and drops Dia's share-usage-data row.
- [O] Unlock (`ImportProfilePickerView`): "Unlock your data for import" / "Some data is encrypted, so
  macOS will ask for your computer password …" with a per-profile picker when a browser has several.
  Result screen (`ImportPasswordsAndCookiesResultView`): success "Your passwords and cookies are now
  available …"; failure "Something went wrong" with Try Again / Skip.
- [O] Safari export (`SafariExportedDataView`): "Import from Safari", numbered steps (File ▸ Export
  Browsing Data to File), and a "Choose .zip file or drag it here" drop well; validator messages
  ("Please select a folder or zip file.", "The folder is missing required files …"). Cra reuses the
  drop well for Firefox's exported passwords CSV.
- [O] Pinned tabs (`PinnedTabsView` / `PinnedTabButton`): "Keep your favorites handy" / "Pin important
  apps …", a grid of preset apps (`PinnedTabs/Icons/*`: Gmail, Calendar, Slack, Notion, GitHub,
  Figma, YouTube, Spotify, Drive, Docs, Linear, Canva…) seeded from `rankedTopSitesTask`. Cra fills it
  from the imported browser's most-visited hosts (History/places.sqlite) plus the presets, with
  favicons from the source's Favicons DB.
- [O] Personalization (`PersonalizationView`): "Pick the theme color and layout that feel right for
  you.", colour swatches + a tab-layout picker ("Classic"/qualifier). Cra maps the swatches to
  `SpaceTheme.presets` and the layout to the toolbar setting.
- [O] Outro (`RebrandOutroView`): "Welcome to your new home on the internet" (older build: "Welcome
  to a better work day"), animated logo honouring Reduce Motion.
- [O] Importers. Chromium family (Chrome, Brave, Edge, Opera, Opera GX, Vivaldi, Chromium, and Arc's
  and Dia's own Chromium profiles): profiles from `User Data` (+ `Local State` info_cache), bookmarks
  from `Bookmarks`, open tabs from the SNSS `Sessions/Session_*` (command stream, versions 1 and 3;
  2/4 are encrypted), top sites from `History`, favicons from `Favicons`. Firefox/Zen: `profiles.ini`
  → profile, `places.sqlite` bookmarks + frecency top sites, `favicons.sqlite`, session from the
  `sessionstore*.jsonlz4` (mozLz4 = "mozLz40\0" + u32 size + LZ4 raw). Safari: only what it exports.
- [O] Passwords and cookies (`CredentialImport`). macOS Chromium v10 blobs = AES-128-CBC, key =
  PBKDF2-SHA1(secret, "saltysalt", 1003, 16), IV = 16×0x20; the secret is the login-Keychain item
  "<Name> Safe Storage" (one OS password prompt per browser). Cookies DB version ≥ 24 prefixes the
  plaintext with SHA-256(host_key) — checked to confirm the key, and re-added for Cra's own profile.
  Cra re-encrypts every row with its own key (`SafeStorage`: the "Cra Data Safe Storage" Keychain
  item, which `scripts/patch-cef-keychain.sh` makes CEF use instead of "Chromium Safe Storage"; older
  builds used `--use-mock-keychain`, secret "mock_password", and are migrated once) and stages them
  to `pending-credentials.json` (0600); `main.swift` writes them into
  the profile's `Cookies` / `Login Data` before CEF starts (both are locked while Chromium runs) and
  only when no other instance is up, then deletes the file. Verified end-to-end against this Mac's Dia
  profile (1 login + 3052 cookies decrypted, staged, applied on relaunch, idempotent on re-run).
- [U] Dia's exact top-sites ranking, its default checkbox states, and the encrypted SNSS v2/v4 session
  format. Firefox saved logins are not read from `logins.json`/`key4.db`; Cra takes Firefox passwords
  only via its own exported CSV, like Safari.

## Dia nav-bar status (Dia 1.54.2, 25 Oct 2026)

Static only (strings of `Dia.app/Contents/MacOS/Dia`, no decompiler; not observed at runtime).
- Dia confirms browser actions inside the navigation bar instead of a toast: the status view
  (`NavigationBar.AssistantBarStatusView`) takes the title/URL slot, e.g. "🔗 Copied Current URL"
  (user screenshot). Localisation comments call these "Nav-bar status" and ship Title Case and
  sentence case variants.
- Messages found: Copied Current URL, Copied URL as Markdown / URLs as Markdown, Copied to
  clipboard (link), copied (clean, tracker-free) URL(s), Copied login code, Cannot Add New Pane
  (split limit; `rectangle.portrait.split.2x1.slash` sits next to the view), extension installed,
  password saved, import progress/result, '<shortcut> again to <action>', trace status.
- Unknown: display duration and transition (no runtime capture). Cra shows the status for 2 s
  with a 0.15 s fade in / 0.2 s fade out (`SidebarUIState.flashStatus`).

## Dia Extensions menu (Dia 1.54.2, 25 Oct 2026)

[O] Menu bar order: Dia, File, Edit, View, Tabs, Bookmarks, History, Extensions, Window, Help (AX of
the running app). Extensions lists one item per installed extension with its 16 pt icon, in plain
ordinal order ("dataslayer" after "Vercel"), then a separator, "+ Add Extension…", "Manage
Extensions…", "Pin Extensions…" (strings "A menu item to add a browser extension" / "manage browser
extensions" / "pin extensions"; capture of the open menu). Items run the extension's action
(`BrowserExtensionActionsProxy.executeAction`). [U] What Add Extension… opens and the layout of the
pin UI. Cra: UI/ExtensionsMenu.swift. An item runs the extension's action on the current tab
(MainWindowController.runExtensionAction: Extensions.triggerAction over the DevTools pipe, Chrome's
real popup with activeTab); without the pipe it opens the popup page in a Little Window, else the
options page. Pin Extensions… is a checklist submenu backed by `ExtensionStore.pinnedIDs`.

## Toolbar extensions and Split View button (Arc 1.170, 25 Oct 2026)

- [O] Arc's content toolbar ends with the pinned extensions, an Extensions button and a Split View
  button (user screenshot: 1Password, Detailed SEO "D", sliders-in-a-square, split square).
  Pinned = Chromium's own `extensions.pinned_extensions` pref in Arc's profile
  (`aeblfdk…` 1Password, `pfjdepj…` Detailed SEO). Binary strings: `contentToolbarOpenExtensionsButton`,
  `extensionsMenu`, `didDismissExtensionsMenu`, "Open pinned extensions picker.", "Manage Extensions",
  `pinExtension:` / `unpinExtension:`; the Extensions button opens a menu, not a web popover.
- Cra: `ContentToolbarView.trailingButtons` (pinned icons from `ExtensionStore.pinnedIDs`, the menu
  bar's Extensions menu under the button, Split View → addSplitView).
- Running an action (CEF 154 has no extension API): `Extensions.triggerAction` over a private
  `--remote-debugging-pipe` (fd 3/4 held by Cra, `--enable-unsafe-extension-debugging`; CEF's own
  per-browser DevTools client gets "Method not allowed"). It needs the *tab* target (page →
  tab via `Target.attachToTarget` + `setAutoAttach` on each tab target) and a Chrome toolbar:
  with `CEF_CTT_NONE` Chromium segfaults (null extensions container), so page windows get
  `CEF_CTT_NORMAL` with the toolbar view hidden (`CRA_NO_CHROME_TOOLBAR=1` opts out). Chrome's
  real popup appears (activeTab granted; Detailed SEO analysed the page) anchored to the hidden
  toolbar; `ExtensionActions` moves it under Cra's button and keeps it there on resize.

## Third-party ad and tracker blocking (Dia onboarding privacy step, 25 Oct 2026)

Dia's onboarding checkbox "Block third-party ads and trackers" ("You won't see them. And they
won't see you.") maps to `AppSettings.blockAdsAndTrackers` (default on; Settings > Privacy).
`CraClient::GetResourceRequestHandler` attaches a `CefResourceRequestHandler` whose
`OnBeforeResourceLoad` returns `RV_CANCEL` when the request host, or a parent domain of it, is on
the bundled list and the request is third-party to the tab's top-level page (the page is not on the
listed domain and the two hosts are not the same site, eTLD+1 approximated without the PSL).
Main-frame navigations and downloads always load; subframes (ad iframes) can be blocked. Every Cra
tab, popup and Little Window, Alloy or Chrome-style, uses `CraClient`; DevTools does not. Matching
lives in `Sources/CraCEF/CraContentBlocker.h` (lock-free: an immutable set behind an atomic
pointer, plus an atomic switch), the API is `+[CraCEFRuntime setContentBlockingEnabled:]`,
`setBlockedDomains:`, `loadBlockedDomainsFromFile:completion:`, `shouldBlockRequestURL:onPageURL:`.

The list is `resources/blocklist/domains.txt` (22,510 domains, copied into
`Contents/Resources/blocklist` by `scripts/build.sh` and `scripts/dev.sh`), fetched 2026-10-25 and
merged from:

- AdAway default blocklist, https://github.com/AdAway/adaway.github.io (hosts.txt), CC BY 3.0.
- Anudeep's Blacklist, https://github.com/anudeepND/blacklist (adservers.txt), MIT.

Both allow redistribution in an MIT app with attribution, which is in
`resources/blocklist/NOTICE.txt`. Rejected: EasyList/EasyPrivacy (GPL-3.0 / CC BY-SA), DuckDuckGo
Tracker Radar (non-commercial), hagezi (GPL-3.0), Disconnect (GPL-3.0), StevenBlack unified hosts
(MIT itself but includes non-commercial sources such as MVPS). Domain lists can't catch first-party
ads served from a site's own hosts (YouTube video ads, Facebook/Instagram feed ads, sponsored
search results) or cosmetic ad slots; requests from service workers and extension background pages
(no browser) are not filtered.

## Dia space paging and window buttons (Dia 1.54.2, 25 Oct 2026, static only)
[O] = read from the binary, [I] = inferred, not observed running.
- [O] Swift field metadata: `ARCUI.PageSwipeController` (pages with widths, `pageOrigins`,
  `trackingState {isTracking, isAnimating}`, `scrollingShouldBeginHandler(NSEvent)`, `positionUpdateHandler`,
  `PagingPosition {floorPageID, ceilPageID, progress}`, `performsPageDetentHaptics`, `lastDetentPageID`,
  `NonGesturalScrollState {cumulativeDistance, lastEventTime, lastTriggerTime}` for wheels).
  Settling is `SettlingAnimation {fromPosition, targetPosition, positions, keyTimes, duration}` run as a Core
  Animation keyframe animation (`TabSidebar.PagingContainerViewController.CoreAnimationSettling`, `CADisplayLink`).
  `ARCUI.VelocityTracker {value, pastValues}` measures release speed.
- [O] `TabSidebar.PagingContainerViewController`: one `NSViewController` page per space in a horizontal
  `pagingContentView`, loaded lazily (`loadedPages`, `isPageCleanupScheduled`). `SpaceModels.SpacePagingTransition
  {fromSpaceID, toSpaceID, progress}` drives the window tint (`SpacePagingTintSettlingAnimation` keyframes colours).
  `PendingRubberBandSnapBack`/`RubberBandDragState` exist for the edges.
- [O] No `trackSwipeEvent` use: Dia reads raw scroll events. It imports `SwiftUI.Spring(duration:bounce:)` and
  `Spring.update(value:velocity:target:deltaTime:)`; the one sampler found passes `bounce: 0`, but its callers are
  physics code (atan2, pendulum), so the paging spring's own duration was not recovered.
- [I] Cra copies the structure: `SidebarRootView` pages every space side by side, `MainWindowController` locks the
  axis after 6 pt, tracks 1:1 with a 0.5 x rubber band past the ends, ticks `.alignment` haptics per page, and
  settles with `interpolatingSpring(duration: 0.4, bounce: 0, initialVelocity:)` seeded from the last 80 ms of
  deltas (flick > 0.8 pages/s or past half a page changes space). `PagedSpaceBackground` mixes the two spaces'
  gradients by progress. 0.4 s is a design choice, not a Dia measurement.
- [O] Window buttons: Dia's `Window.PlatformWindow` overrides only key/main bookkeeping, `styleMask` (pass-through)
  and `_usesCustomDrawing` (returns NO); no active-appearance override. Cra keeps its buttons coloured while
  inactive by overriding AppKit's private `_hasActiveAppearanceForStandardWindowButton:` (checked on a test window).

## Dia Settings window (Dia 1.54.2, 25 Oct 2026)

Evidence: window-id captures (`screencapture -l`) and the accessibility tree of Dia's own
Settings window (Dia ▸ Settings…, driven through AX: `AXSelected` on sidebar rows, `AXPress`
on the close button; synthetic clicks from cliclick did not reach the window), plus strings
and class names of `Dia.app/Contents/MacOS/Dia` (`Preferences.*`, `BoostBrowser_Preferences`).
Dark mode only; light mode was not observed.

- [O] Window `preferencesWindow`: 778×509, close button only (zoom/minimise disabled), hidden
  title, an `NSSplitViewController` (AXSplitGroup, splitter at 204, not draggable) whose sidebar
  is full height, and a unified toolbar (AXToolbar 52 pt) holding Back/Forward (41×52 each,
  drawn as one 69×38 capsule, black ≈25%, at x 214) and the pane title (15 pt bold, x 293).
  Traffic lights at (18,18). Window colour 61/57/54, sidebar 46/43/41 (wallpaper-tinted
  standard materials), a 1 pt lighter line (78/73/68) on the split.
- [O] Sidebar rows: Account, Tabs, Privacy, Profiles, Skills, Apps, Shortcuts, Advanced. Rows
  196×28 inset 8, first row 64 from the top, 20×20 glyph at +20, 13 pt label at +49. Glyphs are
  SF Symbols (person.text.rectangle, square.on.square, hand.raised, person, keyboard,
  gearshape.2; Skills and Apps are custom). Selected row: accent fill (1/158/255) + white text
  while key; grey fill (white ≈10%) + accent-coloured label when not key. Corner ≈6.
- [O] Card panes (Account, Privacy, Profiles, Apps): 13 pt semibold header 8 in from the card,
  cards 21 from the content edges, 20 below the toolbar, radius 12, fill white ≈7% (75/73/69),
  rows 43 tall (49 with push buttons), 10 pt insets, row dividers white ≈12% inset 10, 11 pt
  secondary footnote 5 below. Privacy: "Content blocking" → Block ads / Block cookie banners /
  Block trackers (NSSwitch 46×22, 20 pt coloured rounded-square glyphs: red hand, orange
  cookie, yellow glasses), "Advanced Settings" button 7.5 under the card; "Data" → "Share content
  data to help improve Dia" (off) + "This data will not be tied to your profile".
  Account: Name / Email (value secondary, "Edit") / Password ("Change…"); Sync card: 28 pt
  purple circle, "Sync — updated just now" + green dot, description, NSSwitch, divider,
  "Advanced…" / "Connect Another Device…"; a "More" (…) button below. Profiles: description,
  "New windows open with" popup card, "Profiles" list (colour dot, name, chevron, drag handle),
  "Create Profile…".
- [O] Form panes (Tabs, Advanced): a two-column NSTableView over the whole window width
  (label column 387 ending 8.5 before x 382.5 window-relative, controls at x 406), first row
  32 below the toolbar, checkboxes 18 tall on a 24 pt pitch, groups ≈14 apart (single-row
  groups 44 tall). Tabs: "Tab Layout:" two 142×135 image radios (Top of Window / Sidebar);
  "General:" Extend website color into tab bar, Haptic feedback when reordering tabs, Add new
  tabs to the top, Warn before closing last tab in a Profile (all on); "Tab Groups:" ⌘-clicking
  links creates tab groups, ⌥-⇧-click opens tab in group, Automatically group tabs for
  meetings, Add emoji to new tab groups (all on); "Tab Cleanup:" "Clean up tabs I haven't used
  in:" (off) + popup "12 hours" (disabled while off). Advanced: "General:" Automatically update
  Dia; "Sounds:" Chat events, Daily report; "Address Bar:" popup "Prefer Search Engine"
  (strings: automatic / prefer chat / prefer default search engine); "When quitting Dia:" Warn
  before quitting (off) + popup "Preserve Tabs and Windows" (strings: Close Tabs and Windows /
  system setting).
- [O] Shortcuts: NSSearchField 472×26 at (19,19) with a filter (line.3.horizontal.decrease;
  menu: Customized Shortcuts, Conflicting Shortcuts) and a more button (…; Reset All
  Shortcuts); a 272 pt list card (window colour, 1 pt white ≈6% outline, radius 12) 14 below:
  11 pt semibold grey menu-title rows (Dia, File, Edit, View, Tabs…) and 36 pt action rows
  (13 pt name, shortcut 13 pt secondary right-aligned, hairline dividers); selected row filled
  95/144/229 with white text. Detail column 15 to the right: 22 pt bold title, gearshape.fill
  button at the right, 15 pt secondary description ("Create a new tab."), then a black 29 pt
  field (radius ≈8) showing the keys in 15 pt white. Unselected: "Perform common actions in Dia
  faster and from anywhere." / "Select an action to customize its keyboard shortcut."
  Strings also name a details pane: "When shortcut conflicts", "Use Website First", "Prompt
  after using on Website", "(not remappable)".
- [O] Skills: master list (/Reply, /Summarize) with +/− and an "Edit Skill" button; Apps:
  Morning Brief row, Recommended/Connected/Available app rows with Connect / Auto-connected /
  Reconnect, "Request an App". Defaults seen in ~/Library/Preferences/company.thebrowser.dia:
  nativeAdBlockEnabled, tabReorderingHapticsDisabled, shouldWarnBeforeQuitting,
  autoCleanInactiveTabsEnabled, windowRestorationSetting, shouldShareUsageData.
- Cra: `Sources/Cra/UI/Settings/` reproduces the window (NSSplitViewController + unified toolbar
  with `.sidebarTrackingSeparator`, SwiftUI panes) with panes General, Tabs, Privacy,
  Extensions, Shortcuts, Advanced; Account, Profiles, Skills and Apps have no Cra counterpart.
  New settings: `hapticFeedbackOnReorder`, `warnBeforeQuitting` (NSAlert in
  `applicationShouldTerminate`, skipped on engine relaunch), `autoArchiveEnabled`.
- [U] Light-mode colours, the popup option lists, the Shortcuts details pane, hover states
  (the source list has none), and the "Advanced Settings" ad-block dialog were not opened.

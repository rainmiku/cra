// CraCEF: the Objective-C surface Swift uses to drive Chromium (CEF).
// Everything here runs on the main thread.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class CraBrowser;

typedef NS_ENUM(NSInteger, CraDownloadState) {
    CraDownloadStateInProgress = 0,
    CraDownloadStateComplete = 1,
    CraDownloadStateCancelled = 2,
    CraDownloadStateInterrupted = 3,
};

@interface CraDownloadInfo : NSObject
@property (nonatomic) uint32_t identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *fullPath;
@property (nonatomic, copy) NSString *suggestedName;
@property (nonatomic) int64_t receivedBytes;
@property (nonatomic) int64_t totalBytes;
@property (nonatomic) NSInteger percent;
@property (nonatomic) CraDownloadState state;
@end

@protocol CraBrowserDelegate <NSObject>
- (void)browser:(CraBrowser *)browser didChangeTitle:(NSString *)title;
- (void)browser:(CraBrowser *)browser didChangeURL:(NSString *)url;
- (void)browser:(CraBrowser *)browser didChangeLoading:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)browser:(CraBrowser *)browser didChangeProgress:(double)progress;
- (void)browser:(CraBrowser *)browser didFinishLoadingURL:(NSString *)url title:(NSString *)title statusCode:(NSInteger)statusCode;
- (void)browser:(CraBrowser *)browser didLoadFavicon:(NSImage *)image forURL:(NSString *)iconURL;
- (void)browser:(CraBrowser *)browser didChangeStatusMessage:(NSString *)message;
/// The page's theme colour (meta theme-color or body background) as "#RRGGBB", or "" when unknown.
- (void)browser:(CraBrowser *)browser didReportThemeColor:(NSString *)hex;
- (void)browser:(CraBrowser *)browser didChangeFullscreen:(BOOL)fullscreen;
/// Cmd-click, middle-click and similar: open a plain new tab.
- (void)browser:(CraBrowser *)browser requestsNewTabWithURL:(NSString *)url inBackground:(BOOL)background;
/// window.open / target=_blank: return a popup host (a CraBrowser created with
/// a nil URL) so the popup keeps its opener relationship, or nil to block it.
- (nullable CraBrowser *)browser:(CraBrowser *)browser popupHostForURL:(NSString *)url inBackground:(BOOL)background;
/// Return a view to host DevTools in (Cra docks it inside the content card);
/// nil makes CEF open its own DevTools window.
- (nullable NSView *)devToolsHostViewForBrowser:(CraBrowser *)browser;
/// DevTools was created for docking (a host view was returned): `view.window`
/// is CEF's hidden Alloy window, to be attached as a child window.
- (void)browser:(CraBrowser *)browser didCreateDevToolsView:(NSView *)view;
/// The DevTools browser closed (either mode).
- (void)browserDidCloseDevTools:(CraBrowser *)browser;
/// Chrome-style hosting: the page's window exists (also for popups).
- (void)browser:(CraBrowser *)browser didCreateHostWindow:(NSWindow *)window;
/// Chrome's docked DevTools frontend placed the page: `bounds` are points with a
/// top-left origin inside the DevTools window's content view (setInspectedPageBounds).
- (void)browser:(CraBrowser *)browser devToolsPageBounds:(NSRect)bounds;
/// Chrome's DevTools frontend docked (YES) or undocked into its own window (NO).
- (void)browser:(CraBrowser *)browser devToolsDocked:(BOOL)docked;
/// Reserved shortcuts, before the page sees the key. Return YES to consume.
- (BOOL)browser:(CraBrowser *)browser handleKeyEvent:(NSEvent *)event;
/// Keys the page did not handle (Chrome gives the page first chance at
/// unreserved shortcuts like ⌘F). Return YES to consume.
- (BOOL)browser:(CraBrowser *)browser handleUnhandledKeyEvent:(NSEvent *)event;
- (void)browser:(CraBrowser *)browser didUpdateDownload:(CraDownloadInfo *)download;
/// Ask the user. Each entry of `permissions` completes "<origin> wants to …",
/// e.g. "use your camera" or "record your entire screen". Requests Cra does not
/// support are denied before they get here.
- (void)browser:(CraBrowser *)browser requestsPermissionForOrigin:(NSString *)origin permissions:(NSArray<NSString *> *)permissions completion:(void (^)(BOOL allowed))completion;
- (void)browserDidReceiveFocus:(CraBrowser *)browser;
- (void)browserDidClose:(CraBrowser *)browser;
@optional
/// A video of this page entered or left Chromium's Picture in Picture window
/// (whether the page, the user or Cra asked for it).
- (void)browser:(CraBrowser *)browser didChangePictureInPicture:(BOOL)active;
/// The video in the Picture in Picture window started or stopped playing.
- (void)browser:(CraBrowser *)browser didChangePictureInPicturePlayback:(BOOL)playing;
/// The colour the page paints behind its content (root/body background, else the
/// canvas colour of its color scheme), as "#RRGGBB". The shell fills the area under
/// the page window with it, so a page lagging behind a resize shows no white edge.
- (void)browser:(CraBrowser *)browser didReportBackgroundColor:(NSString *)hex;
@end

@interface CraBrowser : NSObject
@property (nonatomic, weak, nullable) id<CraBrowserDelegate> delegate;
/// Embedded (Alloy) hosting: a plain NSView that owns the Chromium view. Put
/// it in your hierarchy and size it; Chromium follows.
@property (nonatomic, readonly) NSView *containerView;
/// Chrome-style hosting (see +[CraCEFRuntime setChromeHosting:]): the page
/// lives in its own frameless Chrome window, delivered through
/// -browser:didCreateHostWindow:. Attach it as a child window and size it.
@property (nonatomic, readonly, nullable) NSWindow *hostWindow;
@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *currentTitle;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isCreated;
@property (nonatomic, readonly) BOOL isClosed;
@property (nonatomic, readonly) BOOL hasDevTools;
/// Anything you want to hang on the browser (Swift stores the tab id).
@property (nonatomic, strong, nullable) id userInfo;

/// Pass a URL to create a browser now. Pass nil to create a popup host that
/// adopts the next popup CEF gives it (see -browser:popupHostForURL:...).
- (instancetype)initWithFrame:(NSRect)frame url:(nullable NSString *)url delegate:(nullable id<CraBrowserDelegate>)delegate;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)setFocused:(BOOL)focused;
- (void)showDevToolsInspectingPoint:(NSPoint)point;
- (void)showDevTools;
- (void)closeDevTools;
- (double)zoomLevel;
- (void)setZoomLevel:(double)level;
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFinding:(BOOL)clearSelection;
- (void)setAudioMuted:(BOOL)muted;
/// Chromium remembers Allow and Block answers to permission prompts per origin.
/// The ones remembered for the page's origin, e.g. "Clipboard: allowed".
- (NSArray<NSString *> *)rememberedPermissions;
/// Forgets them, so the page's origin is asked again.
- (void)forgetRememberedPermissions;
/// Pops the page's video out into Chromium's floating Picture in Picture
/// window. Manual requests toggle (a second call brings the video back).
/// `automatic` is the "leaving a video tab" case: only a playing video of some
/// size qualifies, and nothing happens when there is none.
- (void)requestPictureInPictureAutomatic:(BOOL)automatic NS_SWIFT_NAME(requestPictureInPicture(automatic:));
- (void)exitPictureInPicture;
/// YES while a video of this page is in the Picture in Picture window.
@property (nonatomic, readonly) BOOL isInPictureInPicture;
/// YES while that video is playing.
@property (nonatomic, readonly) BOOL isPictureInPicturePlaying;
/// Play/pause the video in the Picture in Picture window.
- (void)togglePictureInPicturePlayback;
/// Seek the video in the Picture in Picture window by `seconds` (negative = back).
- (void)skipPictureInPictureBy:(double)seconds NS_SWIFT_NAME(skipPictureInPicture(by:));
- (void)print;
- (void)viewSource;
- (void)executeJavaScript:(NSString *)script;
/// Asks the page for its background colour again (-browser:didReportBackgroundColor:);
/// pages can switch themes without a load.
- (void)probeBackgroundColor;
/// Runs script in this browser's DevTools frontend, if open (debug aid behind cra://debug?devtoolsjs=).
- (void)executeJavaScript:(NSString *)script inDevTools:(BOOL)inDevTools;
/// Chrome DevTools Protocol call on this browser's own session (no DevTools window).
/// `params` is a JSON object string; the completion gets the result JSON or an error.
- (void)sendDevToolsMethod:(NSString *)method params:(NSString *)params
                completion:(void (^)(NSString * _Nullable result, NSString * _Nullable error))completion;
- (void)notifyMoveOrResizeStarted;
/// Asynchronous. -browserDidClose: fires when Chromium is done.
- (void)close;
@end

@interface CraCEFRuntime : NSObject
/// Call once, after NSApplication exists, before creating browsers.
/// Experiment: a Chrome-style (extension-capable) Views window; the handler gets its NSWindow.
+ (void)spikeChromeWindowWithURL:(NSString *)url handler:(void (^)(NSWindow *))handler;
/// Host pages as Chrome-style windows (Chrome extensions, Chrome's docked
/// DevTools) instead of embedded Alloy views. Set before any browser exists.
+ (void)setChromeHosting:(BOOL)enabled;
+ (BOOL)chromeHosting;
/// Third-party ad and tracker blocking: subresource and subframe requests whose host
/// (or a parent domain) is on the blocked list are cancelled when they are third-party
/// to the tab's top-level page. Main-frame navigations always load. Takes effect for
/// the next request, any time, from any thread. Off until enabled.
+ (void)setContentBlockingEnabled:(BOOL)enabled;
+ (BOOL)contentBlockingEnabled;
/// Replaces the blocked list (bare domains; a domain also covers its subdomains).
+ (void)setBlockedDomains:(NSArray<NSString *> *)domains;
/// Reads and installs a list file off the main thread: one domain per line or
/// hosts-file lines ("0.0.0.0 example.com"), # comments. The completion gets the
/// domain count (0 when the file can't be read) on the main queue.
+ (void)loadBlockedDomainsFromFile:(NSString *)path completion:(nullable void (^)(NSInteger count))completion;
+ (NSInteger)blockedDomainCount;
/// The blocking decision for a request made by a page, for diagnostics and tests.
+ (BOOL)shouldBlockRequestURL:(NSString *)requestURL onPageURL:(NSString *)pageURL;
+ (BOOL)initializeWithCachePath:(NSString *)cachePath
                 userAgentProduct:(NSString *)product
                          logPath:(NSString *)logPath
                   useChromeStyle:(BOOL)useChromeStyle;
/// Runs the Chromium-integrated AppKit run loop. Returns after -quitMessageLoop.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;
/// Closes every browser, then quits the message loop once they are gone.
+ (void)closeAllBrowsersAndQuit;
+ (NSInteger)liveBrowserCount;
/// YES when initialize failed because another Cra is running and was told
/// about this launch (exit quietly).
+ (BOOL)anotherInstanceWasNotified;
/// Called in the running instance when another launch is handed over.
+ (void)setRelaunchHandler:(void (^)(NSArray<NSString *> *urls))handler;
/// Pages Chromium opens on its own (an extension's chrome.tabs.create or
/// windows.create, welcome pages after an extension loads). The handler gets
/// the URL to open as a Cra tab; Chrome's own window for it is closed.
+ (void)setStrayPageHandler:(void (^)(NSString *url))handler;
+ (NSString *)chromiumVersion;
+ (NSString *)cefVersion;
/// YES when the browser-level DevTools pipe is up (it needs fds 3/4 free at start-up).
+ (BOOL)hasBrowserDevTools;
/// Browser-level DevTools protocol call (Target.*, Extensions.*) over the private pipe.
+ (void)sendBrowserDevToolsMethod:(NSString *)method params:(NSString *)params
                       completion:(void (^)(NSString * _Nullable result, NSString * _Nullable error))completion;
/// Same, inside an attached target's session (Target.attachToTarget with flatten).
+ (void)sendBrowserDevToolsMethod:(NSString *)method params:(NSString *)params sessionID:(nullable NSString *)sessionID
                       completion:(void (^)(NSString * _Nullable result, NSString * _Nullable error))completion;
/// Protocol events from the pipe: method, params JSON, and the session they belong to.
+ (void)setBrowserDevToolsEventHandler:(nullable void (^)(NSString *method, NSString *params, NSString * _Nullable sessionID))handler;
@end

/// NSApplication subclass CEF requires (CefAppProtocol). Set as
/// NSPrincipalClass and created with +sharedApplication before anything else.
@interface CraApplication : NSApplication
@end

NS_ASSUME_NONNULL_END

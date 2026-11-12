# Changes on branch `ios-window`

For the owner's review. Purpose: the same Window + Instanced2D path on an
iPhone (UIKit window, Vulkan through MoltenVK), so Portal's iPhone app runs
the same UI and drawing code as the desktops. Nothing changes for existing
Windows / Linux / macOS programs except four no-op methods per backend.

## Window interface (src/Window/root.zig)

Added only what a touch device's shared UI needs; every backend implements
it (Win32, Wayland and AppKit as no-ops), and `checkInterface` checks it:

| Method / item | Desktops | iOS |
|---|---|---|
| `insets() Insets` | all zero | safe area (notch, home indicator) + keyboard height, framebuffer pixels |
| `showTextInput(TextField) bool` | `false` (keys come as `.key` / `.char`) | a UITextView over the given rect; keyboard, autocorrect, dictation |
| `hideTextInput()` | no-op | hides it, keyboard down |
| `textInputText(buf) []const u8` | `""` | the field's text (UTF-8) |
| `setTextInputText(utf8)` | no-op | replaces it (e.g. clear after send) |
| `Event.insets` | never | rotation, keyboard shown/hidden |
| `Event.background` / `.foreground` | never | scene entered background / came back |
| `Event.text_input` (`.changed` / `.submit`) | never | typing, dictation, Return |
| `runApp(AppOptions, entry, ctx) noreturn` | calls `entry` now, then exits | UIApplicationMain; `entry` on an app thread |
| `AppOptions` | ignored | keyboard-extension block, cover when inactive / captured, lock after background |
| `utf8Prefix(s)` | helper | helper |

Programs with an exhaustive `switch` over `Window.Event` need arms for the
four new events (Portal's TermView is updated on its own branch).

## Inverted control: how the shared loop runs on iOS

UIApplicationMain never returns, so on iOS the app's ordinary loop
(`while (pollEvent) ...; draw; waitEvents`) runs **unchanged on an app
thread**:

* `main` calls `Window.runApp(options, entry, ctx)`. On iOS that registers
  the app delegate, scene delegate and Metal view classes
  (`objc_allocateClassPair`) and enters UIApplicationMain.
* When the scene connects, the main thread builds the UIWindow, a
  view controller and the `RendererMetalView` (its `+layerClass` is
  CAMetalLayer), then starts the app thread, which calls `entry(ctx)`;
  `Window.init` there returns the handle to that window.
* UIKit callbacks (touches, layout, keyboard, lifecycle, text view) run on
  the main thread and push `Event`s into the same `Queue` the other
  backends use, under a pthread mutex, signalling a condition variable.
  `waitEvents` blocks on it (`pthread_cond_wait`, or a relative timed wait
  for a deadline); `wake()` from any thread signals it. Event-driven, no
  timers.
* Vulkan/MoltenVK presents to the CAMetalLayer from the app thread (allowed
  by Metal). Every UIKit call stays on the main thread: the app thread
  records what it wants (text field rect, text) and posts one coalesced
  `dispatch_async_f` to the main queue; clipboard reads/writes use
  `dispatch_sync_f`.
* `sceneDidEnterBackground` pushes `.background` and waits (at most 2 s)
  until the app thread has taken it, so no frame is being encoded when the
  app is suspended; the app draws nothing until `.foreground`.

Alternatives considered: (a) callbacks (`init/frame/event`) for every
backend: would have changed every host loop and the desktop backends;
(b) a run-loop observer driving the loop on the main thread: needs the
loop split into steps, i.e. the same refactor. The app thread keeps one
loop for every platform.

## iOS backend (src/Window/ios.zig, src/Window/ios_objc.zig)

* Touch: one finger. A tap becomes `mouse_down` + `mouse_up` where it
  landed (buttons, links); a drag past 10 pt becomes `scroll` (16 pt per
  notch, finger down = scroll up).
* Safe area from `safeAreaInsets`, keyboard from
  `UIKeyboardWillChangeFrameNotification` (`Insets.keyboard`), content scale
  from the screen; `layer.drawableSize` follows the view.
* Text: UITextView with smart quotes/dashes and autocapitalisation off,
  Return = submit (`.text_input = .submit`), keyboard appearance dark.
* Privacy (`AppOptions`, all off by default): refuse third-party keyboards
  (`application:shouldAllowExtensionPointIdentifier:`), cover the UI while
  inactive (before the app-switcher snapshot) and while
  `UIScreen.isCaptured` (`UIScreenCapturedDidChangeNotification`), keep the
  cover after a background trip until the app calls `ios.unlock()`.
* iOS extras for the app's own iOS section (not in the interface):
  `Window.ios.rootView()`, `uiWindow()`, `lock()`, `unlock()`,
  `isLocked()`, `setUnlockHandler()` (called when the app becomes active while locked, and on a tap on the cover), `postEvent()`, and `ios.objc` (runtime helpers, global
  blocks for completion handlers, main-queue dispatch).
* Fonts (src/Font/fontset.zig): iOS system font paths
  (`/System/Library/Fonts/CoreUI/Menlo.ttc`, ...), unverified on a device.

## Instanced2D

Already enables `VK_KHR_portability_enumeration` (+ the enumerate-portability
flag) and `VK_KHR_portability_subset` when offered, and
`VK_EXT_metal_surface` for `SurfaceSource.metal`; unchanged. MoltenVK is
found by the Vulkan package's loader (branch `moltenvk`: the app bundle's
`Frameworks/libMoltenVK.dylib` on iOS).

## Build

* `check-window` now also compiles the Window module for **aarch64-ios**, as
  an object (src/Window/ios_check.zig). It cannot link here: linking needs
  the iOS SDK (libSystem, libobjc, UIKit/QuartzCore/Foundation), which only
  a Mac has. The UIKit/libobjc/libdispatch symbols are `extern`s that
  resolve when the app links on the Mac.
* Module **"IosObjC"** (src/Window/ios_objc.zig): the iOS runtime layer on
  its own, for iOS code without a window (Portal's packet tunnel
  extension); the Window module imports the same instance on iOS. It uses
  ../MacOS for the Objective-C types.

## Zig std on iOS (0.18.0-dev.4)

`std.Io.Threaded` does not compile for iOS in this Zig: `getDevNullFd`
reads `null_file.fd`, but the iOS `NullFile` has no `fd` (reached through
`processReplace` -> `spawnDarwin`, and from std's default panic handler via
`debug_io`). The backend avoids std threads (pthread directly) and the
check root replaces the panic handler, so the Renderer's check needs no
workaround. A real app needs std.Io; Portal's `zig build ios` builds
against a copy of the Zig lib dir with that one line changed
(`.wasi, .ios, .tvos, .visionos, .watchos => struct {` -> `.wasi => struct {`
in std/Io/Threaded.zig), produced at build time; it should be reported
upstream and dropped when fixed.

## Gaps in ../MacOS (not modified)

* `OBJC.load()` always dlopens AppKit (absent on iOS) and keeps its symbol
  table private, so `OBJC.msgSend` / `sel` / `ClassBuilder` cannot run on
  iOS. ios_objc.zig reuses `OBJC.Object/Class/Selector/BOOL`,
  `OBJC.MsgSendFn` and `TYPES.CGRect/...` and binds libobjc with `extern`s.
  A `load(.{ .frameworks = ... })` (or an iOS branch loading UIKit) plus
  `ClassBuilder.addClassMethod`, `msgSendSuper` and a global-block helper
  would let both backends share one runtime layer.
* No UIKit wrappers (UIApplication, UIWindow, UIView, UITextView,
  UIPasteboard, NSNotificationCenter); ios.zig sends the messages
  directly.
* `TYPES` lacks `UIEdgeInsets` / `NSRange` (declared in ios_objc.zig).

## Status

Compile-checked only (aarch64-ios object). Needs a Mac with Xcode to link,
and an iPhone to run: verify touch mapping, keyboard insets, dictation into
the UITextView, the background hand-off and the font paths.

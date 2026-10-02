// MobViewModel.swift — Shared state store between BEAM NIFs and SwiftUI.
// NIFs call setRoot() from any thread; the @Published triggers SwiftUI re-render on main.

import SwiftUI
import Combine
import QuartzCore

@objc public class MobViewModel: NSObject, ObservableObject {
    @objc public static let shared = MobViewModel()

    // How long to wait for BEAM boot to produce a first screen before treating
    // it as stuck. An indefinite spinner and a persistent error look identical
    // to "frozen" from the outside — this turns a silent hang into an explicit,
    // diagnosable state instead of leaving the app on the black startup screen
    // forever (seen: App Store review reporting an indefinite/blank launch).
    private static let bootWatchdogSeconds: TimeInterval = 15

    @Published public var root: MobNode?
    /// Increments on every setRoot call; views use onChange(of: rootVersion) to
    /// trigger withAnimation rather than watching root directly (root identity
    /// may change even for same-screen re-renders).
    @Published public var rootVersion: Int = 0
    /// Increments ONLY when a navigation transition is requested.
    /// MobRootView uses this (not rootVersion) as the view identity (.id(navVersion))
    /// so the whole view is only torn down and rebuilt on screen pushes/pops,
    /// not on every state-update re-render (e.g., typing in a text field).
    @Published public var navVersion: Int = 0
    /// Transition type for the *next* root change. Read by MobRootView before
    /// calling withAnimation; not @Published to avoid spurious recompositions.
    public var transition: String = "none"
    /// Current startup phase message shown while BEAM is initialising.
    @Published public var startupPhase: String = "Starting…"
    /// Non-nil when a fatal startup error has occurred; the error screen stalls here.
    @Published public var startupError: String?
    /// The window scene this model is shown in (MOB-245), set by mob_nif's
    /// scene registry: its `UISceneSession.persistentIdentifier`. Nil until
    /// the model meets a scene. Read on the main thread to tag what the window
    /// reports (back gesture, size class) with the scene it came from.
    @objc public var sceneId: String?

    override convenience init() {
        self.init(watchdog: true)
    }

    /// `watchdog: false` for a further window's model: the BEAM is already up
    /// when that window connects, so a slow first frame there is not a stuck
    /// boot.
    @objc public init(watchdog: Bool) {
        super.init()
        guard watchdog else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootWatchdogSeconds) { [weak self] in
            guard let self, self.root == nil, self.startupError == nil else { return }
            let info = Bundle.main.infoDictionary
            let shortVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
            let build = (info?["CFBundleVersion"] as? String) ?? "?"
            self.startupError =
                "Startup is taking longer than expected — this usually means a " +
                "native call blocked the main thread during boot. Please force-quit " +
                "and relaunch the app.\n\nVersion \(shortVersion) (\(build))"
        }
    }

    /// Whether the most recent `setRoot` replaced the navigation stack.
    ///
    /// Read by `MobRootView` to decide whether the outgoing screen is still
    /// reachable and therefore worth retaining. Not `@Published`: it is
    /// consumed inside the same `rootVersion` change that carried it, and
    /// publishing it would trigger a second render for a value that never
    /// changes independently.
    public var replacesStack: Bool = false

    @objc public func setRoot(_ node: MobNode?, transition: String, replacesStack: Bool) {
        DispatchQueue.main.async {
            self.replacesStack = replacesStack
            let measuring = mob_native_stats_enabled() != 0
            let start = measuring ? CACurrentMediaTime() : 0

            self.transition = transition
            self.root = node
            self.rootVersion += 1
            if transition != "none" {
                self.navVersion += 1
            }

            if measuring {
                self.measureApply(from: start, transition: transition)
            }
        }
    }

    /// Record how long the main thread stays busy applying this tree.
    ///
    /// The `@Published` writes above only *schedule* SwiftUI's work. Building
    /// the view tree, laying it out and handing it to Core Animation all happen
    /// later in the same run loop pass, which is exactly the half
    /// `Mob.RenderStats` cannot see: its `set_root_us` closes when `setRoot`
    /// returns, and `setRoot` returns as soon as it has dispatched.
    ///
    /// A `beforeWaiting` observer is the closing bracket because it fires when
    /// the main run loop has nothing left to do and is about to sleep, which is
    /// after layout and display. `CATransaction.setCompletionBlock` was the
    /// obvious alternative and is wrong here: SwiftUI's update frequently lands
    /// in a later transaction than the one open at assignment time, so the
    /// completion fires before the work being measured has happened.
    ///
    /// The order matters as much as the activity, and getting it wrong fails
    /// silently with a plausible number. `beforeWaiting` observers run in
    /// ascending `order`, and Core Animation's transaction-commit observer sits
    /// at 2000000 (UIKit's post-commit handler at 2000001). SwiftUI evaluates
    /// bodies and lays out inside that commit, so an observer at order 0 fires
    /// *before* any of the work being measured and reports little more than the
    /// three property assignments above. `CFIndex.max` puts this last, after
    /// the commit, which is the only position where the closing bracket means
    /// what the doc above says it means.
    ///
    /// The observer is one-shot (`repeats: false`) and removes itself, so a
    /// burst of `set_root` calls in a single pass arms several observers that
    /// all fire on the same idle and each records its own start. That
    /// over-counts overlapping applies rather than losing them, which is the
    /// safer direction for a measurement whose purpose is to justify work.
    ///
    /// Two known biases, both upward, both worth knowing before trusting a
    /// tail figure. `beforeWaiting` fires only when the loop is actually about
    /// to sleep, so a main thread under continuous load can go many iterations
    /// without one and the sample absorbs all of it. And the observer is added
    /// to `.commonModes`, so a run loop excursion into a mode outside that set
    /// is reported as apply time when a common mode resumes. Read `max` and
    /// `p95` with that in mind; a single excursion poisons both.
    private func measureApply(from start: CFTimeInterval, transition: String) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { obs, _ in
            mob_record_native_frame((CACurrentMediaTime() - start) * 1_000_000, transition)
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
        }
        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    @objc public func setStartupPhase(_ phase: String) {
        DispatchQueue.main.async { self.startupPhase = phase }
    }

    @objc public func setStartupError(_ error: String?) {
        DispatchQueue.main.async { self.startupError = error }
    }
}

/// Call `body` with `sceneId` as a C string, or with nil, for the C functions
/// that take a scene id (mob_handle_back, mob_notify_size_class).
func mobWithSceneId(_ sceneId: String?, _ body: (UnsafePointer<CChar>?) -> Void) {
    if let sceneId {
        sceneId.withCString { body($0) }
    } else {
        body(nil)
    }
}

// UIHostingController subclass that intercepts the left-edge swipe gesture
// and forwards it to the BEAM as {:mob, :back}.
// Using UIScreenEdgePanGestureRecognizer rather than a SwiftUI DragGesture
// because it integrates cleanly with scroll views and doesn't require
// threading gesture priority through the view tree.
//
// Each window scene has its own hosting controller showing its own view model
// (MOB-245). The SceneDelegate creates the controller before it is in a
// window, so it starts on the shared model and switches to its scene's model
// once it knows the scene, before anything is drawn.
public class MobHostingController: UIHostingController<MobRootView> {
    override public func viewDidLoad() {
        super.viewDidLoad()
        let edgePan = UIScreenEdgePanGestureRecognizer(
            target: self, action: #selector(handleEdgePan(_:)))
        edgePan.edges = .left
        view.addGestureRecognizer(edgePan)
    }

    // `view.window` is guaranteed here (unlike viewWillAppear), and it runs
    // before the first frame is drawn, so a second window never shows the
    // first one's tree.
    override public func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        guard let scene = view.window?.windowScene,
            let model = mob_scene_attach(scene) as? MobViewModel,
            model !== rootView.model
        else { return }
        rootView = MobRootView(model: model)
    }

    @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .ended {
            mobWithSceneId(rootView.model.sceneId) { mob_handle_back($0) }
        }
    }
}

// Factory: lets ObjC (AppDelegate.m) create the SwiftUI hosting controller
// without knowing about the generic UIHostingController<MobRootView> type.
@objc public class MobUIFactory: NSObject {
    @objc public static func makeRootViewController() -> UIViewController {
        return MobHostingController(rootView: MobRootView())
    }
}

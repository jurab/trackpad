import UIKit
import SwiftUI
import Combine

// Shared lock state — observed by both SwiftUI views and the hosting controller
class LockState: ObservableObject {
    static let shared = LockState()
    @Published var isLocked = false
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Wrap the hosting controller in a container that controls edge gestures
        let hostingVC = UIHostingController(rootView: TrackpadView())
        hostingVC.view.backgroundColor = UIColor(white: 0.08, alpha: 1)

        let container = EdgeLockContainerController()
        container.addChild(hostingVC)
        container.view.addSubview(hostingVC.view)
        hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingVC.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            hostingVC.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            hostingVC.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            hostingVC.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        ])
        hostingVC.didMove(toParent: container)

        window = UIWindow()
        window?.rootViewController = container
        window?.makeKeyAndVisible()
        application.isIdleTimerDisabled = true
        return true
    }
}

// Plain UIViewController as root — UIHostingController can't override edge deferring reliably
class EdgeLockContainerController: UIViewController {
    private var cancellable: AnyCancellable?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)

        cancellable = LockState.shared.$isLocked.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
                self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        LockState.shared.isLocked ? .all : []
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        LockState.shared.isLocked
    }

    override var prefersStatusBarHidden: Bool { true }

    // Tell the system THIS controller handles edge deferring, not a child
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }
    override var childForStatusBarHidden: UIViewController? { nil }
}

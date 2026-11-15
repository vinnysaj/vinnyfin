#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// The full-screen player's view controller on iPhone and iPad. It's presented from UIKit rather
/// than as SwiftUI's full-screen cover so that it can lock the scene's orientation: an iPhone Duo
/// unfolded turns its windows with the device, whatever orientations the app allows, and refuses
/// requests to turn them, but keeps a locked scene still (`PlayerRotation`).
final class PlayerViewController: UIHostingController<AnyView> {
    /// The scene keeps the orientation it's in.
    var locksOrientation = false {
        didSet {
            guard locksOrientation != oldValue else { return }
            setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        }
    }

    let modelID: PlayerModel.ID

    init(modelID: PlayerModel.ID, content: AnyView) {
        self.modelID = modelID
        super.init(rootView: content)
        modalPresentationStyle = .fullScreen
        // Dark from the start, its glass and the popovers it presents too, as the picture is.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersInterfaceOrientationLocked: Bool { locksOrientation }
}

/// Presents the player in a `PlayerViewController` while the coordinator has a model for it
/// (`PlayerCoordinator.coverModel`), over whatever else is presented, and takes it away once it
/// hasn't, as a full-screen cover would.
struct PlayerPresenter<Content: View>: UIViewControllerRepresentable {
    let coordinator: PlayerCoordinator
    @ViewBuilder let content: (PlayerModel) -> Content

    func makeUIViewController(context: Context) -> Presenting {
        Presenting(coordinator: coordinator)
    }

    func updateUIViewController(_ presenting: Presenting, context: Context) {
        presenting.content = { AnyView(content($0)) }
        presenting.sync()
    }

    /// Follows the coordinator itself rather than waiting on SwiftUI's updates, which the views
    /// under a full-screen presentation, out of the window, may not get until it's gone.
    final class Presenting: UIViewController {
        let coordinator: PlayerCoordinator
        var content: ((PlayerModel) -> AnyView)?
        /// Where it presents from, kept while the presentation takes this view out of it.
        private weak var window: UIWindow?
        private var isFollowing = false
        /// The player that should be on screen.
        private var wanted: PlayerViewController?
        /// The player that is, or is on its way.
        private var shown: PlayerViewController?

        init(coordinator: PlayerCoordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            window = view.window
            follow()
            sync()
        }

        private func follow() {
            guard !isFollowing else { return }
            isFollowing = true
            withObservationTracking {
                _ = coordinator.coverModel
            } onChange: { [weak self] in
                Task { @MainActor in
                    self?.isFollowing = false
                    self?.follow()
                    self?.sync()
                }
            }
        }

        func sync() {
            if let model = coordinator.coverModel, let content {
                if let wanted, wanted.modelID == model.id {
                    // The same playback: its view updates in place.
                    wanted.rootView = content(model)
                } else {
                    wanted = PlayerViewController(modelID: model.id, content: content(model))
                }
            } else {
                wanted = nil
            }
            settle()
        }

        /// Brings what's on screen to what should be: one presentation or dismissal at a time,
        /// each going on to the next as it ends.
        private func settle() {
            if let shown, shown.presentingViewController == nil, !shown.isBeingPresented {
                self.shown = nil
            }
            guard shown !== wanted else { return }
            if let shown {
                guard !shown.isBeingPresented, !shown.isBeingDismissed, let below = shown.presentingViewController else { return }
                // From below, so a sheet or popover the player has up goes with it.
                below.dismiss(animated: true) { [weak self] in
                    self?.shown = nil
                    self?.settle()
                }
                return
            }
            guard let wanted, let root = window?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
            shown = wanted
            top.present(wanted, animated: true) { [weak self] in self?.settle() }
        }
    }
}
#endif

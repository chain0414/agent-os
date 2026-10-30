import SwiftUI
import UIKit

/// The plate lives below the native navigation bar and above the transcript.
/// Its gradient also covers the status bar; changing opacity never changes the
/// scroll view's safe area, content insets or reading position.
struct ChatTitleBackdrop: UIViewControllerRepresentable {
    let visibility: ChatTitleVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIViewController(context: Context) -> ChatTitleBackdropController { ChatTitleBackdropController() }
    func updateUIViewController(_ controller: ChatTitleBackdropController, context: Context) {
        controller.update(visible: visibility.isVisible, animated: !reduceMotion, opaque: reduceTransparency)
    }
    static func dismantleUIViewController(_ controller: ChatTitleBackdropController, coordinator: ()) { controller.detach() }
}

final class ChatTitleBackdropController: UIViewController {
    private let titlePlate = ChatTitlePlate()
    private let statusPlate = ChatTitlePlate()
    private var visible = true
    private var opaque = false
    private var stopped = false
    private var registrationScheduled = false
    private weak var registeredParent: UIView?

    override func loadView() {
        view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false
    }
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { removePlates() } else { scheduleRegistration() }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); scheduleRegistration() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); register() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); removePlates() }

    func update(visible: Bool, animated: Bool, opaque: Bool) {
        let changed = self.visible != visible
        self.visible = visible; self.opaque = opaque
        titlePlate.configure(opaque: opaque); statusPlate.configure(opaque: opaque)
        if changed && titlePlate.superview != nil {
            UIView.animate(withDuration: animated ? ChatTitleTransition.duration : 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
                self.titlePlate.alpha = visible ? 1 : 0
            }
        } else { titlePlate.alpha = visible ? 1 : 0 }
        scheduleRegistration()
    }
    func detach() { stopped = true; removePlates() }
    private func removePlates() {
        titlePlate.removeFromSuperview(); statusPlate.removeFromSuperview(); registeredParent = nil
    }
    private func scheduleRegistration() {
        guard !stopped, !registrationScheduled else { return }
        registrationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.registrationScheduled = false; self.register()
        }
    }
    private func register() {
        guard !stopped, isViewLoaded, view.window != nil, let navigation = navigationController,
              let host = navigation.navigationBar.superview else { return }
        // Background representables from an outgoing page must yield to the
        // navigation controller's current page rather than cover the next one.
        var ancestor = parent
        var ownsPage = false
        while let candidate = ancestor {
            if candidate === navigation.topViewController { ownsPage = true; break }
            ancestor = candidate.parent
        }
        guard ownsPage else { removePlates(); return }
        if registeredParent !== host {
            removePlates(); registeredParent = host
            host.insertSubview(titlePlate, belowSubview: navigation.navigationBar)
            host.insertSubview(statusPlate, belowSubview: navigation.navigationBar)
            titlePlate.alpha = visible ? 1 : 0
        }
        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: host)
        let top = min(0, view.window.map { host.convert(CGPoint.zero, from: $0).y } ?? 0)
        let titleFrame = CGRect(x: 0, y: top, width: host.bounds.width, height: max(0, bar.maxY - top) + 36)
        let statusFrame = CGRect(x: 0, y: top, width: host.bounds.width, height: max(0, bar.minY - top) + 10)
        if titlePlate.frame != titleFrame { titlePlate.frame = titleFrame }
        if statusPlate.frame != statusFrame { statusPlate.frame = statusFrame }
        titlePlate.solidThrough = max(0, bar.maxY - top)
        statusPlate.solidThrough = max(0, bar.minY - top - 2)
        titlePlate.configure(opaque: opaque); statusPlate.configure(opaque: opaque)
    }
}

private final class ChatTitlePlate: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let tint = UIView()
    private let gradient = CAGradientLayer()
    private var currentOpaque: Bool?
    var solidThrough: CGFloat = 0 { didSet { if oldValue != solidThrough { setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
        addSubview(blur); addSubview(tint); layer.mask = gradient
        gradient.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(opaque: Bool) {
        guard currentOpaque != opaque else { return }
        currentOpaque = opaque
        blur.isHidden = opaque
        tint.backgroundColor = UIColor.systemBackground.withAlphaComponent(opaque ? 1 : 0.72)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds; tint.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        gradient.locations = [0, NSNumber(value: Double(min(0.99, solidThrough / max(1, bounds.height)))), 1]
        CATransaction.commit()
    }
}

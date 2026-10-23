// Vita3K iOS shell app
// Step 6: fullscreen UIKit surface hosting the Vulkan/MoltenVK scene.
// Step 7: the same surface hosts the production app session
// (AppSessionController) when `appPath` is set.
//
// All UIKit work happens on the main thread; the core renders on its own
// thread and only reads the lock-free frame host state. The CAMetalLayer is
// delivered to the core through the frame-host channel before the session
// starts. Losing focus suspends CPU/audio and drains GPU submissions while
// retaining the session; only an explicit exit tears it down.

import Combine
import SwiftUI
import UIKit
import Vita3KCore

/// UIKit-owned CAMetalLayer surface. The layer is handed to the core as an
/// opaque pointer; its pixel drawable size is the extent the swapchain is
/// built from.
final class MetalSurfaceView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    /// Last pixel size fed to the core (0/0 until the first layout).
    private(set) var drawableWidth = 0
    private(set) var drawableHeight = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        // MoltenVK manages the layer's drawables through the
        // VK_EXT_metal_surface; it owns presentation on its own Metal queue.
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = false
        metalLayer.backgroundColor = UIColor.black.cgColor
        // Step 9: multitouch capture (front touchscreen).
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = L10n.text("Tela do jogo")
        accessibilityIdentifier = "game-surface"
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: MetalSurfaceView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    // Step 9: front-touch capture. Pixel coordinates of this surface are
    // passed to the core, which maps them through the renderer's letterbox
    // viewport to 960x544 content coordinates. A cancelled touch is
    // delivered as "up" so no finger can stick in the core's state.
    private var fingerIDs: [ObjectIdentifier: Int32] = [:]
    private var nextFingerID: Int32 = 1

    private func fingerID(for touch: UITouch) -> Int32 {
        let key = ObjectIdentifier(touch)
        if let id = fingerIDs[key] { return id }
        let id = nextFingerID
        nextFingerID += 1
        fingerIDs[key] = id
        return id
    }

    private func dropFinger(_ touch: UITouch) {
        fingerIDs[ObjectIdentifier(touch)] = nil
    }

    private func touchPixels(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let scale = contentScaleFactor
        return (Int32((p.x * scale).rounded()), Int32((p.y * scale).rounded()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 0, fingerID: fingerID(for: touch), px: x, py: y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 1, fingerID: fingerID(for: touch), px: x, py: y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 2, fingerID: fingerID(for: touch), px: x, py: y)
            dropFinger(touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            Vita3KCore.inputTouchEvent(event: 2, fingerID: fingerID(for: touch), px: x, py: y)
            dropFinger(touch)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // This is the view's backing layer, not a sublayer. UIKit owns its
        // frame; assigning bounds here would reset the view's origin to zero
        // and render under the toolbar after portrait/landscape relayout.
        applyDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDrawableSize()
    }

    /// drawableSize is in PIXELS (contentScale included). UIKit main thread
    /// only: the render thread never touches the layer, it reads the size
    /// the core stores lock-free.
    func applyDrawableSize() {
        // A UIView backed by CAMetalLayer can keep the default 1 pixel per
        // point even on a Retina screen. Present at the screen's pixel
        // density so internal upscaling is not lost in a low-res drawable.
        // Touch input uses this same contentScaleFactor above.
        let scale = max(1, window?.screen.nativeScale ?? traitCollection.displayScale)
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
        let w = max(1, Int((bounds.width * scale).rounded()))
        let h = max(1, Int((bounds.height * scale).rounded()))
        if w != drawableWidth || h != drawableHeight {
            metalLayer.drawableSize = CGSize(width: w, height: h)
            drawableWidth = w
            drawableHeight = h
            Probe.mark("game-surface points=\(bounds.width)x\(bounds.height) scale=\(scale) drawable=\(w)x\(h)")
        }
        Vita3KCore.frameHostSetSize(width: Int32(w), height: Int32(h))
    }

    /// Opaque pointer to the layer for the C bridge.
    var layerPointer: UnsafeMutableRawPointer {
        unsafeBitCast(metalLayer, to: UnsafeMutableRawPointer.self)
    }
}

final class EmulationViewController: UIViewController {
    private let onExit: () -> Void

    /// nil = step 6 Vulkan/MoltenVK demo; otherwise a title id to boot (step 7).
    private let appPath: String?

    private let surfaceView = MetalSurfaceView()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let performanceOverlay = PerformanceOverlayView()
    private var frameSampler = GuestFrameSampler()
    // Fullscreen play: no top bar. The HOME button (top center, visible
    // while a session is active) pauses the game and offers "Continuar" /
    // "Voltar à biblioteca" — the only way back to the library.
    private let homeButton = UIButton(configuration: .plain())
    /// Invisible area over the HOME button: while the button is hidden
    /// (in-game setting), a double tap here brings it back.
    private let homeHotspot = UIView()
    /// Set by the double tap: the button stays visible until the game is resumed, then hides again.
    private var homeShownTemporarily = false
    private let homeMenu = UIView()
    private let homeResume = UIButton(configuration: .borderedProminent())
    private let homeSettings = UIButton(configuration: .bordered())
    private let homeExit = UIButton(configuration: .bordered())
    private let homeTitle = UILabel()
    private var userPaused = false
    // Physical gamepad: Start + Select opens the menu; the D-pad / A / B drive it.
    private var padCancellables = Set<AnyCancellable>()
    private var homeFocusIndex = 0
    private var padHintShown = false
    private var jitWarningShown = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        AppOrientation.supportedOrientations
    }
    override var shouldAutorotate: Bool { true }

    /// Fullscreen while playing: hide the status bar on the game surface.
    override var prefersStatusBarHidden: Bool {
        isSessionMode
    }

    // Both sceImeOpen and sceImeDialogInit use the native iPhone keyboard.
    private let imeBar = GameKeyboardView()
    private var imeVisible = false
    private var dismissedImeRequest: UInt64?

    // Step 9: on-screen (virtual) gamepad. Shown while a session is
    // running and no physical gamepad is attached; it writes SCE_CTRL
    // button masks and -1..1 analogs into the core (blended with any
    // physical pad) so touch-only play works without external hardware.
    private let vpad = VirtualGamepadView()
    private var vpadVisible = false

    /// Debug: cap the number of vpad-check probe markers per VC instance.
    private var vpadDebug = 0

    /// Debug hook: force the on-screen pad even with a (phantom) physical
    /// pad detected — the simulator sees the Mac's host controllers. Set
    /// via the VITA3K_FORCE_VPAD env var or a force-vpad.txt marker in
    /// Documents.
    static func forceVpadEnabled() -> Bool {
        if ProcessInfo.processInfo.environment["VITA3K_FORCE_VPAD"] == "1" {
            return true
        }
        return FileManager.default.fileExists(atPath: Self.basePath + "/force-vpad.txt")
    }

    private var pollTask: Task<Void, Never>?
    private var jitKeepaliveTick = 0
    private var startInFlight = false
    private var userExited = false
    private var appSuspended = false
    private var appResigningObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

    /// Both flavors now link MoltenVK (device slice from the XCFramework,
    /// simulator slice built from source), so the core always has a Vulkan
    /// driver available on this surface.
    private var hasMoltenVK: Bool { true }

    init(appPath: String?, onExit: @escaping () -> Void) {
        self.appPath = appPath
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root

        surfaceView.frame = root.bounds
        root.addSubview(surfaceView)

        // Fullscreen: no top bar. HOME (top center) pauses the game and
        // shows a small menu with "Continuar" / "Voltar à biblioteca".
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.backgroundColor = .black.withAlphaComponent(0.5)
        homeButton.layer.cornerRadius = 22
        homeButton.configuration?.image = UIImage(systemName: "house.fill",
                                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        homeButton.tintColor = .white
        homeButton.accessibilityLabel = L10n.text("Home")
        homeButton.accessibilityIdentifier = "home-button"
        homeButton.isHidden = true
        homeButton.addAction(UIAction { [weak self] _ in self?.homeTapped() }, for: .touchUpInside)

        homeMenu.translatesAutoresizingMaskIntoConstraints = false
        homeMenu.backgroundColor = .black.withAlphaComponent(0.78)
        homeMenu.layer.cornerRadius = 18
        homeMenu.isHidden = true
        homeTitle.text = L10n.text("Pausado")
        homeTitle.translatesAutoresizingMaskIntoConstraints = false
        homeTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        homeTitle.textColor = .white
        homeTitle.textAlignment = .center
        homeResume.configuration?.title = L10n.text("Continuar")
        homeResume.configuration?.baseForegroundColor = .white
        homeResume.translatesAutoresizingMaskIntoConstraints = false
        homeResume.accessibilityIdentifier = "resume-game"
        homeResume.addAction(UIAction { [weak self] _ in self?.resumeGame() }, for: .touchUpInside)
        homeSettings.configuration?.title = L10n.text("Configurações")
        homeSettings.configuration?.baseForegroundColor = .white
        homeSettings.translatesAutoresizingMaskIntoConstraints = false
        homeSettings.accessibilityIdentifier = "ingame-settings"
        homeSettings.addAction(UIAction { [weak self] _ in self?.openInGameSettings() }, for: .touchUpInside)
        homeExit.configuration?.title = L10n.text("Voltar à biblioteca")
        homeExit.configuration?.baseForegroundColor = .white
        homeExit.translatesAutoresizingMaskIntoConstraints = false
        homeExit.accessibilityIdentifier = "exit-game"
        homeExit.addAction(UIAction { [weak self] _ in self?.exit() }, for: .touchUpInside)
        homeMenu.addSubview(homeTitle)
        homeMenu.addSubview(homeResume)
        homeMenu.addSubview(homeSettings)
        homeMenu.addSubview(homeExit)

        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 2
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .white.withAlphaComponent(0.85)
        detailLabel.numberOfLines = 3

        let bottom = UIStackView()
        bottom.addArrangedSubview(statusLabel)
        bottom.addArrangedSubview(detailLabel)
        bottom.axis = .vertical
        bottom.alignment = .leading
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.backgroundColor = .black.withAlphaComponent(0.55)

        // Step 9: IME software keyboard (session mode only).
        imeBar.translatesAutoresizingMaskIntoConstraints = false
        imeBar.isHidden = true
        imeBar.onEdit = { id, text, caret in Vita3KCore.imeReplace(id: id, text: text, caret: caret) }
        imeBar.onFinish = { [weak self] id, cancel in
            guard Vita3KCore.imeFinish(id: id, cancel: cancel) else { return false }
            self?.dismissedImeRequest = id
            self?.imeHide()
            return true
        }

        root.addSubview(homeButton)
        root.addSubview(bottom)
        root.addSubview(imeBar)
        root.addSubview(homeMenu)
        // On-screen gamepad fills the screen; its widgets are anchored to
        // the bottom. It sits above the surface but below the IME bar.
        vpad.frame = root.bounds
        vpad.alpha = UserDefaults.standard.object(forKey: "emulation.controlOpacity") as? Double ?? 0.8
        homeButton.alpha = vpad.alpha
        root.addSubview(vpad)
        performanceOverlay.translatesAutoresizingMaskIntoConstraints = false
        performanceOverlay.isHidden = true
        root.addSubview(performanceOverlay)
        homeHotspot.translatesAutoresizingMaskIntoConstraints = false
        homeHotspot.backgroundColor = .clear
        homeHotspot.isHidden = true
        homeHotspot.accessibilityIdentifier = "home-hotspot"
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(homeHotspotDoubleTapped))
        doubleTap.numberOfTapsRequired = 2
        homeHotspot.addGestureRecognizer(doubleTap)
        root.addSubview(homeHotspot)
        root.bringSubviewToFront(homeButton)
        root.bringSubviewToFront(homeHotspot)
        root.bringSubviewToFront(imeBar)
        root.bringSubviewToFront(homeMenu)

        NSLayoutConstraint.activate([
            performanceOverlay.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            performanceOverlay.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            performanceOverlay.trailingAnchor.constraint(lessThanOrEqualTo: homeButton.leadingAnchor, constant: -8),

            homeButton.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            homeButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            homeHotspot.centerXAnchor.constraint(equalTo: homeButton.centerXAnchor),
            homeHotspot.centerYAnchor.constraint(equalTo: homeButton.centerYAnchor),
            homeHotspot.widthAnchor.constraint(equalToConstant: 72),
            homeHotspot.heightAnchor.constraint(equalToConstant: 72),
            homeButton.widthAnchor.constraint(equalToConstant: 44),
            homeButton.heightAnchor.constraint(equalToConstant: 44),

            homeMenu.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            homeMenu.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            homeMenu.widthAnchor.constraint(equalToConstant: 300),
            homeMenu.heightAnchor.constraint(equalToConstant: 206),
            homeTitle.topAnchor.constraint(equalTo: homeMenu.topAnchor, constant: 16),
            homeTitle.centerXAnchor.constraint(equalTo: homeMenu.centerXAnchor),
            homeResume.topAnchor.constraint(equalTo: homeTitle.bottomAnchor, constant: 12),
            homeResume.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeResume.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeResume.heightAnchor.constraint(equalToConstant: 40),
            homeSettings.topAnchor.constraint(equalTo: homeResume.bottomAnchor, constant: 10),
            homeSettings.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeSettings.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeSettings.heightAnchor.constraint(equalToConstant: 40),
            homeExit.topAnchor.constraint(equalTo: homeSettings.bottomAnchor, constant: 10),
            homeExit.leadingAnchor.constraint(equalTo: homeMenu.leadingAnchor, constant: 16),
            homeExit.trailingAnchor.constraint(equalTo: homeMenu.trailingAnchor, constant: -16),
            homeExit.heightAnchor.constraint(equalToConstant: 40),

            bottom.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor),

            imeBar.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor),
            imeBar.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor),
            imeBar.bottomAnchor.constraint(equalTo: root.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fullscreen: the surface fills the safe area (no top bar). In
        // portrait the game sits on top and the on-screen pad below it.
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let content = safe
        let portrait = view.bounds.height > view.bounds.width
        if portrait && isSessionMode && vpadVisible {
            let screenHeight = min(content.width * 544 / 960, content.height * 0.48)
            surfaceView.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: screenHeight)
            vpad.frame = CGRect(x: content.minX, y: surfaceView.frame.maxY + 8,
                                width: content.width, height: max(1, content.maxY - surfaceView.frame.maxY - 8))
        } else {
            surfaceView.frame = content
            vpad.frame = content.insetBy(dx: 8, dy: 4)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Do not carry held fingers/buttons into a different coordinate space.
        Vita3KCore.inputClear()
        vpad.resetInput()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout(); self.view.layoutIfNeeded() })
    }

    /// Shows the HOME button, or (when hidden in the in-game settings) only its
    /// invisible double-tap area.
    private func applyHomeVisibility(active: Bool) {
        let hide = UserDefaults.standard.bool(forKey: "emulation.hideHome") && !homeShownTemporarily
        homeButton.isHidden = !active || hide
        homeHotspot.isHidden = !active || !hide
    }

    @objc private func homeHotspotDoubleTapped() {
        homeShownTemporarily = true
        applyHomeVisibility(active: Vita3KCore.sessionIsActive())
    }

    /// HOME (the only in-game control): pause the game and show the
    /// "Continuar" / "Voltar à biblioteca" menu. A second tap just hides
    /// the menu (the game stays paused).
    private func homeTapped() {
        guard isSessionMode, Vita3KCore.sessionIsActive() else { return }
        if !homeMenu.isHidden {
            homeMenu.isHidden = true
            return
        }
        if !userPaused {
            guard vita3k_ios_session_set_pause(1, 1) == 0 else { return }
            userPaused = true
            frameSampler.reset()
        }
        homeMenu.isHidden = false
        UISounds.shared.play(.open)
        view.bringSubviewToFront(homeMenu)
        setHomeFocus(0)
    }

    // MARK: - Gamepad

    private var homeButtons: [UIButton] { [homeResume, homeSettings, homeExit] }

    private func setHomeFocus(_ index: Int) {
        homeFocusIndex = min(max(index, 0), homeButtons.count - 1)
        let showRing = GamepadInput.shared.connected
        for (i, button) in homeButtons.enumerated() {
            button.layer.cornerRadius = 20
            button.layer.borderColor = UIColor.white.cgColor
            button.layer.borderWidth = (showRing && i == homeFocusIndex) ? 2 : 0
        }
    }

    private func startGamepad() {
        padCancellables.removeAll()
        GamepadInput.shared.start(owner: ObjectIdentifier(self))
        GamepadInput.shared.$lastEvent
            .compactMap { $0 }
            .sink { [weak self] event in MainActor.assumeIsolated { self?.handlePad(event.button) } }
            .store(in: &padCancellables)
        GamepadInput.shared.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                if connected { MainActor.assumeIsolated { self?.maybeShowPadHint() } }
            }
            .store(in: &padCancellables)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.maybeShowPadHint() }
        }
    }

    private func stopGamepad() {
        padCancellables.removeAll()
        GamepadInput.shared.stop(owner: ObjectIdentifier(self))
    }

    private func handlePad(_ button: PadButton) {
        guard isSessionMode, Vita3KCore.sessionIsActive() else { return }
        if presentedViewController != nil {
            // The in-game settings sheet: B closes it.
            if button == .back { dismiss(animated: true) }
            return
        }
        if homeMenu.isHidden {
            if button == .menuCombo {
                UserDefaults.standard.set(true, forKey: "emulation.menuComboUsed")
                homeTapped()
            }
            return
        }
        switch button {
        case .up:
            UISounds.shared.play(.move)
            setHomeFocus(homeFocusIndex - 1)
        case .down:
            UISounds.shared.play(.move)
            setHomeFocus(homeFocusIndex + 1)
        case .confirm: homeButtons[homeFocusIndex].sendActions(for: .touchUpInside)
        case .back, .start: resumeGame()
        default: break
        }
    }

    /// Tells the player how to open the menu (until they have used it, and at
    /// most a few times), shown once per play session when a controller is attached.
    private func maybeShowPadHint() {
        guard isSessionMode, !padHintShown, !userExited, GamepadInput.shared.connected,
              Vita3KCore.sessionIsActive(), homeMenu.isHidden else { return }
        let defaults = UserDefaults.standard
        let shown = defaults.integer(forKey: "emulation.menuHintCount")
        guard !defaults.bool(forKey: "emulation.menuComboUsed"), shown < 6 else { return }
        padHintShown = true
        defaults.set(shown + 1, forKey: "emulation.menuHintCount")

        let label = UILabel()
        label.text = L10n.text("Pressione Start + Select para abrir o menu")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        let toast = UIView()
        toast.backgroundColor = .black.withAlphaComponent(0.8)
        toast.layer.cornerRadius = 16
        toast.layer.borderWidth = 1
        toast.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        toast.alpha = 0
        toast.isUserInteractionEnabled = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(label)
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16),
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        UIView.animate(withDuration: 0.3) { toast.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 5, options: []) {
            toast.alpha = 0
        } completion: { _ in toast.removeFromSuperview() }
    }

    /// Settings sheet over the paused game (the game stays paused until Resume).
    private func openInGameSettings() {
        guard let appPath, presentedViewController == nil else { return }
        let host = UIHostingController(rootView: InGameSettingsView(titleId: appPath, onDone: { [weak self] in
            self?.dismiss(animated: true)
        }, onRestart: { [weak self] in
            self?.dismiss(animated: true) { self?.restartGame() }
        }))
        present(host, animated: true)
    }

    /// Stops the running session and starts it again (used to apply settings
    /// that only take effect at launch, such as the resolution).
    private func restartGame() {
        guard isSessionMode, !userExited, Vita3KCore.sessionIsActive() else { return }
        imeHide()
        dismissedImeRequest = nil
        performanceOverlay.isHidden = true
        frameSampler.reset()
        pollTask?.cancel()
        pollTask = nil
        setVpadVisible(false)
        homeMenu.isHidden = true
        userPaused = false
        statusLabel.isHidden = false
        statusLabel.text = L10n.text("inicializando sessão…")
        homeShownTemporarily = false
        Task.detached(priority: .userInitiated) {
            // stop() joins the session thread and tears down cleanly.
            _ = Vita3KCore.sessionStop()
            await MainActor.run { [weak self] in self?.startDemo() }
        }
    }

    private func resumeGame() {
        guard vita3k_ios_session_set_pause(1, 0) == 0 else { return }
        userPaused = false
        homeMenu.isHidden = true
        UISounds.shared.play(.back)
        frameSampler.reset()
        // Back in the game: hide the HOME button again if the setting is on.
        homeShownTemporarily = false
        applyHomeVisibility(active: Vita3KCore.sessionIsActive())
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        // App lifecycle is delivered as notifications to the VC (the
        // willResignActive/didBecomeActive responder methods are not reliably
        // invoked on a presented view controller).
        appResigningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspendForBackground()
                }
            }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.userExited, self.viewIfLoaded?.window != nil else { return }
                    self.resumeFromBackground()
                }
            }
        startGamepad()
        if UIApplication.shared.applicationState == .active {
            vita3k_ios_session_set_background(0)
            startDemo()
        } else {
            suspendForBackground()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        userExited = true
        if let o = appResigningObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appActiveObserver { NotificationCenter.default.removeObserver(o) }
        appResigningObserver = nil
        appActiveObserver = nil
        imeHide()
        stopGamepad()
        vpad.setActive(false)
        // No stuck input may survive the surface's death: lift all fingers
        // and drop the overlay mouse in the core.
        Vita3KCore.inputClear()
        stopDemo()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Session

    private func exit() {
        userExited = true
        stopDemo()
        onExit()
    }

    private var isSessionMode: Bool { appPath != nil }

    private func suspendForBackground() {
        guard !userExited, !appSuspended else { return }
        appSuspended = true
        pollTask?.cancel()
        pollTask = nil
        frameSampler.reset()
        vpad.resetInput()
        Vita3KCore.inputClear()
        // Do not dismiss the IME request or clear its text/selection. UIKit
        // retains the editing view across application activation changes.
        vita3k_ios_session_set_background(1)
        Probe.mark("lifecycle suspended " + Vita3KCore.sessionReport())
    }

    private func resumeFromBackground() {
        guard appSuspended, !userExited else { return }
        if isSessionMode, Vita3KCore.jitValidateAlive() != 0 {
            showJITUnavailable()
            return
        }
        appSuspended = false
        view.layoutIfNeeded()
        surfaceView.applyDrawableSize()
        vita3k_ios_session_set_background(0)
        Probe.mark("lifecycle resumed " + Vita3KCore.sessionReport())
        // Starting is also a live session: never submit a second launch.
        if startInFlight || (isSessionMode ? Vita3KCore.sessionPhase() != 0 : Vita3KCore.vulkanDemoIsRunning()) {
            startPolling()
            if imeVisible { imeBar.textView.becomeFirstResponder() }
        } else {
            startDemo()
        }
    }

    private func showJITUnavailable() {
        statusLabel.isHidden = false
        statusLabel.text = L10n.text("JIT indisponível — reabra pelo StikDebug.")
        // Keep the guest suspended until the user exits. Do not run cached
        // JIT code after the grant has been revoked, or auto-launch a new game.
        suspendForBackground()
        guard !jitWarningShown else { return }
        jitWarningShown = true
        let alert = UIAlertController(title: L10n.text("Abra pelo StikDebug"), message: L10n.text("O JIT não está mais disponível. Inicie o Veeb pelo StikDebug usando Universal."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.text("Voltar à biblioteca"), style: .default) { [weak self] _ in self?.exit() })
        present(alert, animated: true)
    }

    private func startDemo() {
        guard !userExited, !appSuspended, !startInFlight else { return }
        guard !isSessionMode || Vita3KCore.jitValidateAlive() == 0 else {
            statusLabel.text = L10n.text("JIT indisponível. Abra o Veeb pelo StikDebug com Universal.")
            return
        }
        view.layoutIfNeeded()
        if !isSessionMode {
            guard !Vita3KCore.vulkanDemoIsRunning() else { return }
        }
        startInFlight = true
        Probe.mark("startDemo mode=\(isSessionMode ? "game" : "demo") appPath=\(appPath ?? "nil")")
        statusLabel.text = isSessionMode ? L10n.text("inicializando sessão…") : L10n.text("inicializando Vulkan/MoltenVK…")
        detailLabel.text = ""

        let basePath = Self.basePath
        let staticAssets = Bundle.main.bundlePath
        let width = surfaceView.drawableWidth
        let height = surfaceView.drawableHeight
        let moltenvk: Int32 = hasMoltenVK ? 1 : 0

        if isSessionMode {
            // A previously exited session may still be tearing down: wait, bounded,
            // for it to become idle before delivering the layer and spawning
            // the new session on the main thread.
            Task { @MainActor [weak self] in
                let deadline = Date().addingTimeInterval(30)
                while Vita3KCore.sessionIsActive(), Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard let self, !self.userExited, !self.appSuspended else {
                    self?.startInFlight = false
                    return
                }
                guard !Vita3KCore.sessionIsActive() else {
                    self.startInFlight = false
                    self.statusLabel.text = L10n.text("sessão anterior não encerrou")
                    return
                }
                // The CAMetalLayer is UIKit (main-thread) owned: deliver it to
                // the core on the main thread, through the frame-host channel,
                // before the session is spawned. The heavy work (renderer
                // init, 4 GiB reservation, app load) runs on the core's thread.
                Vita3KCore.frameHostSetLayer(self.surfaceView.layerPointer)
                Vita3KCore.frameHostSetSize(width: Int32(width), height: Int32(height))
                guard let appPath else {
                    self.startInFlight = false
                    self.statusLabel.text = L10n.text("sem título para a sessão")
                    return
                }
                // Step 7: the C facade spawns the launch worker itself.
                let rc = Vita3KCore.sessionLaunch(appPath: appPath, width: Int32(width), height: Int32(height))
                self.startInFlight = false
                if rc == 0 {
                    self.statusLabel.text = L10n.format("iniciando %@…", appPath)
                    self.startPolling()
                } else {
                    self.statusLabel.text = L10n.format("launch falhou (rc=%d)", rc)
                    self.detailLabel.text = Vita3KCore.sessionReport()
                }
            }
            return
        }

        // The CAMetalLayer is UIKit (main-thread) owned: deliver it to the
        // core on the main thread, through the frame-host channel, before
        // the demo is spawned (the session path does its own delivery after
        // waiting for a previous session to stop).
        Vita3KCore.frameHostSetLayer(surfaceView.layerPointer)
        Vita3KCore.frameHostSetSize(width: Int32(width), height: Int32(height))

        Task.detached(priority: .userInitiated) { [weak self] in
            // renderer::init creates the instance/device/swapchain and
            // compiles the screen filter pipeline (SPIR-V -> MSL): this can
            // take a couple of seconds, so it must not block the UI.
            let (rc, report) = Vita3KCore.startVulkanDemo(
                basePath: basePath, staticAssets: staticAssets,
                hasMoltenVK: moltenvk, width: Int32(width), height: Int32(height))

            await MainActor.run {
                guard let self else { return }
                self.startInFlight = false
                if rc == 0 {
                    self.show(report: report)
                    self.startPolling()
                } else {
                    self.statusLabel.text = L10n.format("demo indisponível (rc=%d)", rc)
                    self.detailLabel.text = report
                }
            }
        }
    }

    private func stopDemo() {
        imeHide()
        dismissedImeRequest = nil
        performanceOverlay.isHidden = true
        frameSampler.reset()
        pollTask?.cancel()
        pollTask = nil
        // Runtime teardown clears the core's pad state and its visibility.
        setVpadVisible(false)
        homeMenu.isHidden = true
        userPaused = false

        if isSessionMode {
            guard Vita3KCore.sessionIsActive() else { return }
            Task.detached(priority: .userInitiated) {
                // stop() joins the session thread and tears down cleanly.
                _ = Vita3KCore.sessionStop()
                await MainActor.run {
                    self.statusLabel.text = L10n.text("sessão parada")
                }
            }
            return
        }

        guard Vita3KCore.vulkanDemoIsRunning() else { return }
        Task.detached(priority: .userInitiated) {
            // stop joins the render thread and waits the GPU idle.
            _ = Vita3KCore.stopVulkanDemo()
            await MainActor.run {
                self.statusLabel.text = L10n.text("demo parado")
            }
        }
    }

    private func startPolling() {
        guard !appSuspended, !userExited else { return }
        pollTask?.cancel()
        frameSampler.reset()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await MainActor.run {
                    if self.isSessionMode {
                        let phase = Vita3KCore.sessionPhase()
                        if ProcessInfo.processInfo.environment["VITA3K_UI_TEST"] == "1" {
                            // Read-only continuity evidence for lifecycle UI tests.
                            self.surfaceView.accessibilityValue = Vita3KCore.sessionReport()
                                .components(separatedBy: "\n")
                                .filter { $0.hasPrefix("lifecycle:") || $0.hasPrefix("paused:") }
                                .joined(separator: " ")
                        }
                        let showStatus = UserDefaults.standard.bool(forKey: "emulation.showStatus")
                        self.statusLabel.text = phase == 4 ? L10n.text("Falha ao iniciar o jogo. Consulte o diagnóstico.") : (self.userPaused ? L10n.text("Pausado") : L10n.text("Em execução"))
                        self.statusLabel.isHidden = phase == 2 && !self.userPaused
                        self.detailLabel.text = ""
                        self.performanceOverlay.isHidden = phase != 2 || !showStatus
                        if !self.performanceOverlay.isHidden {
                            let paused = Vita3KCore.sessionIsPaused()
                            let frames = self.frameSampler.sample(frames: Vita3KCore.sessionFrameCount(),
                                                                  time: ProcessInfo.processInfo.systemUptime,
                                                                  paused: paused)
                            self.performanceOverlay.update(frames: frames,
                                                           memory: PerformanceMemory.read(device: self.surfaceView.metalLayer.device),
                                                           paused: paused)
                        } else {
                            self.frameSampler.reset()
                        }
                        if phase == 4 {
                            let report = Vita3KCore.sessionReport()
                            self.detailLabel.text = report.components(separatedBy: "\n").first(where: { $0.hasPrefix("error:") })
                        }
                        // HOME button while a session is active; the pause
                        // menu cannot outlive the session.
                        let active = Vita3KCore.sessionIsActive()
                        self.applyHomeVisibility(active: active)
                        if !active {
                            self.homeMenu.isHidden = true
                            self.userPaused = false
                        }
                        // Step 9: mirror the guest's IME state into the
                        // software keyboard visibility.
                        let request = Vita3KCore.imeSnapshot()
                        if let request, request.id != self.dismissedImeRequest {
                            if !self.imeVisible || self.imeBar.request?.id != request.id {
                                self.imeShow(request)
                            }
                        } else if self.imeVisible {
                            self.imeHide()
                        }
                        // Step 9: on-screen gamepad while a session runs and
                        // no physical pad is attached (the IME bar takes
                        // priority over the pad). VITA3K_FORCE_VPAD=1
                        // (simctl launch --env) overrides the physical-pad
                        // check: the simulator sees the Mac's host
                        // controllers, which would always hide the pad.
                        let forceVpad = Self.forceVpadEnabled()
                        let wantVpad = Vita3KCore.sessionIsActive()
                            && (Vita3KCore.gamepadCount() == 0 || forceVpad)
                            && !self.imeVisible
                            && Self.showControls
                        if wantVpad != self.vpadVisible {
                            self.setVpadVisible(wantVpad)
                        }
                        if self.vpadDebug <= 3 {
                            self.vpadDebug += 1
                            Probe.mark("vpad-check want=\(wantVpad) active=\(Vita3KCore.sessionIsActive()) pads=\(Vita3KCore.gamepadCount()) ime=\(self.imeVisible) visible=\(self.vpadVisible)")
                        }
                        // JIT keep-alive (the ARMSX2 pattern): the StikDebug
                        // session can be revoked after ~30-60 s of
                        // inactivity; probe every ~12 s and surface the
                        // expiry so the user can relaunch via StikDebug.
                        self.jitKeepaliveTick += 1
                        if self.jitKeepaliveTick % 12 == 0, Vita3KCore.jitValidateAlive() != 0 {
                            self.showJITUnavailable()
                            Probe.mark("jit-keepalive: grant revoked")
                        }
                    } else {
                        self.show(report: Vita3KCore.vulkanDemoReport())
                    }
                }
            }
        }
    }

    /// One-line status + the full report, straight from the core (demo mode).
    private func show(report: String) {
        let lines = report.components(separatedBy: "\n")
        var first = lines.first ?? ""
        if lines.contains("running: yes") {
            first = L10n.text("demo ativo")
            if let f = lines.first(where: { $0.hasPrefix("fps:") }),
               let fr = lines.first(where: { $0.hasPrefix("frames:") }) {
                first += "  \(String(fr.split(separator: ":").last ?? ""))  \(String(f.split(separator: ":").last ?? ""))"
            }
        }
        if let gpu = lines.first(where: { $0.hasPrefix("gpu:") }) {
            first += "\n\(gpu)"
        }
        statusLabel.text = first
        detailLabel.text = lines.dropFirst().joined(separator: "\n")
    }

    // MARK: - Step 9: IME software keyboard

    private func imeShow(_ request: GameKeyboardRequest) {
        imeVisible = true
        view.bringSubviewToFront(imeBar)
        imeBar.present(request)
        // The keyboard takes the bottom of the screen: hide the pad.
        if vpadVisible {
            setVpadVisible(false)
        }
    }

    private func imeHide() {
        guard imeVisible else { return }
        imeVisible = false
        imeBar.dismiss()
        // The keyboard was covering the pad: bring the pad back if the
        // session is still running (no physical pad attached).
        let forceVpad = Self.forceVpadEnabled()
        if Vita3KCore.sessionIsActive()
            && (Vita3KCore.gamepadCount() == 0 || forceVpad)
            && Self.showControls
            && !vpadVisible {
            setVpadVisible(true)
        }
    }

    /// Show/hide the on-screen gamepad (also enables/disables it in the
    /// core and clears its state when hiding).
    private func setVpadVisible(_ on: Bool) {
        guard on != vpadVisible else { return }
        vpadVisible = on
        vpad.setActive(on)
        view.setNeedsLayout()
        Probe.mark("vpad \(on ? "shown" : "hidden") (gamepads=\(Vita3KCore.gamepadCount()))")
    }

    static var basePath: String {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        return FileManager.default.currentDirectoryPath
    }

    static var showControls: Bool {
        UserDefaults.standard.object(forKey: "emulation.showControls") as? Bool ?? true
    }
}

// MARK: - SwiftUI hosting

struct EmulationSurfaceView: UIViewControllerRepresentable {
    let appPath: String?
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> EmulationViewController {
        let controller = EmulationViewController(appPath: appPath, onExit: onExit)
        Probe.mark("makeUIViewController appPath=\(appPath ?? "nil")")
        return controller
    }

    func updateUIViewController(_ uiViewController: EmulationViewController, context: Context) {}
}

// Step 9: SCE_CTRL button bits for the on-screen gamepad (mirrors
// vita3k/ctrl/include/ctrl/ctrl.h). The non-extended set aliases L==L2 and
// R==R2, matching the real Vita's SceCtrlData.buttons layout.
enum SceCtrl {
    static let select: UInt32 = 0x00000001
    static let start: UInt32 = 0x00000008
    static let up: UInt32 = 0x00000010
    static let right: UInt32 = 0x00000020
    static let down: UInt32 = 0x00000040
    static let left: UInt32 = 0x00000080
    static let l: UInt32 = 0x00000100   // non-ext: L2 == L
    static let r: UInt32 = 0x00000200   // non-ext: R2 == R
    static let triangle: UInt32 = 0x00001000
    static let circle: UInt32 = 0x00002000
    static let cross: UInt32 = 0x00004000
    static let square: UInt32 = 0x00008000

    // Extended (SceCtrlDataExt) bits.
    static let extL1: UInt32 = 0x00000400
    static let extR1: UInt32 = 0x00000800
    static let extL2: UInt32 = 0x00000100
    static let extR2: UInt32 = 0x00000200
    static let extL3: UInt32 = 0x00000002
    static let extR3: UInt32 = 0x00000004
}

/// A draggable analog stick. Reports normalized (-1..1) offsets through
/// `onChange` (x right+, y down+ in screen space, which is LX/LY, RX/RY).
/// The knob springs back to center when released.
final class VirtualStickView: UIView {
    var onChange: ((_ x: Float, _ y: Float) -> Void)?

    private let knob = UIView()
    private var travel: CGFloat { max(1, (bounds.width - knob.bounds.width) / 2) }
    private var tracking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = bounds.width / 2
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        knob.layer.cornerRadius = knob.bounds.width / 2
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let s = knob.bounds.width
        knob.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = true
        handle(touches.first)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracking else { return }
        handle(touches.first)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = false
        center()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        tracking = false
        center()
    }

    private func handle(_ touch: UITouch?) {
        guard let touch else { return }
        let p = touch.location(in: self)
        let cx = bounds.width / 2
        let cy = bounds.height / 2
        var dx = p.x - cx
        var dy = p.y - cy
        let dist = max(abs(dx), abs(dy))
        if dist > travel {
            dx *= travel / dist
            dy *= travel / dist
        }
        knob.frame = CGRect(x: (bounds.width - knob.bounds.width) / 2 + dx,
                            y: (bounds.height - knob.bounds.height) / 2 + dy,
                            width: knob.bounds.width, height: knob.bounds.height)
        onChange?(Float(dx / travel), Float(dy / travel))
    }

    func center() {
        tracking = false
        layoutIfNeeded()
        let s = knob.bounds.width
        knob.frame = CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        onChange?(0, 0)
    }
}

/// On-screen gamepad: D-pad, ABXY, two sticks, shoulders, Select/Start.
/// Writes the full SCE_CTRL button mask (and stick axes) into the core on
/// every touch; all buttons clear when the view is deactivated.
final class VirtualGamepadView: UIView {
    private var pressed: Set<UInt32> = []       // non-extended bits held
    private var pressedExt: Set<UInt32> = []    // extended bits held
    private var leftStick: (Float, Float) = (0, 0)
    private var rightStick: (Float, Float) = (0, 0)

    private let leftStickView = VirtualStickView()
    private let rightStickView = VirtualStickView()

    /// 0 = off, 1 = on (drives the core's virtual_pad.active)
    var isActive = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addSubview(leftStickView)
        addSubview(rightStickView)

        leftStickView.onChange = { [weak self] x, y in
            guard let self else { return }
            self.leftStick = (x, y)
            self.pushAxes()
        }
        rightStickView.onChange = { [weak self] x, y in
            guard let self else { return }
            self.rightStick = (x, y)
            self.pushAxes()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let W = bounds.width
        let H = bounds.height
        let on = isActive
        // Both axes matter: landscape phones have much less vertical room.
        let cell = min(48, max(30, min(W * 0.105, (H - 74) / 4.6)))
        let stick = min(100, cell * 1.7)
        leftStickView.isHidden = !on
        rightStickView.isHidden = !on
        let leftCX = cell * 1.5 + 4
        let rightCX = W - leftCX
        leftStickView.frame = CGRect(x: leftCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        rightStickView.frame = CGRect(x: rightCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        leftStickView.knobSize(stick * 0.4)
        rightStickView.knobSize(stick * 0.4)
        let padY = max(48, leftStickView.frame.minY - cell * 3 - 8)
        dpad(4, padY, cell, on)
        let rightX = W - 4 - 3 * cell
        placeButton(abTriangle, rightX + cell, padY, cell, on)
        placeButton(abSquare, rightX, padY + cell, cell, on)
        placeButton(abCircle, rightX + 2 * cell, padY + cell, cell, on)
        placeButton(abCross, rightX + cell, padY + 2 * cell, cell, on)
        placeButton(btnSelect, W / 2 - 55, H - 44, 44, on)
        placeButton(btnStart, W / 2 + 11, H - 44, 44, on)
        placeButton(btnL, leftCX - 22, 0, 44, on)
        placeButton(btnR, rightCX - 22, 0, 44, on)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Empty overlay space belongs to the game's front touchscreen.
        isActive && subviews.contains { !$0.isHidden && $0.frame.contains(point) }
    }

    func resetInput() {
        pressed.removeAll()
        pressedExt.removeAll()
        for button in buttonCache.values { button.isHighlighted = false }
        leftStickView.center()
        rightStickView.center()
        leftStick = (0, 0)
        rightStick = (0, 0)
        Vita3KCore.virtualAxes(lx: 0, ly: 0, rx: 0, ry: 0)
        Vita3KCore.virtualButtons(0, 0)
    }

    // MARK: - Layout helpers

    private func placeButton(_ b: UIButton, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ on: Bool) {
        b.frame = CGRect(x: x, y: y, width: size, height: size)
        b.isHidden = !on
        b.layer.cornerRadius = size / 2
    }

    private func dpad(_ x: CGFloat, _ y: CGFloat, _ c: CGFloat, _ on: Bool) {
        // (col,row): up=(1,0) left=(0,1) right=(2,1) down=(1,2)
        placeButton(dpUp, x + c, y, c, on)
        placeButton(dpLeft, x, y + c, c, on)
        placeButton(dpRight, x + c * 2, y + c, c, on)
        placeButton(dpDown, x + c, y + c * 2, c, on)
    }

    // MARK: - Button widgets (created once, reused across layouts)

    private var buttonCache: [Int: UIButton] = [:]

    private func button(_ title: String, tag: Int) -> UIButton {
        if let b = buttonCache[tag] {
            return b
        }
        let b = UIButton(configuration: .plain())
        b.configuration?.title = title
        b.configuration?.contentInsets = .zero
        b.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: tag >= 30 ? 11 : 20, weight: .semibold)
            return attributes
        }
        b.titleLabel?.numberOfLines = 1
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.tintColor = .white.withAlphaComponent(0.85)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        b.tag = tag
        b.accessibilityIdentifier = "pad-\(tag)"
        b.accessibilityLabel = title
        addSubview(b)
        wire(b)
        buttonCache[tag] = b
        return b
    }

    private var dpUp: UIButton { button("▲", tag: 0) }
    private var dpLeft: UIButton { button("◀", tag: 1) }
    private var dpRight: UIButton { button("▶", tag: 2) }
    private var dpDown: UIButton { button("▼", tag: 3) }
    private var abTriangle: UIButton { button("△", tag: 10) }
    private var abSquare: UIButton { button("□", tag: 11) }
    private var abCross: UIButton { button("✕", tag: 12) }
    private var abCircle: UIButton { button("◯", tag: 13) }
    private var btnL: UIButton { button("L", tag: 20) }
    private var btnR: UIButton { button("R", tag: 21) }
    private var btnSelect: UIButton { button("SEL", tag: 30) }
    private var btnStart: UIButton { button("ST", tag: 31) }

    private func wire(_ b: UIButton) {
        b.addTarget(self, action: #selector(buttonDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(buttonUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func buttonDown(_ sender: UIButton) {
        setPressed(buttonBit(sender.tag, ext: false), ext: false, on: true)
        setPressed(buttonBit(sender.tag, ext: true), ext: true, on: true)
        pushButtons()
    }

    @objc private func buttonUp(_ sender: UIButton) {
        setPressed(buttonBit(sender.tag, ext: false), ext: false, on: false)
        setPressed(buttonBit(sender.tag, ext: true), ext: true, on: false)
        pushButtons()
    }

    private func buttonBit(_ tag: Int, ext: Bool) -> UInt32 {
        switch tag {
        case 0: return SceCtrl.up
        case 1: return SceCtrl.left
        case 2: return SceCtrl.right
        case 3: return SceCtrl.down
        case 10: return SceCtrl.triangle
        case 11: return SceCtrl.square
        case 12: return SceCtrl.cross
        case 13: return SceCtrl.circle
        case 20: return ext ? SceCtrl.extL1 : SceCtrl.l
        case 21: return ext ? SceCtrl.extR1 : SceCtrl.r
        case 30: return SceCtrl.select
        case 31: return SceCtrl.start
        default: return 0
        }
    }

    private func setPressed(_ bit: UInt32, ext: Bool, on: Bool) {
        guard bit != 0 else { return }
        if on {
            _ = ext ? pressedExt.insert(bit) : pressed.insert(bit)
        } else {
            _ = ext ? pressedExt.remove(bit) : pressed.remove(bit)
        }
    }

    private func pushButtons() {
        guard isActive else { return }
        var m: UInt32 = 0
        for b in pressed { m |= b }
        var me: UInt32 = 0
        for b in pressedExt { me |= b }
        Vita3KCore.virtualButtons(m, me)
    }

    private func pushAxes() {
        guard isActive else { return }
        Vita3KCore.virtualAxes(lx: leftStick.0, ly: leftStick.1, rx: rightStick.0, ry: rightStick.1)
    }

    /// Show/hide the pad and enable/disable it in the core.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        isUserInteractionEnabled = on
        if on {
            Vita3KCore.virtualPadEnabled(true)
        } else {
            resetInput()
            Vita3KCore.virtualPadEnabled(false)
        }
        setNeedsLayout()
    }
}

extension VirtualStickView {
    func knobSize(_ s: CGFloat) {
        knob.bounds.size = CGSize(width: s, height: s)
        knob.layer.cornerRadius = s / 2
        layoutIfNeeded()
    }
}

// Vita3K iOS — the on-screen gamepad: monochrome keys that match the app's
// design, and a layout editor (move / resize each key or a whole group, saved
// for all games or per game).
import SwiftUI
import UIKit

// MARK: - Elements and layout model

enum PadGroup: String, CaseIterable {
    case dpad, face, shoulders, system, leftStick, rightStick

    var members: [PadElement] { PadElement.allCases.filter { $0.group == self } }

    var title: String {
        switch self {
        case .dpad: L10n.text("Direcionais")
        case .face: L10n.text("Botões de ação")
        case .shoulders: L10n.text("Gatilhos")
        case .system: L10n.text("Select e Start")
        case .leftStick: L10n.text("Analógico esquerdo")
        case .rightStick: L10n.text("Analógico direito")
        }
    }
}

enum PadElement: String, CaseIterable, Codable {
    case up, left, right, down
    case triangle, square, cross, circle
    case l, r
    case select, start
    case leftStick, rightStick

    var tag: Int {
        switch self {
        case .up: 0
        case .left: 1
        case .right: 2
        case .down: 3
        case .triangle: 10
        case .square: 11
        case .cross: 12
        case .circle: 13
        case .l: 20
        case .r: 21
        case .select: 30
        case .start: 31
        case .leftStick: 40
        case .rightStick: 41
        }
    }

    var group: PadGroup {
        switch self {
        case .up, .left, .right, .down: .dpad
        case .triangle, .square, .cross, .circle: .face
        case .l, .r: .shoulders
        case .select, .start: .system
        case .leftStick: .leftStick
        case .rightStick: .rightStick
        }
    }

    var title: String {
        switch self {
        case .up: L10n.text("Cima")
        case .left: L10n.text("Esquerda")
        case .right: L10n.text("Direita")
        case .down: L10n.text("Baixo")
        case .triangle: L10n.text("Triângulo")
        case .square: L10n.text("Quadrado")
        case .cross: L10n.text("Cruz")
        case .circle: L10n.text("Círculo")
        case .l: "L"
        case .r: "R"
        case .select: "Select"
        case .start: "Start"
        case .leftStick: L10n.text("Analógico esquerdo")
        case .rightStick: L10n.text("Analógico direito")
        }
    }
}

/// Offset (fraction of the pad size) from the default position, and size factor.
struct ControlTransform: Codable, Equatable {
    var dx: Double = 0
    var dy: Double = 0
    var scale: Double = 1
    var opacity: Double = 1

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dx = try c.decodeIfPresent(Double.self, forKey: .dx) ?? 0
        dy = try c.decodeIfPresent(Double.self, forKey: .dy) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

typealias ControlsLayout = [String: ControlTransform]

enum LayoutScope: Int {
    case global, game
}

enum ControlsLayoutStore {
    private static func key(_ scope: LayoutScope, titleID: String?, landscape: Bool) -> String {
        let o = landscape ? "l" : "p"
        switch scope {
        case .global: return "controls.layout.global.\(o)"
        case .game: return "controls.layout.game.\(titleID ?? "-").\(o)"
        }
    }

    private static func read(_ key: String) -> ControlsLayout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ControlsLayout.self, from: data)
    }

    /// This game's own layout wins over the global one.
    static func load(titleID: String?, landscape: Bool) -> ControlsLayout {
        read(key(.game, titleID: titleID, landscape: landscape))
            ?? read(key(.global, titleID: titleID, landscape: landscape))
            ?? [:]
    }

    static func save(_ layout: ControlsLayout, scope: LayoutScope, titleID: String?, landscape: Bool) {
        let clean = layout.filter { $0.value != ControlTransform() }
        guard let data = try? JSONEncoder().encode(clean) else { return }
        UserDefaults.standard.set(data, forKey: key(scope, titleID: titleID, landscape: landscape))
    }

    static func hasGameLayout(titleID: String?) -> Bool {
        [true, false].contains { UserDefaults.standard.data(forKey: key(.game, titleID: titleID, landscape: $0)) != nil }
    }
}

// MARK: - Keys

final class PadKeyButton: UIButton {
    enum Look {
        case glyph(PadElement)
        case chevron(CGFloat)      // rotation in radians (0 = up)
        case pill(String)
    }

    private let look: Look
    private let shape = CAShapeLayer()
    private let label = UILabel()

    init(look: Look, tag: Int, title: String) {
        self.look = look
        super.init(frame: .zero)
        self.tag = tag
        accessibilityIdentifier = "pad-\(tag)"
        accessibilityLabel = title
        layer.borderWidth = 1.2
        layer.addSublayer(shape)
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isUserInteractionEnabled = false
        if case .pill(let text) = look {
            label.text = text
            addSubview(label)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { refresh() } }

    /// Small keys keep a finger-sized touch target (44 pt) however far they are scaled down.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (44 - bounds.width) / 2), dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }

    private func refresh() {
        let on = isHighlighted
        backgroundColor = on ? UIColor.white.withAlphaComponent(0.9) : UIColor.black.withAlphaComponent(0.34)
        layer.borderColor = UIColor.white.withAlphaComponent(on ? 0.9 : 0.4).cgColor
        let ink = on ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(0.92)
        shape.strokeColor = ink.cgColor
        if case .chevron = look { shape.fillColor = ink.cgColor }
        label.textColor = ink
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        shape.frame = bounds
        label.frame = bounds.insetBy(dx: 6, dy: 0)
        label.font = .systemFont(ofSize: max(9, h * 0.34), weight: .heavy)
        let c = CGPoint(x: w / 2, y: h / 2)
        let r = min(w, h) * 0.2
        shape.lineWidth = max(1.8, min(w, h) * 0.055)
        var path = UIBezierPath()
        switch look {
        case .pill:
            layer.cornerRadius = h / 2
            shape.path = nil
        case .chevron(let angle):
            layer.cornerRadius = min(w, h) * 0.3
            let k = min(w, h) * 0.2
            path.move(to: CGPoint(x: 0, y: -k))
            path.addLine(to: CGPoint(x: k * 0.95, y: k * 0.7))
            path.addLine(to: CGPoint(x: -k * 0.95, y: k * 0.7))
            path.close()
            path.apply(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            shape.path = path.cgPath
        case .glyph(let element):
            layer.cornerRadius = min(w, h) / 2
            switch element {
            case .triangle:
                path.move(to: CGPoint(x: c.x, y: c.y - r * 1.15))
                path.addLine(to: CGPoint(x: c.x + r * 1.1, y: c.y + r * 0.85))
                path.addLine(to: CGPoint(x: c.x - r * 1.1, y: c.y + r * 0.85))
                path.close()
            case .circle:
                path.addArc(withCenter: c, radius: r * 1.05, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            case .square:
                path = UIBezierPath(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.18)
            default: // cross
                path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
                path.move(to: CGPoint(x: c.x + r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
            }
            shape.path = path.cgPath
        }
    }
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
        backgroundColor = UIColor.black.withAlphaComponent(0.28)
        layer.borderWidth = 1.2
        layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
        layer.cornerRadius = bounds.width / 2
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        knob.layer.borderWidth = 1.2
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
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
        track(at: touch.location(in: self))
    }

    /// Moves the knob toward `p` (in this view's coordinates).
    func track(at p: CGPoint) {
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

    func knobSize(_ s: CGFloat) {
        knob.bounds.size = CGSize(width: s, height: s)
        knob.layer.cornerRadius = s / 2
        layoutIfNeeded()
    }
}

// MARK: - The pad

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

    /// Which game's layout to use (nil: only the global one).
    var titleID: String? {
        didSet { if titleID != oldValue { loadedKey = nil; setNeedsLayout() } }
    }
    private var layout: ControlsLayout = [:]
    private var loadedKey: String?

    /// 0 = off, 1 = on (drives the core's virtual_pad.active)
    var isActive = false {
        didSet { setNeedsLayout() }
    }

    // Editing
    enum EditMode: Int { case individual, group, all }
    private(set) var isEditing = false
    var editMode: EditMode = .individual {
        didSet { if editMode != oldValue { notifySelection(); updateOverlay() } }
    }
    private(set) var selected: PadElement? {
        didSet { notifySelection(); updateOverlay() }
    }
    /// Reports (title, scale) of the selection, or nil when nothing is selected.
    var onSelectionChange: (((title: String, scale: Double, opacity: Double)?) -> Void)?
    private var layoutBeforeEditing: ControlsLayout = [:]
    /// While editing, each orientation keeps its own working copy so rotating the
    /// phone never leaks edits from one orientation into the other.
    private var editLandscape = false
    private var editOriginal: [Bool: ControlsLayout] = [:]
    private var editStash: [Bool: ControlsLayout] = [:]
    var onEditOrientationChange: ((Bool) -> Void)?
    private let overlay = CAShapeLayer()
    private let selectedOverlay = CAShapeLayer()
    private var lastPan: CGPoint = .zero
    private var editGestures: [UIGestureRecognizer] = []
    /// Fingers currently driving a floating stick.
    private var floating: [PadElement: UITouch] = [:]
    static let dynamicSticksPreference = "emulation.dynamicSticks"
    private var dynamicSticks: Bool {
        UserDefaults.standard.bool(forKey: Self.dynamicSticksPreference)
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
        isMultipleTouchEnabled = true
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

        for shape in [overlay, selectedOverlay] {
            shape.fillColor = nil
            shape.lineDashPattern = [5, 4]
            shape.isHidden = true
            layer.addSublayer(shape)
        }
        overlay.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        overlay.lineWidth = 1
        selectedOverlay.strokeColor = UIColor.white.cgColor
        selectedOverlay.lineWidth = 2

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Only while editing: otherwise they would cancel presses on the keys.
        for gesture in [pan, tap] {
            gesture.isEnabled = false
            addGestureRecognizer(gesture)
        }
        editGestures = [pan, tap]
    }

    // MARK: Geometry

    /// Default (unscaled, unmoved) frame of every element.
    private func defaultFrames() -> [PadElement: CGRect] {
        let W = bounds.width
        let H = bounds.height
        // Both axes matter: landscape phones have much less vertical room.
        let cell = min(48, max(30, min(W * 0.105, (H - 74) / 4.6)))
        let stick = min(100, cell * 1.7)
        let leftCX = cell * 1.5 + 4
        let rightCX = W - leftCX
        var f: [PadElement: CGRect] = [:]
        f[.leftStick] = CGRect(x: leftCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        f[.rightStick] = CGRect(x: rightCX - stick / 2, y: H - stick - 4, width: stick, height: stick)
        let padY = max(48, f[.leftStick]!.minY - cell * 3 - 8)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        f[.up] = box(4 + cell, padY, cell, cell)
        f[.left] = box(4, padY + cell, cell, cell)
        f[.right] = box(4 + cell * 2, padY + cell, cell, cell)
        f[.down] = box(4 + cell, padY + cell * 2, cell, cell)
        let rightX = W - 4 - 3 * cell
        f[.triangle] = box(rightX + cell, padY, cell, cell)
        f[.square] = box(rightX, padY + cell, cell, cell)
        f[.circle] = box(rightX + 2 * cell, padY + cell, cell, cell)
        f[.cross] = box(rightX + cell, padY + 2 * cell, cell, cell)
        f[.select] = box(W / 2 - 74, H - 36, 66, 30)
        f[.start] = box(W / 2 + 8, H - 36, 66, 30)
        f[.l] = box(leftCX - 32, 0, 64, 34)
        f[.r] = box(rightCX - 32, 0, 64, 34)
        return f
    }

    private func frame(of element: PadElement, defaults: [PadElement: CGRect]) -> CGRect {
        guard let base = defaults[element] else { return .zero }
        let t = layout[element.rawValue] ?? ControlTransform()
        let size = CGSize(width: base.width * t.scale, height: base.height * t.scale)
        let center = CGPoint(x: base.midX + t.dx * bounds.width, y: base.midY + t.dy * bounds.height)
        var rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        // Never leave the screen.
        rect.origin.x = min(max(rect.origin.x, 0), max(0, bounds.width - rect.width))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, bounds.height - rect.height))
        return rect
    }

    private func view(for element: PadElement) -> UIView {
        switch element {
        case .leftStick: leftStickView
        case .rightStick: rightStickView
        default: key(element)
        }
    }

    private var landscape: Bool { bounds.width > bounds.height }

    private func hitFrame(_ v: UIView) -> CGRect {
        guard v is PadKeyButton else { return v.frame }
        return v.frame.insetBy(dx: -max(0, (44 - v.frame.width) / 2), dy: -max(0, (44 - v.frame.height) / 2))
    }

    private func reloadLayoutIfNeeded() {
        let key = "\(titleID ?? "-")|\(landscape)"
        guard key != loadedKey, !isEditing else { return }
        loadedKey = key
        layout = ControlsLayoutStore.load(titleID: titleID, landscape: landscape)
    }

    private func switchEditOrientationIfNeeded() {
        guard isEditing, bounds.width > 0, landscape != editLandscape else { return }
        editStash[editLandscape] = layout
        editLandscape = landscape
        if editOriginal[landscape] == nil {
            editOriginal[landscape] = ControlsLayoutStore.load(titleID: titleID, landscape: landscape)
        }
        layout = editStash[landscape] ?? editOriginal[landscape] ?? [:]
        selected = nil
        notifySelection()
        onEditOrientationChange?(landscape)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switchEditOrientationIfNeeded()
        reloadLayoutIfNeeded()
        let shown = isActive || isEditing
        let defaults = defaultFrames()
        let dynamic = dynamicSticks && !isEditing
        for element in PadElement.allCases {
            let v = view(for: element)
            let isStick = element == .leftStick || element == .rightStick
            // A floating stick keeps the place where the finger landed.
            if isStick, floating[element] != nil { continue }
            // Dynamic sticks only appear under a finger.
            v.isHidden = !shown || (isStick && dynamic)
            v.frame = frame(of: element, defaults: defaults)
            v.isUserInteractionEnabled = !isEditing && !(isStick && dynamicSticks)
            v.alpha = CGFloat(layout[element.rawValue]?.opacity ?? 1)
            if v is VirtualStickView, v.bounds.width > 0 {
                (v as? VirtualStickView)?.knobSize(v.bounds.width * 0.4)
            }
        }
        for v in [leftStickView, rightStickView] { bringSubviewToFront(v) }
        updateOverlay()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Editing: the whole pad area is the canvas. Otherwise empty overlay
        // space belongs to the game's front touchscreen.
        if isEditing { return true }
        if isActive, dynamicSticks, dynamicElement(at: point) != nil { return true }
        return isActive && subviews.contains { !$0.isHidden && hitFrame($0).contains(point) }
    }

    // MARK: Dynamic sticks

    /// Which floating stick a touch starting at `point` would drive, or nil.
    /// Only empty space in the lower left / lower right counts: never on a key
    /// (with a margin), and never in the middle or top, which stay free for
    /// the game's own touch screen.
    private func dynamicElement(at point: CGPoint) -> PadElement? {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return nil }
        let top = landscape ? H * 0.28 : 0
        guard point.y >= top else { return nil }
        let element: PadElement
        if point.x < W * 0.4 { element = .leftStick }
        else if point.x > W * 0.6 { element = .rightStick }
        else { return nil }
        let defaults = defaultFrames()
        for key in PadElement.allCases where key != .leftStick && key != .rightStick {
            if frame(of: key, defaults: defaults).insetBy(dx: -14, dy: -14).contains(point) { return nil }
        }
        return element
    }

    private func stickView(_ element: PadElement) -> VirtualStickView {
        element == .leftStick ? leftStickView : rightStickView
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isActive, dynamicSticks, !isEditing else { return super.touchesBegan(touches, with: event) }
        for touch in touches {
            let p = touch.location(in: self)
            guard let element = dynamicElement(at: p), floating[element] == nil else { continue }
            let stick = stickView(element)
            let size = frame(of: element, defaults: defaultFrames()).size
            var origin = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
            origin.x = min(max(origin.x, 0), bounds.width - size.width)
            origin.y = min(max(origin.y, 0), bounds.height - size.height)
            floating[element] = touch
            stick.frame = CGRect(origin: origin, size: size)
            stick.knobSize(size.width * 0.4)
            stick.alpha = CGFloat(layout[element.rawValue]?.opacity ?? 1)
            stick.isHidden = false
            stick.track(at: touch.location(in: stick))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !floating.isEmpty else { return super.touchesMoved(touches, with: event) }
        for (element, touch) in floating where touches.contains(touch) {
            let stick = stickView(element)
            stick.track(at: touch.location(in: stick))
        }
    }

    private func endFloating(_ touches: Set<UITouch>) {
        for (element, touch) in floating where touches.contains(touch) {
            floating[element] = nil
            let stick = stickView(element)
            stick.center()
            stick.isHidden = true
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endFloating(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endFloating(touches)
        super.touchesCancelled(touches, with: event)
    }

    func resetInput() {
        pressed.removeAll()
        pressedExt.removeAll()
        for button in buttonCache.values { button.isHighlighted = false }
        floating.removeAll()
        leftStickView.center()
        rightStickView.center()
        leftStick = (0, 0)
        rightStick = (0, 0)
        Vita3KCore.virtualAxes(lx: 0, ly: 0, rx: 0, ry: 0)
        Vita3KCore.virtualButtons(0, 0)
    }

    // MARK: Key widgets (created once, reused across layouts)

    private var buttonCache: [Int: PadKeyButton] = [:]

    private func key(_ element: PadElement) -> PadKeyButton {
        if let b = buttonCache[element.tag] { return b }
        let look: PadKeyButton.Look
        switch element {
        case .up: look = .chevron(0)
        case .right: look = .chevron(.pi / 2)
        case .down: look = .chevron(.pi)
        case .left: look = .chevron(-.pi / 2)
        case .l: look = .pill("L")
        case .r: look = .pill("R")
        case .select: look = .pill("SELECT")
        case .start: look = .pill("START")
        default: look = .glyph(element)
        }
        let b = PadKeyButton(look: look, tag: element.tag, title: element.title)
        addSubview(b)
        b.addTarget(self, action: #selector(buttonDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(buttonUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        buttonCache[element.tag] = b
        return b
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
        isUserInteractionEnabled = on || isEditing
        if on {
            Vita3KCore.virtualPadEnabled(true)
        } else {
            resetInput()
            Vita3KCore.virtualPadEnabled(false)
        }
        setNeedsLayout()
    }

    // MARK: - Layout editing

    private var targets: [PadElement] {
        if editMode == .all { return PadElement.allCases }
        guard let selected else { return [] }
        return editMode == .group ? selected.group.members : [selected]
    }

    func beginEditing() {
        resetInput()
        layoutBeforeEditing = layout
        editLandscape = landscape
        editOriginal = [landscape: layout]
        editStash = [:]
        isEditing = true
        onEditOrientationChange?(landscape)
        editGestures.forEach { $0.isEnabled = true }
        selected = nil
        isUserInteractionEnabled = true
        setNeedsLayout()
    }

    /// Ends editing; `scope` saves the layout (nil discards the changes).
    func endEditing(save scope: LayoutScope?) {
        editStash[editLandscape] = layout
        if let scope {
            // Only orientations that were actually changed are written.
            for (orientation, edited) in editStash where edited != (editOriginal[orientation] ?? [:]) {
                ControlsLayoutStore.save(edited, scope: scope, titleID: titleID, landscape: orientation)
            }
        } else {
            layout = layoutBeforeEditing
        }
        editStash = [:]
        editOriginal = [:]
        isEditing = false
        editGestures.forEach { $0.isEnabled = false }
        selected = nil
        isUserInteractionEnabled = isActive
        loadedKey = nil
        setNeedsLayout()
    }

    func resetLayoutToDefault() {
        layout = [:]
        setNeedsLayout()
        notifySelection()
    }

    /// Whether this game already has its own saved layout.
    var gameHasOwnLayout: Bool { ControlsLayoutStore.hasGameLayout(titleID: titleID) }

    func setSelectionScale(_ value: Double) {
        let members = targets
        guard let first = members.first else { return }
        let old = layout[(editMode == .all ? PadElement.cross : first).rawValue]?.scale ?? 1
        let ratio = value / max(old, 0.01)
        let defaults = defaultFrames()
        let centers = members.map { m -> CGPoint in
            let f = frame(of: m, defaults: defaults)
            return CGPoint(x: f.midX, y: f.midY)
        }
        let centroid = CGPoint(x: centers.map(\.x).reduce(0, +) / CGFloat(centers.count),
                               y: centers.map(\.y).reduce(0, +) / CGFloat(centers.count))
        for (i, m) in members.enumerated() {
            var t = layout[m.rawValue] ?? ControlTransform()
            t.scale = min(max(t.scale * ratio, 0.5), 2.2)
            if members.count > 1, editMode != .all, let base = defaults[m] {
                let c = CGPoint(x: centroid.x + (centers[i].x - centroid.x) * ratio,
                                y: centroid.y + (centers[i].y - centroid.y) * ratio)
                t.dx = Double((c.x - base.midX) / bounds.width)
                t.dy = Double((c.y - base.midY) / bounds.height)
            }
            layout[m.rawValue] = t
        }
        setNeedsLayout()
        layoutIfNeeded()
        notifySelection()
    }

    func setSelectionOpacity(_ value: Double) {
        for m in targets {
            var t = layout[m.rawValue] ?? ControlTransform()
            t.opacity = min(max(value, 0.15), 1)
            layout[m.rawValue] = t
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func notifySelection() {
        guard isEditing else { onSelectionChange?(nil); return }
        if editMode == .all {
            let t = layout[PadElement.cross.rawValue] ?? ControlTransform()
            onSelectionChange?((L10n.text("Todos os botões"), t.scale, t.opacity))
            return
        }
        guard let selected else { onSelectionChange?(nil); return }
        let title = editMode == .group ? selected.group.title : selected.title
        let t = layout[selected.rawValue] ?? ControlTransform()
        onSelectionChange?((title, t.scale, t.opacity))
    }

    private func element(at point: CGPoint) -> PadElement? {
        let defaults = defaultFrames()
        var best: (PadElement, CGFloat)?
        for element in PadElement.allCases {
            let base = frame(of: element, defaults: defaults)
            let f = base.insetBy(dx: -max(8, (44 - base.width) / 2), dy: -max(8, (44 - base.height) / 2))
            guard f.contains(point) else { continue }
            let d = hypot(f.midX - point.x, f.midY - point.y)
            if best == nil || d < best!.1 { best = (element, d) }
        }
        return best?.0
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard isEditing else { return }
        selected = element(at: gesture.location(in: self))
        if editMode == .all { notifySelection() }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEditing else { return }
        switch gesture.state {
        case .began:
            lastPan = .zero
            if let hit = element(at: gesture.location(in: self)) { selected = hit }
            else if editMode != .all { selected = nil }
        case .changed:
            let t = gesture.translation(in: self)
            var dx = t.x - lastPan.x
            var dy = t.y - lastPan.y
            lastPan = t
            let members = targets
            guard !members.isEmpty else { return }
            let defaults = defaultFrames()
            var lowX = -CGFloat.infinity, highX = CGFloat.infinity
            var lowY = -CGFloat.infinity, highY = CGFloat.infinity
            for m in members {
                let f = frame(of: m, defaults: defaults)
                lowX = max(lowX, -f.minX); highX = min(highX, bounds.width - f.maxX)
                lowY = max(lowY, -f.minY); highY = min(highY, bounds.height - f.maxY)
            }
            dx = min(max(dx, lowX), highX)
            dy = min(max(dy, lowY), highY)
            for m in members {
                var tr = layout[m.rawValue] ?? ControlTransform()
                tr.dx += Double(dx / bounds.width)
                tr.dy += Double(dy / bounds.height)
                layout[m.rawValue] = tr
            }
            setNeedsLayout()
            layoutIfNeeded()
        default:
            break
        }
    }

    private func updateOverlay() {
        overlay.isHidden = !isEditing
        selectedOverlay.isHidden = !isEditing || (selected == nil && editMode != .all)
        guard isEditing else { return }
        overlay.frame = bounds
        selectedOverlay.frame = bounds
        let defaults = defaultFrames()
        let all = UIBezierPath()
        for element in PadElement.allCases {
            all.append(UIBezierPath(roundedRect: frame(of: element, defaults: defaults).insetBy(dx: -3, dy: -3), cornerRadius: 10))
        }
        overlay.path = all.cgPath
        let union = targets.map { frame(of: $0, defaults: defaults) }.reduce(CGRect.null) { $0.union($1) }
        selectedOverlay.path = union.isNull ? nil : UIBezierPath(roundedRect: union.insetBy(dx: -6, dy: -6), cornerRadius: 14).cgPath
    }
}

// MARK: - Editor bar

@MainActor
final class ControlsEditorModel: ObservableObject {
    @Published var mode = 0   // 0 individual, 1 group, 2 all
    @Published var scopeIsGame = false
    @Published var selectionTitle: String?
    @Published var scale: Double = 1
    @Published var opacity: Double = 1
    @Published var expanded = false
    @Published var landscape = false
    var onModeChange: ((Int) -> Void)?
    var onDynamicChange: (() -> Void)?
    var onScale: ((Double) -> Void)?
    var onOpacity: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: ((LayoutScope) -> Void)?
}

struct ControlsEditorBar: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: ControlsEditorModel
    @AppStorage(VirtualGamepadView.dynamicSticksPreference) private var dynamicSticks = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { model.mode }, set: { model.mode = $0; model.onModeChange?($0) })) {
                    Text("Individual").tag(0)
                    Text("Grupo").tag(1)
                    Text("Todos").tag(2)
                }
                .pickerStyle(.segmented)
                Button(L10n.text("Cancelar")) { model.onCancel?() }
                    .buttonStyle(.bordered)
                Button(L10n.text("Salvar")) { model.onSave?(model.scopeIsGame ? .game : .global) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .font(.footnote.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                sliderColumn(icon: "arrow.up.left.and.arrow.down.right", label: "Tamanho",
                             value: Binding(get: { model.scale }, set: { model.scale = $0; model.onScale?($0) }),
                             range: 0.5...2.2)
                sliderColumn(icon: "circle.lefthalf.filled", label: "Opacidade",
                             value: Binding(get: { model.opacity }, set: { model.opacity = $0; model.onOpacity?($0) }),
                             range: 0.15...1)
            }
            HStack(spacing: 6) {
                Label(L10n.text(model.landscape ? "Paisagem" : "Retrato"),
                      systemImage: model.landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.12), in: Capsule())
                    .fixedSize()
                Text(model.selectionTitle ?? L10n.text("Toque num botão para selecioná-lo"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.expanded.toggle() }
                } label: {
                    Label(L10n.text(model.expanded ? "Menos" : "Mais"), systemImage: model.expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
            if model.expanded {
                Toggle(isOn: Binding(get: { dynamicSticks }, set: { dynamicSticks = $0; model.onDynamicChange?() })) {
                    Label("Analógicos dinâmicos", systemImage: "hand.point.up.left.fill")
                        .font(.footnote.weight(.semibold))
                }
                HStack(spacing: 8) {
                    Picker("", selection: $model.scopeIsGame) {
                        Text("Todos os jogos").tag(false)
                        Text("Este jogo").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button(L10n.text("Redefinir")) { model.onReset?() }
                        .font(.footnote.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(.horizontal, 12)
        .environment(\.colorScheme, .dark)
        .tint(palette.accent)
    }
}

private extension ControlsEditorBar {
    func sliderColumn(icon: String, label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(L10n.text(label)).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(verbatim: "\(Int((value.wrappedValue * 100).rounded()))%").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            Slider(value: value, in: range).disabled(model.selectionTitle == nil)
        }
    }
}

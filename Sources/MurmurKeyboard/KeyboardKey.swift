import SwiftUI
import UIKit

/// Visual description of a single key cap.
struct KeyboardKeyStyle {
    var title: String = ""
    var symbolName: String?
    var font: UIFont = .systemFont(ofSize: 24, weight: .light)
    var symbolPointSize: CGFloat = 16
    var symbolWeight: UIImage.SymbolWeight = .medium
    var glyphColor: UIColor = .label
    var capColor: UIColor = .clear
    var pressedCapColor: UIColor = .clear
    var cornerRadius: CGFloat = 14
    var showsPopup: Bool = false
    var alternatives: [String] = []
    var insertText: String?
    var isEnabled: Bool = true
    var isDarkMode: Bool = false
    var accessibilityLabel: String?
    var accessibilityHint: String?
}

/// A keyboard key drawn and driven by UIKit.
///
/// SwiftUI gestures inside a keyboard extension lose fast taps: the gesture can
/// be cancelled when a second thumb lands, when the host updates the text field,
/// or when the view rebuilds between touch-down and touch-up. Apple's keyboard
/// answers every touch, so Murmur's keys do the same — a plain `UIView` that
/// tracks its own touches, shows the character popup and the accent palette, and
/// inserts on lift, exactly like the system keyboard.
@MainActor
final class MurmurKeyCapView: UIView {

    // MARK: - Callbacks

    /// Fired the instant the finger lands, like Apple's key click.
    var onTouchDown: (() -> Void)?
    /// Fired once when the touch ends or is cancelled, for repeat actions.
    var onTouchEnd: (() -> Void)?
    /// Fired on a completed tap for keys that do not insert text.
    var onTap: (() -> Void)?
    /// Fired on a completed tap (or accent choice) with the text to insert.
    var onInsert: ((String) -> Void)?
    /// Fired when the accent palette takes over, so the character already typed
    /// on touch-down can be taken back.
    var onRetract: (() -> Void)?
    /// Fired when the accent palette selection moves.
    var onSelectionChange: (() -> Void)?

    // MARK: - Views

    private let capView = UIView()
    private let label = UILabel()
    private let symbolView = UIImageView()

    // MARK: - State

    private var style = KeyboardKeyStyle()
    private weak var activeTouch: UITouch?
    private var touchOrigin: CGPoint = .zero
    private var isTrackingTouch = false
    private var isCancelled = false
    private var isHighlighted = false
    /// True once this press has already typed its character on touch-down.
    private var hasCommittedPress = false

    private var popupView: KeyPopupView?
    private var paletteView: KeyPaletteView?
    private var selectedAlternate = -1
    private var paletteTask: Task<Void, Never>?

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false

        capView.isUserInteractionEnabled = false
        capView.layer.cornerCurve = .continuous
        addSubview(capView)

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.isUserInteractionEnabled = false
        capView.addSubview(label)

        symbolView.contentMode = .center
        symbolView.isUserInteractionEnabled = false
        capView.addSubview(symbolView)

        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    func apply(_ style: KeyboardKeyStyle) {
        self.style = style

        label.text = style.title
        label.font = style.font
        label.textColor = style.glyphColor

        if let symbolName = style.symbolName {
            let configuration = UIImage.SymbolConfiguration(
                pointSize: style.symbolPointSize,
                weight: style.symbolWeight
            )
            symbolView.image = UIImage(
                systemName: symbolName,
                withConfiguration: configuration
            )
            symbolView.tintColor = style.glyphColor
            symbolView.isHidden = false
            label.isHidden = true
        } else {
            symbolView.image = nil
            symbolView.isHidden = true
            label.isHidden = false
        }

        capView.layer.cornerRadius = style.cornerRadius
        label.alpha = style.isEnabled ? 1 : 0.4
        symbolView.alpha = style.isEnabled ? 1 : 0.4
        isUserInteractionEnabled = style.isEnabled

        accessibilityLabel = style.accessibilityLabel
            ?? (style.title.isEmpty ? nil : style.title)
        accessibilityHint = style.accessibilityHint
        accessibilityTraits = style.insertText == nil ? .button : .keyboardKey

        updateCapAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capView.frame = bounds
        capView.layer.cornerRadius = style.cornerRadius
        label.frame = bounds
        symbolView.frame = bounds
    }

    /// Apple's keyboard has no dead spots between caps: a plane-wide hit test
    /// resolves every touch to the nearest key. Ours are separate views sitting
    /// in a 6 pt grid, so without this a fast thumb that lands in a gap types
    /// nothing at all — which is exactly what "it starts missing keys when I
    /// type faster" feels like. Half a gap of slop glues the caps together.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return bounds.insetBy(dx: -5, dy: -5).contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dismissOverlays()
            // Never leave a key stuck in a "still pressed" state after the view
            // has been off screen: a stuck key would ignore every later touch.
            paletteTask?.cancel()
            paletteTask = nil
            activeTouch = nil
            isTrackingTouch = false
            isCancelled = false
            setHighlighted(false)
        }
    }

    /// VoiceOver's double-tap lands here rather than in the touch handlers.
    override func accessibilityActivate() -> Bool {
        guard style.isEnabled else { return false }
        if let insertText = style.insertText {
            onInsert?(insertText)
        } else if let onTap {
            onTap()
        } else {
            // Keys such as delete act on touch-down and touch-up instead.
            onTouchDown?()
            onTouchEnd?()
        }
        return true
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard style.isEnabled, let touch = touches.first else { return }

        // A press whose end never arrived must not lock this key out forever.
        // If nothing is on the screen any more, clear the stale state and treat
        // this as a fresh press.
        if isTrackingTouch {
            guard event?.allTouches?.isEmpty != false else { return }
            finishTouch()
        }

        activeTouch = touch
        isTrackingTouch = true
        isCancelled = false
        hasCommittedPress = false
        touchOrigin = touch.location(in: self)

        setHighlighted(true)
        onTouchDown?()

        // Type on touch-down. Waiting for the lift meant every lost touch-up —
        // a touch the system cancelled, a view rebuilt mid-press, a busy main
        // thread — dropped the character. The character is typed the moment the
        // finger lands; holding for an accent takes it back again below.
        if let insertText = style.insertText {
            onInsert?(insertText)
            hasCommittedPress = true
        }

        if style.showsPopup, !style.title.isEmpty {
            showPopup()
        }
        if !style.alternatives.isEmpty {
            schedulePalette()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTrackingTouch,
              let touch = touches.first,
              touch === activeTouch
        else { return }

        if let paletteView {
            let index = paletteView.index(at: touch.location(in: paletteView))
            if index != selectedAlternate {
                selectedAlternate = index
                paletteView.select(index: index)
                if index >= 0 {
                    onSelectionChange?()
                }
            }
            return
        }

        let point = touch.location(in: self)
        let dx = point.x - touchOrigin.x
        let dy = point.y - touchOrigin.y

        // Apple cancels a key once the finger wanders off it, and nothing is
        // typed. The character was typed on touch-down, so take it back.
        guard !isCancelled, (dx * dx + dy * dy) > 40 * 40 else { return }
        isCancelled = true
        setHighlighted(false)
        dismissOverlays()
        if hasCommittedPress {
            hasCommittedPress = false
            onRetract?()
        }
        finishTouch()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTrackingTouch,
              let touch = touches.first,
              touch === activeTouch
        else { return }

        if paletteView != nil {
            if selectedAlternate >= 0, selectedAlternate < style.alternatives.count {
                onInsert?(style.alternatives[selectedAlternate])
            }
        } else if style.insertText == nil, !isCancelled {
            // Mode keys (shift, 123, return) act on release, unless the finger
            // slid off the key.
            onTap?()
        }

        finishTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTrackingTouch else { return }

        // The character is already typed; a system cancel (its own gestures
        // taking over, the host closing the field) simply ends the press.
        isCancelled = true
        finishTouch()
    }

    private func finishTouch() {
        guard isTrackingTouch else { return }
        isTrackingTouch = false
        activeTouch = nil
        hasCommittedPress = false
        paletteTask?.cancel()
        paletteTask = nil
        setHighlighted(false)
        dismissOverlays()
        selectedAlternate = -1
        onTouchEnd?()
    }

    private func setHighlighted(_ highlighted: Bool) {
        guard isHighlighted != highlighted else { return }
        isHighlighted = highlighted
        updateCapAppearance()
    }

    private func updateCapAppearance() {
        capView.backgroundColor = isHighlighted ? style.pressedCapColor : style.capColor
    }

    // MARK: - Popup and accent palette

    private func schedulePalette() {
        paletteTask?.cancel()
        paletteTask = Task { @MainActor [weak self] in
            // Apple's accent palette opens after about half a second of holding.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.showPaletteIfStillHolding()
        }
    }

    private func showPaletteIfStillHolding() {
        guard isTrackingTouch, !isCancelled, paletteView == nil else { return }
        showPalette()
    }

    private func showPopup() {
        let popup = popupView ?? KeyPopupView()
        popup.configure(
            text: style.title,
            glyphColor: style.glyphColor,
            isDarkMode: style.isDarkMode
        )
        popupView = popup
        present(popup, size: CGSize(width: 46, height: 56))
    }

    private func showPalette() {
        // The base character was already typed on touch-down; take it back so
        // the accent the user picks replaces it rather than following it.
        if hasCommittedPress {
            hasCommittedPress = false
            onRetract?()
        }

        let palette = paletteView ?? KeyPaletteView()
        palette.configure(
            items: style.alternatives,
            font: style.font,
            glyphColor: style.glyphColor,
            isDarkMode: style.isDarkMode
        )
        paletteView = palette
        selectedAlternate = 0
        palette.select(index: 0)

        popupView?.removeFromSuperview()
        popupView = nil

        present(palette, size: palette.intrinsicSize)
    }

    private func present(_ overlay: UIView, size: CGSize) {
        let host = overlayHost()
        if overlay.superview !== host {
            overlay.removeFromSuperview()
            host.addSubview(overlay)
        }
        overlay.frame = overlayFrame(in: host, size: size)
    }

    private func overlayFrame(in host: UIView, size: CGSize) -> CGRect {
        let keyFrame = host.convert(bounds, from: self)
        let horizontalLimit = max(host.bounds.width - size.width - 3, 3)
        let x = min(max(keyFrame.midX - size.width / 2, 3), horizontalLimit)
        let y = max(keyFrame.minY - size.height - 6, 2)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The highest view below the window, so overlays sit above every key row.
    private func overlayHost() -> UIView {
        var root: UIView = self
        while let parent = root.superview, !(parent is UIWindow) {
            root = parent
        }
        return root
    }

    private func dismissOverlays() {
        popupView?.removeFromSuperview()
        popupView = nil
        paletteView?.removeFromSuperview()
        paletteView = nil
    }
}

// MARK: - Popup

/// The magnified key bubble Apple shows while a character key is held.
@MainActor
private final class KeyPopupView: UIView {

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false

        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30, weight: .regular)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, glyphColor: UIColor, isDarkMode: Bool) {
        label.text = text
        label.textColor = glyphColor
        backgroundColor = isDarkMode
            ? UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1)
            : .white
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}

// MARK: - Accent palette

/// The strip of accented variants Apple expands the popup into on a long press.
/// Dragging horizontally while it is open picks a variant; lifting inserts it.
@MainActor
private final class KeyPaletteView: UIView {

    private let selectionView = UIView()
    private var labels: [UILabel] = []
    private var items: [String] = []

    private let itemWidth: CGFloat = 34
    private let padding: CGFloat = 4
    private let paletteHeight: CGFloat = 52

    var intrinsicSize: CGSize {
        CGSize(
            width: padding * 2 + itemWidth * CGFloat(max(items.count, 1)),
            height: paletteHeight
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false

        selectionView.layer.cornerRadius = 8
        selectionView.layer.cornerCurve = .continuous
        selectionView.isHidden = true
        addSubview(selectionView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        items: [String],
        font: UIFont,
        glyphColor: UIColor,
        isDarkMode: Bool
    ) {
        self.items = items
        labels.forEach { $0.removeFromSuperview() }
        labels = items.map { item in
            let label = UILabel()
            label.text = item
            label.font = font
            label.textColor = glyphColor
            label.textAlignment = .center
            addSubview(label)
            return label
        }

        backgroundColor = isDarkMode
            ? UIColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1)
            : .white
        selectionView.backgroundColor = isDarkMode
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor.black.withAlphaComponent(0.10)
        selectionView.isHidden = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(
                x: padding + CGFloat(index) * itemWidth,
                y: 0,
                width: itemWidth,
                height: bounds.height
            )
        }
    }

    func select(index: Int) {
        guard index >= 0, index < items.count else {
            selectionView.isHidden = true
            return
        }
        selectionView.isHidden = false
        selectionView.frame = CGRect(
            x: padding + CGFloat(index) * itemWidth + 1,
            y: padding,
            width: itemWidth - 2,
            height: bounds.height - padding * 2
        )
    }

    func index(at point: CGPoint) -> Int {
        guard !items.isEmpty else { return -1 }
        let column = Int(((point.x - padding) / itemWidth).rounded(.down))
        return min(max(column, 0), items.count - 1)
    }
}

// MARK: - SwiftUI bridge

struct KeyboardKey: UIViewRepresentable {
    var style: KeyboardKeyStyle
    var onTouchDown: (() -> Void)?
    var onTouchEnd: (() -> Void)?
    var onTap: (() -> Void)?
    var onInsert: ((String) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onRetract: (() -> Void)?

    func makeUIView(context: Context) -> MurmurKeyCapView {
        let view = MurmurKeyCapView()
        configure(view)
        return view
    }

    func updateUIView(_ view: MurmurKeyCapView, context: Context) {
        configure(view)
    }

    /// Take whatever width the key row offers, so a key row always fills the
    /// keyboard evenly instead of collapsing to an empty intrinsic size.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MurmurKeyCapView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func configure(_ view: MurmurKeyCapView) {
        view.apply(style)
        view.onTouchDown = onTouchDown
        view.onTouchEnd = onTouchEnd
        view.onTap = onTap
        view.onInsert = onInsert
        view.onSelectionChange = onSelectionChange
        view.onRetract = onRetract
    }
}

// TrayPanel.swift
// The floating bar's surface: a glass panel under the menu bar holding one
// cell per item. Cells are the items' pictures at bar scale (or the owning
// app's icon when no picture exists), edge to edge like the bar, wrapping
// into right-aligned rows when the room runs out. The panel sizes itself
// to its cells — never to a measured strip — so there is no slack at the
// sides. Input: a press on a cell, a plain drag to reorder (it is Pelmet's
// own surface, no ⌘ needed), Esc to dismiss. What a press does is the
// controller's business.

import AppKit
import PelmetCore

@MainActor
final class TrayPanel {
    struct Cell: Equatable {
        let key: ItemID
        let image: NSImage
        /// Points at bar scale. Pictures keep the bar's own aspect; an app
        /// icon gets a bar-like cell.
        let size: CGSize
        let isPicture: Bool

        static func == (a: Cell, b: Cell) -> Bool { a.key == b.key && a.size == b.size && a.isPicture == b.isPicture && a.image === b.image }
    }

    struct Placement {
        let screen: NSScreen
        let position: FloatingBarPosition
        let scale: CGFloat
        /// Primary-band x (AX global) the section opens at — its right edge.
        let anchorX: CGFloat?
        /// Cocoa global pointer x at the trigger.
        let pointerX: CGFloat?
    }

    var onPress: ((ItemID, NSEvent) -> Void)?
    var onReorder: (([ItemID]) -> Void)?
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private let host: NSView
    private let content = TrayContentView()
    private var placement: Placement?
    private var keyMonitors: [Any] = []
    private var restFrame: NSRect = .zero

    static let cornerRadius: CGFloat = 12
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 4
    static let gapBelowBar: CGFloat = 4
    static let edgeMargin: CGFloat = 8
    /// Wrap past this share of the display's width.
    static let maxWidthShare: CGFloat = 0.6

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            host = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = Self.cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(content)
            host = effect
        }
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        panel.contentView = host
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        content.onPress = { [weak self] key, event in self?.onPress?(key, event) }
        content.onReorder = { [weak self] order in self?.onReorder?(order) }
    }

    var isShown: Bool { panel.isVisible }
    var screen: NSScreen? { placement?.screen }

    /// The tray and its approach: the band above it, the gap, a margin
    /// around it and the run to the display's trailing edge (a pointer
    /// leaving the bar by the clock is on its way here). Without this a
    /// rehide delay of zero closed the tray the moment the pointer left
    /// the band anywhere but onto the tray itself.
    func contains(_ point: NSPoint) -> Bool {
        guard panel.isVisible, let screen = placement?.screen else { return false }
        let f = panel.frame
        let margin: CGFloat = 24
        let top = screen.frame.maxY - Self.barHeight(of: screen)
        let corridor = NSRect(
            x: f.minX - margin, y: f.minY - margin,
            width: (screen.frame.maxX - f.minX) + margin, height: top - (f.minY - margin)
        )
        return corridor.contains(point)
    }

    /// The order the cells sit in right now (a drag in flight included).
    var order: [ItemID] { content.order }

    // MARK: - Show / update / hide

    func show(cells: [Cell], placement: Placement) {
        self.placement = placement
        let frame = layout(cells, placement: placement)
        restFrame = frame
        panel.setFrame(frame, display: true)
        content.setPressed(nil)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        installKeyMonitors()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced {
            content.layer?.transform = CATransform3DIdentity
            panel.alphaValue = 1
        } else {
            // Hangs down from under the bar: the content starts lifted and
            // clipped by the glass, so nothing draws over the bar itself.
            content.layer?.transform = CATransform3DMakeTranslation(0, 8, 0)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AppTiming.trayEntrance
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                content.layer?.transform = CATransform3DIdentity
            }
        }
    }

    /// The cells changed while open: the panel re-sizes in place.
    func update(cells: [Cell]) {
        guard panel.isVisible, let placement else { return }
        let frame = layout(cells, placement: placement)
        guard frame != restFrame else { return }
        restFrame = frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AppTiming.trayReflow
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func hide() {
        removeKeyMonitors()
        guard panel.isVisible else { return }
        content.cancelDrag()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let finish: @MainActor @Sendable () -> Void = { [panel] in panel.orderOut(nil); panel.alphaValue = 0 }
        if reduced {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = AppTiming.trayExit
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
            content.layer?.transform = CATransform3DMakeTranslation(0, 8, 0)
        }, completionHandler: {
            // AppKit calls this on the main thread but does not say so.
            Task { @MainActor in finish() }
        })
    }

    func setPressed(_ key: ItemID?) { content.setPressed(key) }

    // MARK: - Geometry

    /// The bar's own height on `screen`: the visibleFrame band, falling
    /// back to the safe area under a full-screen app.
    static func barHeight(of screen: NSScreen) -> CGFloat {
        let safeBand = screen.safeAreaInsets.top
        let visibleBand = screen.frame.maxY - screen.visibleFrame.maxY
        let band = visibleBand > 0 && (safeBand == 0 || visibleBand <= safeBand + 2) ? visibleBand : safeBand
        return band > 0 ? band : 24
    }

    /// Lays the cells out and returns the panel's frame on the display.
    private func layout(_ cells: [Cell], placement: Placement) -> NSRect {
        let screen = placement.screen
        let cellHeight = (Self.barHeight(of: screen) * placement.scale).rounded()
        let maxWidth = max(200, (screen.frame.width * Self.maxWidthShare).rounded()) - 2 * Self.insetX
        content.contentInset = NSPoint(x: Self.insetX, y: Self.insetY)
        let size = content.lay(cells, cellHeight: cellHeight, maxRowWidth: maxWidth)
        let width = size.width + 2 * Self.insetX
        let height = size.height + 2 * Self.insetY

        var right: CGFloat
        switch placement.position {
        case .underSection:
            if let anchorX = placement.anchorX, let primary = NSScreen.screens.first {
                right = anchorX + (screen.frame.maxX - primary.frame.maxX)
            } else {
                right = screen.frame.maxX - Self.edgeMargin
            }
        case .underPointer:
            right = (placement.pointerX ?? screen.frame.midX) + width / 2
        case .trailing:
            right = screen.frame.maxX - Self.edgeMargin
        case .centered:
            right = screen.frame.midX + width / 2
        }
        right = min(right, screen.frame.maxX - Self.edgeMargin)
        let left = max(right - width, screen.frame.minX + Self.edgeMargin)
        let top = screen.frame.maxY - Self.barHeight(of: screen) - Self.gapBelowBar
        return NSRect(x: left.rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }

    // MARK: - Keys

    private func installKeyMonitors() {
        removeKeyMonitors()
        let handle: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            Task { @MainActor in self?.onDismiss?() }
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handle($0) }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0) ? nil : $0 }) {
            keyMonitors.append(local)
        }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors = []
    }
}

// MARK: - Content

/// The cells, their layout, the pressed highlight and the reorder drag.
@MainActor
private final class TrayContentView: NSView {
    var onPress: ((ItemID, NSEvent) -> Void)?
    var onReorder: (([ItemID]) -> Void)?
    var contentInset = NSPoint(x: 0, y: 0)

    private var cells: [TrayPanel.Cell] = []
    private var views: [ItemID: TrayCellView] = [:]
    /// Cell frames in content coordinates (origin at the inset).
    private var slots: [ItemID: NSRect] = [:]
    private var rowWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0
    private(set) var order: [ItemID] = []

    // Drag state
    private var pressed: ItemID?
    private var pressPoint: NSPoint = .zero
    private var lifted: ItemID?
    private var liftOffset: NSPoint = .zero
    private var dragOrder: [ItemID] = []

    static let rowGap: CGFloat = 4
    static let dragThreshold: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Rows of cells, right-aligned, first row on top. Returns the content
    /// size without the inset.
    func lay(_ cells: [TrayPanel.Cell], cellHeight: CGFloat, maxRowWidth: CGFloat, place: Bool = true) -> NSSize {
        self.cells = cells
        self.cellHeight = cellHeight
        order = cells.map(\.key)
        // Views: keep the ones still here, drop the rest.
        let keys = Set(order)
        for (key, view) in views where !keys.contains(key) {
            view.removeFromSuperview()
            views[key] = nil
        }
        for cell in cells {
            let view = views[cell.key] ?? {
                let v = TrayCellView()
                addSubview(v)
                views[cell.key] = v
                return v
            }()
            view.set(cell, height: cellHeight)
        }
        // Widths at this height.
        var widths: [ItemID: CGFloat] = [:]
        for cell in cells { widths[cell.key] = Self.width(of: cell, height: cellHeight) }
        // Break into rows.
        var rows: [[ItemID]] = [[]]
        var rowW: CGFloat = 0
        for key in order {
            let w = widths[key] ?? 0
            if rowW > 0, rowW + w > maxRowWidth {
                rows.append([])
                rowW = 0
            }
            rows[rows.count - 1].append(key)
            rowW += w
        }
        rowWidth = rows.map { $0.reduce(0) { $0 + (widths[$1] ?? 0) } }.max() ?? 0
        var y: CGFloat = 0
        slots = [:]
        for row in rows {
            let w = row.reduce(0) { $0 + (widths[$1] ?? 0) }
            var x = rowWidth - w
            for key in row {
                let cw = widths[key] ?? 0
                slots[key] = NSRect(x: x, y: y, width: cw, height: cellHeight)
                x += cw
            }
            y += cellHeight + Self.rowGap
        }
        let height = y - Self.rowGap
        if place { self.place(animated: false) }
        return NSSize(width: rowWidth, height: max(height, cellHeight))
    }

    static func width(of cell: TrayPanel.Cell, height: CGFloat) -> CGFloat {
        guard cell.isPicture, cell.size.height > 0 else { return (height * 0.8).rounded() }
        return (cell.size.width * height / cell.size.height).rounded()
    }

    private func place(animated: Bool) {
        for (key, slot) in slots {
            guard let view = views[key], key != lifted else { continue }
            let frame = slot.offsetBy(dx: contentInset.x, dy: contentInset.y)
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = AppTiming.trayReflow
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                    view.animator().frame = frame
                }
            } else {
                view.frame = frame
            }
        }
    }

    override func layout() {
        super.layout()
        if lifted == nil { place(animated: false) }
    }

    func setPressed(_ key: ItemID?) {
        for (k, view) in views { view.pressed = (k == key) }
    }

    // MARK: Mouse

    private func cell(at point: NSPoint) -> ItemID? {
        for (key, slot) in slots where slot.offsetBy(dx: contentInset.x, dy: contentInset.y).contains(point) { return key }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = cell(at: point)
        pressPoint = point
        setPressed(pressed)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let key = cell(at: point) else { return }
        onPress?(key, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, let view = views[pressed] else { return }
        let point = convert(event.locationInWindow, from: nil)
        if lifted == nil {
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > Self.dragThreshold else { return }
            lifted = pressed
            dragOrder = order
            liftOffset = NSPoint(x: pressPoint.x - view.frame.minX, y: pressPoint.y - view.frame.minY)
            view.lifted = true
            view.layer?.zPosition = 10
        }
        view.frame.origin = NSPoint(x: point.x - liftOffset.x, y: point.y - liftOffset.y)
        // Insertion: the slot whose midpoint the pointer has crossed, in
        // the row under the pointer.
        let others = dragOrder.filter { $0 != pressed }
        var index = others.count
        for (i, key) in others.enumerated() {
            guard let slot = slots[key] else { continue }
            let frame = slot.offsetBy(dx: contentInset.x, dy: contentInset.y)
            let sameRow = abs(frame.midY - point.y) <= cellHeight
            if sameRow, point.x < frame.midX { index = i; break }
            if frame.midY - point.y > cellHeight { index = i; break }
        }
        var next = others
        next.insert(pressed, at: index)
        guard next != dragOrder else { return }
        dragOrder = next
        reslot(dragOrder)
        place(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed else { return }
        if let lifted, let view = views[lifted] {
            self.lifted = nil
            view.lifted = false
            view.layer?.zPosition = 0
            setPressed(nil)
            let changed = dragOrder != order
            order = dragOrder
            place(animated: true)
            if changed { onReorder?(order) }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard cell(at: point) == pressed else { setPressed(nil); return }
        onPress?(pressed, event)
    }

    func cancelDrag() {
        guard let lifted, let view = views[lifted] else { return }
        self.lifted = nil
        view.lifted = false
        view.layer?.zPosition = 0
        setPressed(nil)
        pressed = nil
        reslot(order)
        place(animated: false)
    }

    /// Re-run the slots for a new order without changing rows' shape more
    /// than the widths force.
    private func reslot(_ newOrder: [ItemID]) {
        let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.key, $0) })
        let ordered = newOrder.compactMap { byKey[$0] }
        let keepOrder = order
        let keepInset = contentInset
        _ = lay(ordered, cellHeight: cellHeight, maxRowWidth: rowWidth + 0.5, place: false)
        order = keepOrder
        contentInset = keepInset
    }
}

/// One cell: the picture (or app icon) and the pressed highlight, the bar's
/// own rounded rectangle.
@MainActor
private final class TrayCellView: NSView {
    private let image = NSImageView()
    private let highlight = NSView()
    private var isPicture = true

    var pressed = false { didSet { highlight.isHidden = !pressed && !lifted } }
    var lifted = false { didSet { highlight.isHidden = !pressed && !lifted; alphaValue = lifted ? 0.9 : 1 } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 5
        highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        addSubview(image)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private var sizeConstraints: [NSLayoutConstraint] = []

    func set(_ cell: TrayPanel.Cell, height: CGFloat) {
        isPicture = cell.isPicture
        image.image = cell.image
        NSLayoutConstraint.deactivate(sizeConstraints)
        if cell.isPicture {
            sizeConstraints = [
                image.leadingAnchor.constraint(equalTo: leadingAnchor),
                image.trailingAnchor.constraint(equalTo: trailingAnchor),
                image.topAnchor.constraint(equalTo: topAnchor),
                image.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            let side = (height * 0.55).rounded()
            sizeConstraints = [
                image.widthAnchor.constraint(equalToConstant: side),
                image.heightAnchor.constraint(equalToConstant: side),
            ]
        }
        NSLayoutConstraint.activate(sizeConstraints)
    }

    override func updateLayer() {
        highlight.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }
}

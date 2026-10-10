// PanelView.swift
// The panel's tiles (docs/PANEL-PLAN.md §2): what `PanelModel` says, laid out
// by `PanelGrid`, dressed as the design mock (pelmet-site
// marketing/panel-mock). Sections stack top down; a tile is a soft well with
// the icon as the bar draws it. Everything it shows is handed in, so the
// presenter owns the state and the Settings preview can draw the same view.

import AppKit
import PelmetCore
import SwiftUI

/// What one tile draws.
struct PanelTileArt {
    enum Image {
        /// Cut from the bar (ItemPictures); one-colour glyphs are tinted.
        case picture(CGImage, size: CGSize, monochrome: Bool)
        /// The stand-in until a picture lands: the app's icon or a symbol.
        case icon(NSImage)
    }

    let image: Image
    let name: String
    /// A launcher: the app isn't running, a click opens it.
    var dimmed = false
}

/// One stacked block of the panel.
struct PanelBlock: Identifiable {
    let kind: PanelSection.Kind
    let grid: PanelGrid
    /// Icons you can click, for the header and the fold.
    let count: Int
    let showsHeader: Bool
    /// Always Hidden only: its fold is drawn, and the grid when open.
    let foldable: Bool
    let isFolded: Bool

    var id: PanelSection.Kind { kind }
}

struct PanelContent {
    var blocks: [PanelBlock] = []
    var layout: PanelGrid.Layout = .panel
    var art: [PanelTile: PanelTileArt] = [:]
    /// The widest grid: headers, the search field and the fold span it.
    var width: CGFloat = 44
    /// What the keyboard typed: the search row shows while it isn't empty.
    var query = ""
    /// The tile Return opens and the arrows move.
    var selected: PanelTile?
    /// While the left edge is dragged: "4 per row", "Auto".
    var columnsTip: String?
    /// Always Hidden has icons this panel can show, drawn or not: the row
    /// draws no fold, its right-click menu opens it.
    var hasAlwaysHidden = false
    /// Always Hidden's tiles are on screen: unfolded in the panel, part of
    /// the row.
    var showsAlwaysHidden = false
    /// The Animation setting, which Always Hidden's fold follows (Reduce
    /// Motion turns Smooth into Fade).
    var motion: RevealAnimation = .instant
    /// What opens Always Hidden. The tile is a cell of the grid above it
    /// (`PanelTile.fold`); the count and the handle are the section's own.
    var fold: PanelOptions.AlwaysHiddenFold = .tile
    /// Nothing is hidden, or nothing matches: the panel says so instead of
    /// showing nothing.
    var isEmpty: Bool { blocks.allSatisfy { $0.count == 0 } }
}

/// A right-click menu row, built by the presenter.
enum PanelMenuRow {
    case action(String, () -> Void)
    case check(String, Bool, enabled: Bool = true, () -> Void)
    case header(String)
    case divider
}

struct PanelView: View {
    let content: PanelContent
    let onPress: (PanelTile) -> Void
    let onFold: () -> Void
    var tileMenu: (PanelTile) -> [PanelMenuRow] = { _ in [] }
    var panelMenu: () -> [PanelMenuRow] = { [] }
    /// The left edge sets the columns: dragged (the pointer's x in the
    /// window, true when let go), and double-clicked for Auto.
    var onColumnsDrag: (_ x: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var onColumnsReset: () -> Void = {}

    @State private var hovering = false

    @Environment(\.colorScheme) private var scheme

    private var padding: CGFloat {
        PanelMetrics.standard(layout: content.layout, showsNames: false).padding
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if !content.query.isEmpty {
                searchRow
            }
            if content.isEmpty {
                if content.query.isEmpty { empty } else { noMatch }
            } else if content.layout == .row {
                HStack(spacing: 0) {
                    ForEach(content.blocks) { block in
                        grid(block.grid)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
                        section(block, first: index == 0)
                    }
                }
            }
        }
        .padding(padding)
        .fixedSize()
        .overlay(alignment: .leading) {
            if content.layout == .panel, !content.isEmpty {
                ColumnGrip(ink: ink, panelHovered: hovering, tip: content.columnsTip,
                           onDrag: onColumnsDrag, onReset: onColumnsReset)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menu(panelMenu()) }
    }

    @ViewBuilder
    private func menu(_ rows: [PanelMenuRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .action(let title, let run):
                Button(title, action: run)
            case .check(let title, let on, let enabled, let run):
                Toggle(title, isOn: Binding(get: { on }, set: { _ in run() }))
                    .disabled(!enabled)
            case .header(let title):
                Text(title)
            case .divider:
                Divider()
            }
        }
    }

    @ViewBuilder
    private func section(_ block: PanelBlock, first: Bool) -> some View {
        if block.foldable {
            // A search shows the matches, no fold.
            let fold: PanelOptions.AlwaysHiddenFold? = content.query.isEmpty ? content.fold : nil
            VStack(alignment: .trailing, spacing: 0) {
                if fold == .count {
                    countFold(block)
                        .padding(.top, first ? 0 : 6)
                }
                foldedTiles(block, gap: fold == .count ? 6 : first ? 0 : 10)
                if fold == .handle {
                    handleFold(block)
                }
            }
            // The bar's own motion for the style: Smooth slides the tiles
            // out from under the icons above, Fade fades them in place.
            .animation(MockBar.animation(content.motion, revealed: !block.isFolded), value: block.isFolded)
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                if block.showsHeader {
                    header(block)
                }
                grid(block.grid)
            }
            // The mock's gap under Didn't fit; Hidden runs into the fold,
            // which brings its own.
            .padding(.bottom, block.kind == .didntFit ? 10 : 0)
        }
    }

    @ViewBuilder
    private func foldedTiles(_ block: PanelBlock, gap: CGFloat) -> some View {
        let tiles = VStack(spacing: 0) {
            if !block.isFolded {
                grid(block.grid)
                    .padding(.top, gap)
                    .transition(content.motion == .smooth ? .move(edge: .top) : .opacity)
            }
        }
        // As wide folded as open: the slide's clip grows down only, never in
        // from the trailing edge.
        .frame(width: content.width, alignment: .trailing)
        // Clipped for the slide only: a fade-out keeps its tiles in place
        // while the space under them closes.
        if content.motion == .smooth { tiles.clipped() } else { tiles }
    }

    private func header(_ block: PanelBlock) -> some View {
        HStack(spacing: 6) {
            Text(title(of: block.kind))
                .foregroundStyle(ink.secondary)
            if block.kind == .didntFit {
                Text(block.count, format: .number)
                    .foregroundStyle(ink.tertiary)
                    .fontWeight(.regular)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        // At least the grid's width; a long name in a narrow panel widens it.
        .frame(minWidth: content.width)
        .help(block.kind == .didntFit ? String(localized: "macOS had no room for these in the menu bar") : "")
    }

    /// The count fold: how many are behind it, a chevron that turns.
    private func countFold(_ block: PanelBlock) -> some View {
        Button(action: onFold) {
            HStack(spacing: 3) {
                Text(block.count, format: .number)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(block.isFolded ? 0 : 180))
                    // Turns in every style, a disclosure's own cue.
                    .animation(.easeOut(duration: 0.2), value: block.isFolded)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(FoldFillStyle(ink: ink, shape: Capsule(), resting: ink.well))
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(block.count, format: .number))
        .frame(width: content.width)
    }

    /// The handle fold: a grabber along the bottom edge, under the tiles
    /// when they are out.
    private func handleFold(_ block: PanelBlock) -> some View {
        Button(action: onFold) {
            Capsule()
                .fill(ink.tertiary)
                .frame(width: 28, height: 4)
                .frame(width: content.width, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(FoldFillStyle(ink: ink, shape: RoundedRectangle(cornerRadius: 7, style: .continuous), resting: .clear))
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(block.count, format: .number))
        .padding(.top, 4)
        // Half into the panel's padding: a grabber sits on the edge.
        .padding(.bottom, -5)
    }

    /// The tile fold: how many are behind it, a chevron once they are out.
    private func foldTile(at placement: PanelGrid.Placement, in grid: PanelGrid) -> some View {
        let always = content.blocks.first { $0.kind == .alwaysHidden }
        let count = always?.count ?? 0
        return Button(action: onFold) {
            FoldTileLabel(count: count, open: always.map { !$0.isFolded } ?? false,
                          title: title(of: .alwaysHidden), grid: grid, ink: ink)
        }
        .buttonStyle(PanelTileStyle(grid: grid, ink: ink, selected: content.selected == .fold))
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(content.selected == .fold ? .isSelected : [])
        .offset(x: placement.frame.minX, y: placement.frame.minY)
    }

    /// The mock's search field, drawn: the panel's own key monitor types
    /// into it.
    private var searchRow: some View {
        let row = content.layout == .row
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink.tertiary)
            HStack(spacing: 0) {
                Text(content.query)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Caret()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(width: content.width, height: row ? 28 : 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ink.well))
        .padding(.bottom, row ? 5 : 10)
    }

    private var noMatch: some View {
        Text("No results")
            .font(.system(size: 12))
            .foregroundStyle(ink.secondary)
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
            .frame(width: content.width, alignment: .leading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing hidden")
                .font(.system(size: 12))
                .foregroundStyle(ink.secondary)
            Text("⌘-drag an icon left of ‹ to hide it.")
                .font(.system(size: 11))
                .foregroundStyle(ink.tertiary)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
        .frame(minWidth: 150, alignment: .leading)
    }

    private func grid(_ grid: PanelGrid) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(grid.rows.joined()), id: \.tile) { placement in
                if placement.tile == .fold {
                    foldTile(at: placement, in: grid)
                } else if let art = content.art[placement.tile] {
                    Button { onPress(placement.tile) } label: {
                        PanelTileLabel(art: art, grid: grid, ink: ink)
                    }
                    .buttonStyle(PanelTileStyle(grid: grid, ink: ink, selected: content.selected == placement.tile))
                    // The arrow keys have their own selection; the system's
                    // blue ring is not it.
                    .focusEffectDisabled()
                    .help(art.dimmed ? "\(art.name)\n\(String(localized: "Not running"))" : art.name)
                    .contextMenu { menu(tileMenu(placement.tile)) }
                    // Names even with names off; a launcher says it isn't running.
                    .accessibilityLabel(art.name)
                    .accessibilityValue(art.dimmed ? String(localized: "Not running") : "")
                    .accessibilityAddTraits(content.selected == placement.tile ? .isSelected : [])
                    .offset(x: placement.frame.minX, y: placement.frame.minY)
                }
            }
            ForEach(Array(grid.dividers.enumerated()), id: \.offset) { _, divider in
                Capsule()
                    .fill(ink.tertiary)
                    .frame(width: 1, height: divider.height * 0.5)
                    .frame(width: divider.width, height: divider.height)
                    .offset(x: divider.minX, y: divider.minY)
            }
        }
        .frame(width: grid.contentSize.width, height: grid.contentSize.height, alignment: .topLeading)
    }

    private func title(of kind: PanelSection.Kind) -> String {
        switch kind {
        case .didntFit: String(localized: "Didn’t fit")
        case .hidden: String(localized: "Hidden")
        case .alwaysHidden: String(localized: "Always Hidden")
        }
    }

    private var ink: PanelInk { PanelInk(scheme: scheme) }
}

/// The mock's colours: white on dark glass, black on light, at a few
/// strengths.
struct PanelInk {
    let scheme: ColorScheme

    private var base: Color { scheme == .dark ? .white : .black }
    var primary: Color { base.opacity(scheme == .dark ? 0.92 : 0.86) }
    var secondary: Color { base.opacity(scheme == .dark ? 0.64 : 0.6) }
    var tertiary: Color { base.opacity(scheme == .dark ? 0.40 : 0.36) }
    var well: Color { base.opacity(scheme == .dark ? 0.075 : 0.05) }
    var wellHover: Color { base.opacity(scheme == .dark ? 0.13 : 0.085) }
    var wellPress: Color { base.opacity(scheme == .dark ? 0.2 : 0.13) }
}

private struct PanelTileLabel: View {
    let art: PanelTileArt
    let grid: PanelGrid
    let ink: PanelInk

    var body: some View {
        let metrics = grid.metrics
        VStack(spacing: metrics.labelGap) {
            glyph
                .frame(width: metrics.wellSize.width, height: metrics.wellSize.height)
            if grid.showsNames {
                Text(art.name)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.tileSize.width, height: metrics.labelHeight)
            }
        }
        .frame(width: metrics.tileSize.width, height: metrics.tileSize.height, alignment: .top)
        .contentShape(Rectangle())
    }

    private var glyph: some View {
        image.opacity(art.dimmed ? 0.35 : 1)
    }

    @ViewBuilder
    private var image: some View {
        let room = CGSize(width: grid.metrics.wellSize.width - 6, height: grid.metrics.wellSize.height - 6)
        switch art.image {
        case .picture(let image, let size, let monochrome):
            // The bar's own size, pulled in only when it can't fit (a wide
            // text item in a 44pt well).
            let fit = min(1, room.width / max(size.width, 1), room.height / max(size.height, 1))
            let picture = Image(decorative: image, scale: CGFloat(image.width) / max(size.width, 1))
            if monochrome {
                picture
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(ink.primary)
                    .frame(width: size.width * fit, height: size.height * fit)
            } else {
                picture
                    .resizable()
                    .frame(width: size.width * fit, height: size.height * fit)
            }
        case .icon(let icon):
            let side = min(icon.isTemplate ? 16 : 20, room.height)
            Image(nsImage: icon)
                .renderingMode(icon.isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(ink.primary)
                .frame(width: side, height: side)
        }
    }
}

private struct PanelTileStyle: ButtonStyle {
    let grid: PanelGrid
    let ink: PanelInk
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Well(configuration: configuration, grid: grid, ink: ink, selected: selected)
    }

    /// A view of its own so the hover can be state.
    private struct Well: View {
        let configuration: Configuration
        let grid: PanelGrid
        let ink: PanelInk
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            let metrics = grid.metrics
            let row = grid.layout == .row
            configuration.label
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: row ? 8 : 13, style: .continuous)
                        .fill(configuration.isPressed ? ink.wellPress : hovering || selected ? ink.wellHover : row ? .clear : ink.well)
                        .frame(width: metrics.wellSize.width, height: metrics.wellSize.height)
                        .scaleEffect(configuration.isPressed ? 0.94 : 1)
                        // On the well alone: on the whole tile, a hover that
                        // changed with a re-layout slid the tile (2026-10-09).
                        .animation(.easeOut(duration: 0.12), value: hovering)
                        .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
                }
                .onHover { hovering = $0 }
        }
    }
}

/// The count and the handle: a fill that comes up on hover and press.
private struct FoldFillStyle<S: Shape>: ButtonStyle {
    let ink: PanelInk
    let shape: S
    let resting: Color

    func makeBody(configuration: Configuration) -> some View {
        Fill(configuration: configuration, ink: ink, shape: shape, resting: resting)
    }

    private struct Fill: View {
        let configuration: Configuration
        let ink: PanelInk
        let shape: S
        let resting: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    shape
                        .fill(configuration.isPressed ? ink.wellPress : hovering ? ink.wellHover : resting)
                        // The fill only: on the control, the hover the click
                        // changed animated the fold's re-layout as a slide.
                        .animation(.easeOut(duration: 0.12), value: hovering))
                .onHover { hovering = $0 }
        }
    }
}

/// The tile fold's face: "+10" folded, a chevron to close it once open.
/// With names on it is named like any tile.
private struct FoldTileLabel: View {
    let count: Int
    let open: Bool
    let title: String
    let grid: PanelGrid
    let ink: PanelInk

    var body: some View {
        let metrics = grid.metrics
        VStack(spacing: metrics.labelGap) {
            ZStack {
                if open {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity)
                } else {
                    Text(verbatim: "+\(count)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(ink.secondary)
            .animation(.easeOut(duration: 0.15), value: open)
            .frame(width: metrics.wellSize.width, height: metrics.wellSize.height)
            if grid.showsNames {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.tileSize.width, height: metrics.labelHeight)
            }
        }
        .frame(width: metrics.tileSize.width, height: metrics.tileSize.height, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// The search row's insertion point, blinking as the mock's does.
private struct Caret: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5, height: 15)
            .opacity(on ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    on.toggle()
                }
            }
    }
}

/// The panel's left edge: drag it for more or fewer columns, double-click
/// it for Auto (the mock's grip).
private struct ColumnGrip: View {
    let ink: PanelInk
    let panelHovered: Bool
    let tip: String?
    let onDrag: (_ x: CGFloat, _ ended: Bool) -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 12)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(hovering || dragging ? ink.secondary : ink.tertiary)
                        .frame(width: 4, height: 26)
                        .padding(.leading, 4)
                        .opacity(hovering || dragging ? 1 : panelHovered ? 0.55 : 0)
                        .animation(.easeOut(duration: 0.15), value: hovering || dragging || panelHovered)
                }
                .onHover { hovering = $0 }
                .pointerStyle(.columnResize)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            dragging = true
                            onDrag(value.location.x, false)
                        }
                        .onEnded { value in
                            dragging = false
                            onDrag(value.location.x, true)
                        })
                .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
            if let tip {
                Text(tip)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

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
    /// Tiles you can click, for the header and the fold row.
    let count: Int
    let showsHeader: Bool
    /// Always Hidden only: the fold row is drawn, and the grid when open.
    let foldable: Bool
    let isFolded: Bool

    var id: PanelSection.Kind { kind }
}

struct PanelContent {
    var blocks: [PanelBlock] = []
    var layout: PanelGrid.Layout = .panel
    var art: [PanelTile: PanelTileArt] = [:]
    /// The widest grid, at least the mock's 150: headers and the fold row
    /// span it.
    var width: CGFloat = 150
    /// What the keyboard typed: the search row shows while it isn't empty.
    var query = ""
    /// The tile Return opens and the arrows move.
    var selected: PanelTile?
    /// Nothing is hidden, or nothing matches: the panel says so instead of
    /// showing nothing.
    var isEmpty: Bool { blocks.allSatisfy { $0.count == 0 } }
}

struct PanelView: View {
    let content: PanelContent
    let onPress: (PanelTile) -> Void
    let onFold: () -> Void

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
    }

    @ViewBuilder
    private func section(_ block: PanelBlock, first: Bool) -> some View {
        if block.foldable {
            foldRow(block, first: first)
            if !block.isFolded {
                grid(block.grid).padding(.top, 8)
            }
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                if block.showsHeader {
                    header(block)
                }
                grid(block.grid)
            }
            // The mock's gap under Didn't fit; Hidden runs into the fold row,
            // which brings its own.
            .padding(.bottom, block.kind == .didntFit ? 10 : 0)
        }
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
        .frame(width: content.width)
        .help(block.kind == .didntFit ? String(localized: "macOS had no room for these in the menu bar") : "")
    }

    private func foldRow(_ block: PanelBlock, first: Bool) -> some View {
        Button(action: onFold) {
            HStack(spacing: 6) {
                Text(title(of: .alwaysHidden))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.secondary)
                Text(block.count, format: .number)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(ink.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.tertiary)
                    .rotationEffect(.degrees(block.isFolded ? 0 : 90))
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(width: content.width, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(FoldRowStyle(ink: ink))
        .focusEffectDisabled()
        .padding(.top, first ? 0 : 8)
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
                if let art = content.art[placement.tile] {
                    Button { onPress(placement.tile) } label: {
                        PanelTileLabel(art: art, grid: grid, ink: ink)
                    }
                    .buttonStyle(PanelTileStyle(grid: grid, ink: ink, selected: content.selected == placement.tile))
                    // The arrow keys have their own selection; the system's
                    // blue ring is not it.
                    .focusEffectDisabled()
                    .help(art.dimmed ? "\(art.name)\n\(String(localized: "Not running"))" : art.name)
                    .accessibilityLabel(art.name)
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
                }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
        }
    }
}

private struct FoldRowStyle: ButtonStyle {
    let ink: PanelInk

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, ink: ink)
    }

    private struct Row: View {
        let configuration: Configuration
        let ink: PanelInk
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(configuration.isPressed ? ink.wellHover : hovering ? ink.well : .clear))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
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

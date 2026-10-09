// CommandBarView.swift
// The command bar's content: the field, and under it the rows. Borderless by
// design: the glass is the only edge, a selected row is a soft fill, and the
// quiet parts (app name, matched synonym, ↩) stay in secondary and tertiary
// ink so the eye lands on the names.

import AppKit
import SwiftUI

enum CommandBarLayout {
    static let width: CGFloat = 440
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 34
    static let listGap: CGFloat = 4
    static let maxRows = 8

    static func listHeight(rows: Int) -> CGFloat {
        CGFloat(min(rows, maxRows)) * rowHeight
    }

    /// The tallest the list gets: the full results, or an input row with its
    /// two lines under it. The panel's window is this tall for as long as it
    /// is open, and only the glass in it changes height.
    static var tallestListHeight: CGFloat { max(listHeight(rows: maxRows), inputListHeight) }

    /// The input row of Set Shortcut / Alias and the two lines under it that
    /// say what to press, or why that did not take.
    static let inputListHeight: CGFloat = rowHeight + 40

    /// The panel's height for a list `listHeight` tall, field only when 0.
    static func panelHeight(listHeight: CGFloat) -> CGFloat {
        2 * padding + headerHeight + (listHeight > 0 ? listGap + listHeight : 0)
    }

    /// The panel's height for `rows` rows (a "no results" line counts as
    /// one), field only when there are none.
    static func panelHeight(rows: Int) -> CGFloat {
        panelHeight(listHeight: rows > 0 ? listHeight(rows: rows) : 0)
    }
}

struct CommandBarRow: Identifiable {
    enum Glyph {
        case image(NSImage)
        case symbol(String)
    }

    /// The candidate's id.
    let id: String
    let title: String
    /// Matched runs in the title (Character offsets), drawn semibold.
    let titleRanges: [Range<Int>]
    let subtitle: String?
    let glyph: Glyph
    /// "bt → Bluetooth": which of the row's other words matched.
    let synonymTag: String?
    /// "Hidden" / "Always Hidden".
    let sectionTag: String?
    /// Keys or values at the trailing edge, in tertiary ink: an item's own
    /// shortcut, or the key that runs an action.
    var trailing: String?
    let accessibilityLabel: String
}

/// The row ⌘K was pressed on, worn in the field as a quiet chip while its
/// actions are showing.
struct CommandBarChip {
    let glyph: CommandBarRow.Glyph
    let title: String
}

/// The two actions that ask for something instead of doing it.
enum CommandBarInput {
    case shortcut, alias
}

@MainActor @Observable
final class CommandBarModel {
    var query = ""
    var rows: [CommandBarRow] = []
    var selected = 0
    /// What the top row would add after the caret.
    var completion: String?
    var showsNoResults = false
    /// Bumped per ranking, so the list returns to its top on new results.
    var resultsVersion = 0
    /// False while the panel is closed, true once drawn in: the 4pt drop of
    /// the entrance is this flipping under an animation.
    var entered = false
    var dropOffset: CGFloat = 4

    /// Set while an item's actions are showing in place of the results.
    var chip: CommandBarChip?
    var placeholder = String(localized: "Search the menu bar")
    /// Set while Set Shortcut / Alias is taking input.
    var input: CommandBarInput?
    var inputTitle = ""
    var inputCaption = ""
    /// Why the last shortcut was refused, in place of the caption.
    var inputMessage: String?
    /// What the alias field starts with: the alias as it is now.
    var aliasDraft = ""
    /// The search field has keyboard focus. Settings › Search's demo shows
    /// no selected row without it: nothing there takes ↩ yet.
    var fieldFocused = false
    var hidesSelectionUnfocused = false
    /// Run when the search field takes focus.
    @ObservationIgnored var onFieldFocus: (() -> Void)?

    @ObservationIgnored weak var field: CommandBarFieldView?
    @ObservationIgnored weak var aliasField: CommandBarFieldView?
}

struct CommandBarView: View {
    let model: CommandBarModel
    let onQueryChange: (String) -> Void
    /// A row picked by click; the modifiers are the click's (⌘ = show in
    /// the bar, as with Return).
    let onChoose: (Int, NSEvent.ModifierFlags) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let input = model.input {
                inputRow(input)
            } else if !model.rows.isEmpty {
                list
            } else if model.showsNoResults {
                noResults
            }
        }
        .padding(CommandBarLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(y: model.entered ? 0 : -model.dropOffset)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let chip = model.chip {
                CommandBarChipView(chip: chip)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            // The field stays in the tree under Set Shortcut / Alias (its
            // text and focus live in it); the input's own title stands over it.
            ZStack(alignment: .leading) {
                CommandBarSearchField(model: model, onChange: onQueryChange)
                    .frame(height: 24)
                    .opacity(model.input == nil ? 1 : 0)
                    .allowsHitTesting(model.input == nil)
                if model.input != nil {
                    Text(model.inputTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarLayout.headerHeight)
    }

    /// One row that is the input itself (the recording chip, or the alias
    /// field), with what to press under it.
    private func inputRow(_ input: CommandBarInput) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: input == .shortcut ? "keyboard" : "tag")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                switch input {
                case .shortcut:
                    Text("Type shortcut…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .labelColor).opacity(0.07)))
                        .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                case .alias:
                    CommandBarAliasField(model: model)
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: CommandBarLayout.rowHeight)
            Text(model.inputMessage ?? model.inputCaption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                .accessibilityLabel(model.inputMessage ?? model.inputCaption)
        }
        .padding(.top, CommandBarLayout.listGap)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Lazy: up to 20 results, only the 8 in view draw. A row is
                // its place in the list, not its item: a new ranking updates
                // the rows in place instead of building new ones, which is
                // a third of what a keystroke cost to draw (2026-10-04).
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        CommandBarRowView(row: row, selected: index == model.selected
                                          && (model.fieldFocused || !model.hidesSelectionUnfocused)) {
                            onChoose(index, NSEvent.modifierFlags)
                        }
                        .id(index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: CommandBarLayout.listHeight(rows: model.rows.count))
            .onChange(of: model.selected) { _, selected in
                guard model.rows.indices.contains(selected) else { return }
                proxy.scrollTo(selected)
            }
            .onChange(of: model.resultsVersion) {
                if !model.rows.isEmpty { proxy.scrollTo(0, anchor: .top) }
            }
        }
        .padding(.top, CommandBarLayout.listGap)
    }

    private var noResults: some View {
        Text("No results")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: CommandBarLayout.rowHeight)
            .padding(.top, CommandBarLayout.listGap)
    }
}

private struct CommandBarRowView: View {
    let row: CommandBarRow
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            glyph
                .frame(width: 18, height: 18)
            Text(styledTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(2)
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(0)
            }
            Spacer(minLength: 6)
            if let tag = row.synonymTag {
                Text(tag)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let tag = row.sectionTag {
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .labelColor).opacity(0.07)))
                    .fixedSize()
                    .layoutPriority(3)
            }
            if let trailing = row.trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 12))
                    .kerning(0.5)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(3)
            } else {
                // Always laid out, so a row does not shift when it is selected.
                Text(verbatim: "↩")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .opacity(selected ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CommandBarLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .labelColor).opacity(selected ? 0.1 : hovered ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, choose)
    }

    private var glyph: some View {
        RowGlyph(glyph: row.glyph)
    }

    /// The title with what the query matched in semibold.
    private var styledTitle: AttributedString {
        var text = AttributedString(row.title)
        let count = text.characters.count
        for range in row.titleRanges where range.upperBound <= count && !range.isEmpty {
            let start = text.characters.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.characters.index(text.startIndex, offsetBy: range.upperBound)
            text[start..<end].font = .system(size: 13, weight: .semibold)
        }
        return text
    }
}

/// Row glyphs as small bitmaps. An app icon is an image of many
/// representations that SwiftUI picks from and resamples on each render; a
/// bitmap at the glyph's size is a plain blit. Made when a row first draws
/// and kept, for the images that outlive an open (the item icons).
/// A row's glyph as the command bar draws it. Settings › Search lists the
/// same icons with it.
struct RowGlyph: View {
    let glyph: CommandBarRow.Glyph

    var body: some View {
        switch glyph {
        case .image(let image):
            Image(nsImage: RowGlyphCache.bitmap(for: image))
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum RowGlyphCache {
    static let side: CGFloat = 18
    private static var bitmaps: [ObjectIdentifier: (source: NSImage, bitmap: NSImage)] = [:]
    private static let capacity = 96

    static func bitmap(for image: NSImage) -> NSImage {
        let key = ObjectIdentifier(image)
        // The source is kept with its bitmap: an identifier of a freed image
        // could be handed to another.
        if let hit = bitmaps[key], hit.source === image { return hit.bitmap }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pixels = Int((side * scale).rounded())
        guard image.size.width > 0, image.size.height > 0, pixels > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return image }
        // Fit inside the square, as the row's aspect-fit would.
        let fit = min(CGFloat(pixels) / image.size.width, CGFloat(pixels) / image.size.height)
        let width = image.size.width * fit, height = image.size.height * fit
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2, width: width, height: height),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSImage(size: NSSize(width: side, height: side))
        bitmap.addRepresentation(rep)
        bitmap.isTemplate = image.isTemplate
        if bitmaps.count >= capacity { bitmaps.removeAll(keepingCapacity: true) }
        bitmaps[key] = (image, bitmap)
        return bitmap
    }
}

/// "Wi-Fi ›": whose actions these are. A low-alpha fill, no border.
private struct CommandBarChipView: View {
    let chip: CommandBarChip

    var body: some View {
        HStack(spacing: 5) {
            glyph
                .frame(width: 14, height: 14)
            Text(chip.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(nsColor: .labelColor).opacity(0.07)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Actions for \(chip.title)"))
    }

    @ViewBuilder
    private var glyph: some View {
        switch chip.glyph {
        case .image(let image):
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

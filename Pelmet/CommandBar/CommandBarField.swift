// CommandBarField.swift
// The command bar's text field. AppKit, not SwiftUI's TextField: the panel
// makes it first responder in the same turn it becomes key (a SwiftUI focus
// state lands a turn or two later and the first letters go missing), and the
// inline completion has to sit exactly where the field editor's text ends.

import AppKit
import SwiftUI

@MainActor
final class CommandBarFieldView: NSView {
    let font: NSFont

    let field = FocusTextField()
    /// The completion's remainder, drawn after the caret in tertiary ink.
    /// Configured like the field so its text sits on the same baseline.
    private let ghost = NSTextField(labelWithString: "")

    /// Take focus the moment the view is in a window: the alias row comes
    /// and goes with an action, and asking for focus before it exists loses.
    var focusOnAttach = false
    /// Told when the field gains or loses keyboard focus.
    var onFocusChange: ((Bool) -> Void)?

    init(font: NSFont = .systemFont(ofSize: 15), placeholder: String = "") {
        self.font = font
        super.init(frame: .zero)
        for text in [field, ghost] {
            text.isBordered = false
            text.drawsBackground = false
            text.focusRingType = .none
            text.font = font
            text.cell?.usesSingleLineMode = true
            text.cell?.lineBreakMode = .byClipping
            addSubview(text)
        }
        field.isEditable = true
        field.cell?.isScrollable = true
        setPlaceholder(placeholder)
        field.onFocus = { [weak self] in self?.onFocusChange?(true) }
        ghost.textColor = .tertiaryLabelColor
        ghost.isHidden = true
        // A caption for VoiceOver would double the field's own label.
        ghost.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func setPlaceholder(_ text: String) {
        guard field.placeholderString != text else { return }
        field.placeholderString = text
        field.setAccessibilityLabel(text)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusOnAttach, let window { window.makeFirstResponder(field) }
    }

    override func layout() {
        super.layout()
        field.frame = bounds
        placeGhost()
    }

    // MARK: - Text

    var editor: NSTextView? { field.currentEditor() as? NSTextView }

    /// Replace the text without the delegate hearing of it (the caller
    /// ranks), caret at the end.
    func setText(_ text: String) {
        field.stringValue = text
        if let editor {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        placeGhost()
    }

    /// The caret is at the end with nothing selected: where → and Tab mean
    /// "take the completion" rather than "move".
    var caretAtEnd: Bool {
        guard let editor else { return field.stringValue.isEmpty }
        let range = editor.selectedRange
        return range.length == 0 && range.location == (editor.string as NSString).length
    }

    // MARK: - Completion

    func setCompletion(_ text: String?) {
        let text = (editor?.hasMarkedText() ?? false) ? nil : text
        ghost.stringValue = text ?? ""
        ghost.isHidden = text == nil || text?.isEmpty == true
        placeGhost()
    }

    private func placeGhost() {
        guard !ghost.isHidden else { return }
        ghost.sizeToFit()
        // The label and the field draw their text the same distance inside
        // their frames, so the label's frame starts where the typed text's
        // width ends. The width comes from the field editor's layout when
        // editing (it knows the scroll), from the font otherwise.
        var x: CGFloat
        if let editor, let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            let glyphs = layout.boundingRect(forGlyphRange: layout.glyphRange(for: container), in: container)
            let end = convert(NSPoint(x: glyphs.maxX + editor.textContainerOrigin.x, y: 0), from: editor).x
            x = end - (editor.textContainerOrigin.x + container.lineFragmentPadding)
        } else {
            x = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        }
        x = max(0, x)
        ghost.frame = NSRect(x: x, y: 0, width: max(0, min(ghost.frame.width, bounds.width - x)), height: bounds.height)
    }
}

struct CommandBarSearchField: NSViewRepresentable {
    let model: CommandBarModel
    let onChange: (String) -> Void

    func makeNSView(context: Context) -> CommandBarFieldView {
        let view = CommandBarFieldView(placeholder: model.placeholder)
        view.field.delegate = context.coordinator
        view.onFocusChange = { [weak model] focused in
            if model?.fieldFocused != focused { model?.fieldFocused = focused }
            if focused { model?.onFieldFocus?() }
        }
        model.field = view
        return view
    }

    func updateNSView(_ view: CommandBarFieldView, context: Context) {
        context.coordinator.onChange = onChange
        // Read here so SwiftUI re-runs this when the completion changes.
        view.setCompletion(model.completion)
        view.setPlaceholder(model.placeholder)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        /// Focus left the field (a click elsewhere, ⇥ on, the demo's ⎋).
        func controlTextDidEndEditing(_ notification: Notification) {
            ((notification.object as? NSView)?.superview as? CommandBarFieldView)?.onFocusChange?(false)
        }
    }
}

/// Says when it takes focus: a click, ⇥ or the controller's own.
final class FocusTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }
}

/// The alias row's field: the same field at the row's size, focused as it
/// appears, pre-filled with the current alias.
struct CommandBarAliasField: NSViewRepresentable {
    let model: CommandBarModel

    func makeNSView(context: Context) -> CommandBarFieldView {
        let view = CommandBarFieldView(
            font: .systemFont(ofSize: 13),
            placeholder: String(localized: "Your own name, like “work”")
        )
        view.focusOnAttach = true
        view.setText(model.aliasDraft)
        model.aliasField = view
        return view
    }

    func updateNSView(_ view: CommandBarFieldView, context: Context) {}
}

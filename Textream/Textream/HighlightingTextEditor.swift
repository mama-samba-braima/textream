//
//  HighlightingTextEditor.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 26.02.2026.
//

import SwiftUI
import AppKit

extension NSFont {
    var rounded: NSFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

struct HighlightingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 16, weight: .regular)
    var isFocused: FocusState<Bool>.Binding?
    /// Range of newly dictated text to highlight with a bump effect
    var highlightRange: NSRange? = nil
    /// The word currently being read, highlighted and scrolled to so the script follows the
    /// prompter. Unlike the caret, this never changes the selection.
    var followRange: NSRange? = nil
    /// One-shot: set caret to this position, then nilled out
    @Binding var caretPosition: Int?
    /// One-shot: scroll this position to the top of the pane, then nilled out. Jumping to a
    /// section should put its heading at the top, not merely somewhere on screen.
    @Binding var scrollToTopPosition: Int?
    /// Continuously reported current caret position in the editor
    @Binding var editorCaretPosition: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // The script pane is white paper, so the text, caret and selection have to be the light
        // ones. AppKit resolves those from the appearance, which SwiftUI's colour scheme cannot
        // reach into.
        scrollView.appearance = NSAppearance(named: .aqua)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = font
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text and apply highlighting
        textView.string = text
        context.coordinator.applyHighlighting(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // The coordinator holds the view it was made with, so without this it keeps styling the
        // text in the font the editor started with, whatever the size control says.
        context.coordinator.parent = self

        if textView.font != font {
            textView.font = font
            context.coordinator.applyHighlighting(textView)
        }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            context.coordinator.applyHighlighting(textView)
        }

        // Apply bump highlight on newly dictated range
        if let range = highlightRange, range.location + range.length <= textView.string.count {
            context.coordinator.applyBumpHighlight(textView, range: range)
        }

        if let range = followRange, range.location + range.length <= textView.string.count {
            context.coordinator.applyFollowHighlight(textView, range: range)
        } else if followRange == nil {
            context.coordinator.clearFollowHighlight(textView)
        }

        if let pos = scrollToTopPosition, pos <= textView.string.count {
            let range = NSRange(location: pos, length: 0)
            textView.setSelectedRange(range)
            context.coordinator.scrollToTop(textView, location: pos)
            DispatchQueue.main.async {
                self.scrollToTopPosition = nil
            }
        }

        // Move caret to requested position (one-shot)
        if let pos = caretPosition, pos <= textView.string.count {
            let caretRange = NSRange(location: pos, length: 0)
            textView.setSelectedRange(caretRange)
            textView.scrollRangeToVisible(caretRange)
            DispatchQueue.main.async {
                self.caretPosition = nil
            }
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: HighlightingTextEditor
        weak var textView: NSTextView?

        private static let annotationPattern = try! NSRegularExpression(
            pattern: "\\[[^\\]]+\\]",
            options: []
        )

        init(_ parent: HighlightingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            applyHighlighting(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let pos = textView.selectedRange().location
            if parent.editorCaretPosition != pos {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.editorCaretPosition = pos
                }
            }
        }

        /// Puts `location` at the top of the visible area rather than merely on screen, which is
        /// what `scrollRangeToVisible` alone would do.
        func scrollToTop(_ textView: NSTextView, location: Int) {
            guard let scrollView = textView.enclosingScrollView else { return }
            let range = NSRange(location: location, length: 0)

            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                rect.origin.y += textView.textContainerInset.height

                let clipView = scrollView.contentView
                let lowest = max(0, textView.bounds.height - clipView.bounds.height)
                let target = min(max(0, rect.minY - 2), lowest)
                clipView.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(clipView)
                return
            }

            // No layout manager to ask: scrolling past the target first, then back to it, leaves
            // it against the top edge.
            let below = NSRange(location: min(textView.string.count, location + 4000), length: 0)
            textView.scrollRangeToVisible(below)
            textView.scrollRangeToVisible(range)
        }

        private var bumpTimer: Timer?

        func applyBumpHighlight(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            guard range.length > 0, range.location + range.length <= textStorage.length else { return }

            let bumpColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            textStorage.beginEditing()
            textStorage.addAttribute(.backgroundColor, value: bumpColor, range: range)
            textStorage.endEditing()

            // Fade out after a short delay
            bumpTimer?.invalidate()
            bumpTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.applyHighlighting(textView)
            }
        }

        var lastFollowRange: NSRange?

        func applyFollowHighlight(_ textView: NSTextView, range: NSRange) {
            guard range != lastFollowRange, let textStorage = textView.textStorage else { return }
            lastFollowRange = range
            applyHighlighting(textView)
            textStorage.beginEditing()
            textStorage.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.3),
                range: range
            )
            textStorage.endEditing()
            // Never yank the view out from under someone who is typing in it.
            if textView.window?.firstResponder !== textView {
                textView.scrollRangeToVisible(range)
            }
        }

        func clearFollowHighlight(_ textView: NSTextView) {
            guard lastFollowRange != nil else { return }
            lastFollowRange = nil
            applyHighlighting(textView)
        }

        func applyHighlighting(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            let text = textStorage.string

            // Preserve selection
            let selectedRanges = textView.selectedRanges

            textStorage.beginEditing()

            // Reset to default style
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: parent.font,
                .foregroundColor: NSColor.labelColor
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)

            // Highlight [bracket] annotations
            let matches = Self.annotationPattern.matches(in: text, options: [], range: fullRange)
            for match in matches {
                let annotationAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFontManager.shared.convert(parent.font, toHaveTrait: .italicFontMask),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08)
                ]
                textStorage.addAttributes(annotationAttributes, range: match.range)
            }

            textStorage.endEditing()

            // Restore selection
            textView.selectedRanges = selectedRanges
        }
    }
}

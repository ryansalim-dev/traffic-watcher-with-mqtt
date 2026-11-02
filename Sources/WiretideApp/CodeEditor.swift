#if os(macOS)
import AppCore
import AppKit
import SwiftUI

/// An editable code area with line numbers and, optionally, JSON syntax colors. SwiftUI's TextEditor can't
/// color text, so this wraps NSTextView.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightJSON = false
    var fontSize: CGFloat = 13
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.textContainerInset = NSSize(width: 4, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.35
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.string = text
        textView.delegate = context.coordinator

        let ruler = LineNumberRuler(textView: textView, fontSize: fontSize)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scrollView.contentView, ruler: ruler)

        context.coordinator.textView = textView
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        } else if context.coordinator.highlightedAsJSON != highlightJSON {
            context.coordinator.highlight()
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        var highlightedAsJSON = false
        private var observer: NSObjectProtocol?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func observe(_ clipView: NSClipView, ruler: NSRulerView) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView,
                                                              queue: .main) { [weak ruler] _ in
                ruler?.needsDisplay = true
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            highlightedAsJSON = parent.highlightJSON
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular), range: full)
            if parent.highlightJSON, storage.length <= CodeText.highlightLimit {
                var location = 0
                for token in JSONHighlighter.tokens(storage.string) {
                    let length = (token.text as NSString).length
                    if let color = Theme.color(for: token.kind), location + length <= storage.length {
                        storage.addAttribute(.foregroundColor, value: NSColor(color), range: NSRange(location: location, length: length))
                    }
                    location += length
                }
            }
            storage.endEditing()
        }
    }
}

/// Line numbers in the gutter of a CodeEditor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let fontSize: CGFloat

    init(textView: NSTextView, fontSize: CGFloat) {
        self.textView = textView
        self.fontSize = fontSize
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let text = textView.string as NSString
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerInset.height
        let lineHeight = layoutManager.defaultLineHeight(for: .monospacedSystemFont(ofSize: fontSize, weight: .regular))

        func label(_ number: Int, in lineRect: NSRect) {
            let string = String(number) as NSString
            let size = string.size(withAttributes: attributes)
            let y = offset + lineRect.minY + (lineHeight - size.height) / 2
            string.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }

        if text.length == 0 {
            label(1, in: layoutManager.extraLineFragmentRect.isEmpty
                  ? NSRect(x: 0, y: 0, width: 10, height: fontSize * 1.2) : layoutManager.extraLineFragmentRect)
            return
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var number = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            number += 1
        }
        var index = characters.location
        while index < NSMaxRange(characters) {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            label(number, in: lineRect)
            number += 1
            guard NSMaxRange(line) > index else { break }
            index = NSMaxRange(line)
        }
        // The empty line after a trailing newline.
        if index >= text.length, text.hasSuffix("\n"), !layoutManager.extraLineFragmentRect.isEmpty {
            label(number, in: layoutManager.extraLineFragmentRect)
        }
    }
}
#endif

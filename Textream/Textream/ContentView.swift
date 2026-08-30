//
//  ContentView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

extension View {
    /// The script pane reads like paper: white, in light colours, whatever the system theme is
    /// doing. The prompter surfaces stay black; this is the writing side.
    func paperSurface() -> some View {
        self
            .environment(\.colorScheme, .light)
            .background(Color.white)
    }
}

struct ContentView: View {
    @ObservedObject private var service = TextreamService.shared
    @State private var isRunning = false
    @State private var dictation = DictationManager()
    @State private var dictationHighlightRange: NSRange? = nil
    @State private var dictationCaretPosition: Int? = nil
    @State private var editorCaretPosition: Int = 0
    @State private var isDroppingPresentation = false
    @State private var dropError: String?
    @State private var dropAlertTitle: String = "Import Error"
    @State private var showSettings = false
    @State private var showAbout = false
    @State private var renamingFolderID: UUID?
    @State private var folderNameDraft: String = ""
    /// Play mode starts split, script on the left and the mirror on the right, and can be
    /// expanded to the mirror alone.
    @State private var mirrorExpanded = false
    @State private var selectedPageIDs: Set<UUID> = []
    /// Pages whose `##` sections are listed under them in the sidebar.
    @State private var expandedOutlines: Set<UUID> = []
    /// Character offset the Markdown preview should scroll to, set by the sidebar outline.
    @State private var previewScrollTarget: Int?
    /// Character offset the editor should bring to the top, set by the sidebar outline.
    @State private var editorScrollTarget: Int?
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findMatches: [NSRange] = []
    @State private var findIndex = 0
    @FocusState private var isFindFocused: Bool
    @State private var pendingDeleteIDs: [UUID] = []
    /// The word being read, pointed at in the script pane while a read is running.
    @State private var followRange: NSRange?
    @State private var languageSuggestion: SpeechLanguageSuggestion?
    @State private var ignoredLanguageIdentifier: String?
    @State private var languageDetectionTask: Task<Void, Never>?
    @FocusState private var isTextFocused: Bool

    private let defaultText = """
Welcome to Textream! This is your personal teleprompter that sits right below your MacBook's notch. [smile]

As you read aloud, the text will highlight in real-time, following your voice. The speech recognition matches your words and keeps track of your progress. [pause]

You can pause at any time, go back and re-read sections, and the highlighting will follow along. When you finish reading all the text, the overlay will automatically close with a smooth animation. [nod]

Try reading this passage out loud to see how the highlighting works. The waveform at the bottom shows your voice activity, and you'll see the last few words you spoke displayed next to it.

Happy presenting! [wave]
"""

    private var languageLabel: String {
        let locale = NotchSettings.shared.speechLocale
        return Locale.current.localizedString(forIdentifier: locale)
            ?? locale
    }

    private var currentText: Binding<String> {
        Binding(
            get: {
                guard service.currentPageIndex < service.pages.count else { return "" }
                return service.pages[service.currentPageIndex]
            },
            set: { newValue in
                guard service.currentPageIndex < service.pages.count else { return }
                service.pages[service.currentPageIndex] = newValue
            }
        )
    }

    private var hasAnyContent: Bool {
        service.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isRecording: Bool {
        dictation.isRecording || dictation.isStarting
    }

    private func scheduleLanguageDetection(for text: String) {
        languageDetectionTask?.cancel()
        languageSuggestion = nil
        let pageIndex = service.currentPageIndex
        let localeIdentifier = NotchSettings.shared.speechLocale

        languageDetectionTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  service.currentPageIndex == pageIndex,
                  service.currentPageText == text,
                  NotchSettings.shared.speechLocale == localeIdentifier else { return }

            let suggestion = SpeechLanguageDetector.suggestion(
                for: text,
                currentLocaleIdentifier: localeIdentifier
            )
            guard !Task.isCancelled,
                  suggestion?.detectedLanguageIdentifier != ignoredLanguageIdentifier else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                languageSuggestion = suggestion
            }
        }
    }

    private func languageSuggestionBanner(_ suggestion: SpeechLanguageSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble.fill")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("This text looks like \(suggestion.languageName).")
                    .font(.system(size: 12, weight: .semibold))
                Text("Speech is currently set to \(languageLabel).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Use \(suggestion.languageName)") {
                if isRecording {
                    stopRecording()
                }
                ignoredLanguageIdentifier = nil
                languageSuggestion = nil
                NotchSettings.shared.speechLocale = suggestion.localeIdentifier
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Switch speech recognition to \(suggestion.localeName)")

            Button {
                ignoredLanguageIdentifier = suggestion.detectedLanguageIdentifier
                withAnimation(.easeInOut(duration: 0.2)) {
                    languageSuggestion = nil
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss language suggestion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.2))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var waveformPill: some View {
        let pill = AudioWaveformView(levels: dictation.audioLevels, color: .red)
            .frame(height: 34)
            .frame(maxWidth: 240)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            pill
                .glassEffect(in: .capsule)
        } else {
            pill
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        #else
        pill
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        #endif
    }

    @State private var highlightClearTimer: Timer?

    // Segment tracking: each recognition session is a "segment"
    @State private var segmentStart: Int = 0
    @State private var segmentLength: Int = 0
    @State private var segmentNeedsSeparator: Bool = false
    // How many chars of the raw recognition result to skip (already committed before cursor move)
    @State private var spokenSkipOffset: Int = 0
    @State private var lastRawSpokenLength: Int = 0

    private func beginNewSegment() {
        let pageIndex = service.currentPageIndex
        guard pageIndex < service.pages.count else { return }
        let text = service.pages[pageIndex]
        let caret = min(editorCaretPosition, text.count)

        // Skip everything already recognized up to this point
        spokenSkipOffset = lastRawSpokenLength

        // Check if we need a space before the new segment
        let charBefore = caret > 0 ? text[text.index(text.startIndex, offsetBy: caret - 1)] : "\n"
        segmentNeedsSeparator = !(charBefore == " " || charBefore == "\n" || caret == 0)
        segmentStart = caret
        segmentLength = 0
    }

    private func startRecording() {
        lastRawSpokenLength = 0
        spokenSkipOffset = 0
        beginNewSegment()

        dictation.onNewSegment = { [self] in
            // Recognition restarted — raw counter resets to 0
            lastRawSpokenLength = 0
            spokenSkipOffset = 0
            beginNewSegment()
        }

        dictation.onTextUpdate = { [self] spokenText in
            lastRawSpokenLength = spokenText.count

            // Only use the portion after the skip offset
            let effectiveText: String
            if spokenSkipOffset < spokenText.count {
                effectiveText = String(spokenText.suffix(spokenText.count - spokenSkipOffset))
            } else {
                effectiveText = ""
            }
            guard !effectiveText.isEmpty else { return }

            let pageIndex = service.currentPageIndex
            guard pageIndex < service.pages.count else { return }
            var text = service.pages[pageIndex]

            // Remove the old segment text
            let safeStart = min(segmentStart, text.count)
            let removeStart = text.index(text.startIndex, offsetBy: safeStart)
            let safeLen = min(segmentLength, text.count - safeStart)
            let removeEnd = text.index(removeStart, offsetBy: safeLen)
            text.removeSubrange(removeStart..<removeEnd)

            // Build the new segment content
            let sep = segmentNeedsSeparator ? " " : ""
            let newSegment = sep + effectiveText
            text.insert(contentsOf: newSegment, at: text.index(text.startIndex, offsetBy: min(segmentStart, text.count)))

            let prevLen = segmentLength
            segmentLength = newSegment.count
            service.pages[pageIndex] = text

            // Highlight only the newly added characters
            let newChars = segmentLength - prevLen
            if newChars > 0 {
                let highlightStart = segmentStart + prevLen
                dictationHighlightRange = NSRange(location: highlightStart, length: newChars)
            }

            // Move caret to end of segment
            dictationCaretPosition = segmentStart + segmentLength

            // Clear highlight after 1s of silence
            highlightClearTimer?.invalidate()
            highlightClearTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                DispatchQueue.main.async {
                    dictationHighlightRange = nil
                }
            }
        }
        dictation.start()
    }

    private func stopRecording() {
        highlightClearTimer?.invalidate()
        highlightClearTimer = nil
        dictationHighlightRange = nil
        dictation.stop()
        dictation.onTextUpdate = nil
        dictation.onNewSegment = nil
    }

    /// The script editor, shared by the idle layout and the split play-mode layout.
    private var scriptEditor: some View {
        HighlightingTextEditor(
            text: currentText,
            font: .systemFont(ofSize: NotchSettings.shared.editorFontSize, weight: .regular).rounded,
            highlightRange: dictationHighlightRange,
            followRange: isRunning ? followRange : nil,
            caretPosition: $dictationCaretPosition,
            scrollToTopPosition: $editorScrollTarget,
            searchRanges: showFind ? findMatches : [],
            activeSearchRange: showFind ? activeMatch : nil,
            editorCaretPosition: $editorCaretPosition
        )
        .onChange(of: editorCaretPosition) { _, newPos in
            guard isRecording else { return }
            let segmentEnd = segmentStart + segmentLength
            if newPos != segmentEnd {
                beginNewSegment()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// The same page as rendered Markdown, for reading rather than editing.
    private var markdownPreview: some View {
        MarkdownPreviewView(
            text: service.currentPageText,
            fontSize: NotchSettings.shared.editorFontSize,
            scrollTarget: $previewScrollTarget
        )
    }

    /// Softens the top and bottom edges of the reading pane so text fades out rather than
    /// being cut off by the toolbar and the transport controls.
    private var fadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.03),
                .init(color: .white, location: 0.93),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Dictation lives on the writing side of the window: the waveform while recording, and the
    /// microphone that starts it. The read's own transport is on the mirror.
    private var dictationBar: some View {
        VStack {
            Spacer()
            ZStack {
                // Waveform pill centered to full width
                if dictation.isRecording {
                    waveformPill
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                // Pinned to the bottom right of the script pane, out of the way of the words.
                HStack(spacing: 10) {
                    Spacer()

                    if !isRunning {
                    Button {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    } label: {
                        Group {
                            if dictation.isStarting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: isRecording ? "pause.fill" : "mic.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(isRecording ? Color.orange : Color.red)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    }

                }
            }
            .padding(20)
        }
        .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    /// The writing side of the window: the editor, or the rendered Markdown when the preview is on.
    @ViewBuilder
    private var scriptPane: some View {
        if NotchSettings.shared.markdownPreviewEnabled && !isRunning {
            markdownPreview
                .mask(fadeMask)
                .paperSurface()
                .transition(.opacity)
        } else {
            scriptEditor
                .mask(fadeMask)
                .paperSurface()
                .overlay(alignment: .top) { findOverlay }
                .transition(.opacity)
        }
    }

    private var playMirror: some View {
        PlayModeView(
            content: service.overlayController.overlayContent,
            speechRecognizer: service.overlayController.speechRecognizer,
            isExpanded: mirrorExpanded,
            isRunning: isRunning,
            onPlay: { run() },
            onScrub: { service.scrub(toCharOffset: $0) },
            onSeek: { service.seek(toCharOffset: $0) },
            onToggleExpand: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mirrorExpanded.toggle()
                }
            },
            onStop: { stop() },
            onWordIndexChange: { index in
                followRange = service.editorRange(forWordIndex: index)
            }
        )
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let languageSuggestion {
                languageSuggestionBanner(languageSuggestion)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
                // Script on the left, what the talent sees on the right, take or no take. The
                // mirror stands by with the section play would start, so starting one is a single
                // press in the place the stop button will be.
                if mirrorExpanded {
                    playMirror
                        .transition(.opacity)
                } else {
                    HSplitView {
                        scriptPane
                            .overlay { dictationBar }
                            .frame(minWidth: 280)
                        playMirror
                            .frame(minWidth: 320)
                    }
                    .transition(.opacity)
                }


                // Drop zone overlay — sits on top so TextEditor doesn't steal the drop
                if isDroppingPresentation {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Drop PowerPoint (.pptx) file")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("For Keynote or Google Slides,\nexport as PPTX first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                )
                .padding(8)
            }

            // Invisible drop target covering entire window
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isDroppingPresentation) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "key" {
                            DispatchQueue.main.async {
                                dropAlertTitle = "Conversion Required"
                                dropError = "Keynote files can't be imported directly. Please export your Keynote presentation as PowerPoint (.pptx) first, then drop the exported file here."
                            }
                            return
                        }
                        guard ext == "pptx" else {
                            DispatchQueue.main.async {
                                dropAlertTitle = "Import Error"
                                dropError = "Unsupported file. Drop a PowerPoint (.pptx) file."
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            handlePresentationDrop(url: url)
                        }
                    }
                    return true
                }
                .allowsHitTesting(isDroppingPresentation)
            }
        }
    }

    // MARK: - Find

    private var activeMatch: NSRange? {
        findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil
    }

    @ViewBuilder
    private var findOverlay: some View {
        if showFind {
            findBar
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Find in script", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFindFocused)
                .onSubmit { stepFind(by: 1) }

            Text(findCountLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(findMatches.isEmpty && !findQuery.isEmpty ? Color.red : Color.secondary)

            findStep("chevron.up", by: -1, help: "Previous match (\u{21E7}\u{2318}G)")
            findStep("chevron.down", by: 1, help: "Next match (\u{2318}G)")

            Button {
                closeFind()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.black.opacity(0.08))
                }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onExitCommand { closeFind() }
    }

    private func findStep(_ systemImage: String, by delta: Int, help: String) -> some View {
        Button {
            stepFind(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(findMatches.isEmpty)
        .opacity(findMatches.isEmpty ? 0.35 : 1)
        .help(help)
    }

    private var findCountLabel: String {
        if findQuery.isEmpty { return "" }
        if findMatches.isEmpty { return "none" }
        return "\(findIndex + 1) of \(findMatches.count)"
    }

    private func openFind() {
        // Hits are marked in the text itself, which only the editor can do.
        if NotchSettings.shared.markdownPreviewEnabled {
            NotchSettings.shared.markdownPreviewEnabled = false
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            showFind = true
        }
        updateFindMatches(anchoredToCaret: true)
        isFindFocused = true
    }

    private func closeFind() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showFind = false
        }
        isFindFocused = false
        isTextFocused = true
    }

    private func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        // Wraps, so stepping past the last hit comes back round to the first.
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
    }

    /// Recomputes the hits for the current query. `anchoredToCaret` starts from where the cursor
    /// is, which is where the eye already is when a search begins.
    private func updateFindMatches(anchoredToCaret: Bool = false) {
        guard showFind, !findQuery.isEmpty else {
            findMatches = []
            findIndex = 0
            return
        }

        let ranges = ScriptSearch.matches(of: findQuery, in: service.currentPageText)
        let previous = activeMatch
        findMatches = ranges
        if ranges.isEmpty {
            findIndex = 0
        } else if anchoredToCaret {
            findIndex = ranges.firstIndex { $0.location >= editorCaretPosition } ?? 0
        } else if let previous, let held = ranges.firstIndex(where: { $0.location >= previous.location }) {
            // Editing the script must not throw the search back to the top of the page.
            findIndex = held
        } else {
            findIndex = min(findIndex, ranges.count - 1)
        }
    }

    // MARK: - Reading Controls

    /// Grows and shrinks the script. A teleprompter script is written to be read out loud, so the
    /// size that suits writing is rarely the size that suits reading it back.
    private var fontSizeControl: some View {
        HStack(spacing: 2) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("-", modifiers: .command)
            .disabled(NotchSettings.shared.editorFontSize <= NotchSettings.minEditorFontSize)
            .help("Smaller script text")

            Text("\(Int(NotchSettings.shared.editorFontSize))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("+", modifiers: .command)
            .disabled(NotchSettings.shared.editorFontSize >= NotchSettings.maxEditorFontSize)
            .help("Bigger script text")

            // Most keyboards put "+" behind Shift, so ⌘= grows the text as well.
            Button {
                adjustFontSize(by: 1)
            } label: {
                Color.clear.frame(width: 0, height: 0)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("=", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var previewToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                NotchSettings.shared.markdownPreviewEnabled.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: NotchSettings.shared.markdownPreviewEnabled ? "eye.fill" : "curlybraces")
                    .font(.system(size: 10))
                Text(NotchSettings.shared.markdownPreviewEnabled ? "Preview" : "Markdown")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(NotchSettings.shared.markdownPreviewEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(NotchSettings.shared.markdownPreviewEnabled
              ? "Back to editing (\u{21E7}\u{2318}P)"
              : "Preview the script as Markdown (\u{21E7}\u{2318}P)")
    }

    private func adjustFontSize(by delta: Double) {
        NotchSettings.shared.editorFontSize = min(
            NotchSettings.maxEditorFontSize,
            max(NotchSettings.minEditorFontSize, NotchSettings.shared.editorFontSize + delta)
        )
    }

    private var directorOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "megaphone.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("Director Mode")
                .font(.system(size: 22, weight: .bold))

            Text(service.directorIsReading ? "Reading from director…" : "Waiting for director to send script…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let ip = BrowserServer.localIPAddress() {
                let url = "http://\(ip):\(NotchSettings.shared.directorServerPort)"

                if let qrImage = generateDirectorQRCode(from: url) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 8) {
                    Text(url)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateDirectorQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    var body: some View {
        windowBody
            .onReceive(NotificationCenter.default.publisher(for: .findInScript)) { _ in
                openFind()
            }
            .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in
                if showFind { stepFind(by: 1) } else { openFind() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in
                if showFind { stepFind(by: -1) } else { openFind() }
            }
            .onChange(of: findQuery) { _, _ in
                updateFindMatches(anchoredToCaret: true)
            }
            .onChange(of: service.currentSectionIndex, initial: true) { _, _ in
                if !isRunning { service.refreshPreview() }
            }
            .onChange(of: service.currentPageText) { _, _ in
                if !isRunning { service.refreshPreview() }
            }
            .onChange(of: isRunning) { _, running in
                if !running { service.refreshPreview() }
            }
            .onChange(of: service.currentPageText) { _, _ in
                updateFindMatches()
            }
            .onChange(of: service.currentPageIndex) { _, _ in
                updateFindMatches(anchoredToCaret: true)
            }
    }

    private var windowBody: some View {
        Group {
            if NotchSettings.shared.directorModeEnabled {
                directorOverlay
            } else {
                NavigationSplitView {
                    pageSidebar
                } detail: {
                    mainContent
                }
                .navigationSplitViewColumnWidth(min: sb(160), ideal: sb(200), max: sb(300))
            }
        }
        .alert(dropAlertTitle, isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("OK") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
        .alert("Microphone Unavailable", isPresented: Binding(
            get: { dictation.error != nil },
            set: { if !$0 { dictation.error = nil } }
        )) {
            Button("OK") { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
        // The window holds a script and the mirror side by side, so it has two panes' worth of
        // minimum rather than one.
        .frame(minWidth: 700, minHeight: 420)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        service.openFile()
                    } label: {
                        HStack(spacing: 4) {
                            if service.currentFileURL != nil && service.pages != service.savedPages {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                            }
                            Text(service.currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    // Add page button in toolbar
                    Button {
                        if isRecording {
                            stopRecording()
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = service.addPageNearSelection()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Page")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    fontSizeControl

                    previewToggle

                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: NotchSettings.shared.listeningMode.icon)
                                .font(.system(size: 10))
                            Text(NotchSettings.shared.listeningMode == .wordTracking
                                 ? languageLabel
                                 : NotchSettings.shared.listeningMode.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: NotchSettings.shared)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onChange(of: service.currentPageText) { _, _ in
            // Edits made in the split view reach the prompter, the external display and the
            // remote straight away, without restarting the read.
            guard isRunning else { return }
            service.refreshLiveScript()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Sync button state when app is re-activated (e.g. dock click)
            isRunning = service.overlayController.isShowing
        }
        .onChange(of: service.currentPageText, initial: true) { _, text in
            scheduleLanguageDetection(for: text)
        }
        .onChange(of: service.currentPageIndex) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onChange(of: NotchSettings.shared.speechLocale) { _, _ in
            if isRecording {
                stopRecording()
            }
            ignoredLanguageIdentifier = nil
            scheduleLanguageDetection(for: service.currentPageText)
        }
        .onDisappear {
            languageDetectionTask?.cancel()
            if isRecording {
                stopRecording()
            }
        }
        .onAppear {
            // Set default text for the first page if empty
            if service.pages.count == 1 && service.pages[0].isEmpty {
                service.pages[0] = defaultText
            }
            // Sync button state with overlay
            if service.overlayController.isShowing {
                isRunning = true
            }
            if TextreamService.shared.launchedExternally {
                DispatchQueue.main.async {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
                    }
                }
            } else {
                isTextFocused = true
            }
        }
    }

    // MARK: - Page Sidebar

    /// The sidebar is sized on its own, separately from the script: a list of titles and a page
    /// of prose are read at different distances. `sb(12)`, a page title, is exactly the setting.
    private var sidebarScale: CGFloat {
        NotchSettings.shared.sidebarFontSize / NotchSettings.defaultSidebarFontSize
    }

    /// A sidebar metric at the current scale, be it a point size, an icon or a row inset.
    private func sb(_ value: CGFloat) -> CGFloat {
        (value * sidebarScale).rounded()
    }


    private func pagePreview(_ page: String) -> String {
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty" }
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let preview = words.prefix(5).joined(separator: " ")
        return preview.count > 30 ? String(preview.prefix(30)) + "…" : preview
    }

    /// Multi-select for delete and drag. The editor follows only when exactly one page is
    /// selected, so selecting a range never yanks the editor around.
    private var sidebarSelection: Binding<Set<UUID>> {
        Binding<Set<UUID>>(
            get: { selectedPageIDs },
            set: { newValue in
                selectedPageIDs = newValue
                guard newValue.count == 1,
                      let id = newValue.first,
                      let index = service.index(of: id),
                      index != service.currentPageIndex else { return }
                if isRecording {
                    stopRecording()
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    service.currentPageIndex = index
                }
            }
        )
    }

    /// The pages an action applies to: the whole selection when the row is part of it,
    /// otherwise just the row that was clicked.
    private func actionTargets(for id: UUID) -> [UUID] {
        selectedPageIDs.contains(id) && selectedPageIDs.count > 1
            ? service.pageIDs.filter { selectedPageIDs.contains($0) }
            : [id]
    }

    private var pageSidebar: some View {
        List(selection: sidebarSelection) {
            if isRunning {
                takeRows
            } else {
                libraryRows
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Mid-take the phone remote is what the bottom of the sidebar is for; otherwise it is
            // where pages are made.
            if isRunning {
                remotePanel
            } else {
                sidebarFooter
            }
        }
        .onDeleteCommand {
            requestDelete(selectedPageIDs.isEmpty
                ? Array(service.pageID(at: service.currentPageIndex).map { [$0] } ?? [])
                : service.pageIDs.filter { selectedPageIDs.contains($0) })
        }
        .onChange(of: service.currentPageIndex) { _, index in
            // The page being worked on shows its sections, so the outline follows the work.
            if let id = service.pageID(at: index) {
                expandedOutlines.insert(id)
            }
            // Keep the sidebar in step when the page changes from elsewhere, but never
            // collapse a selection the user is building.
            guard selectedPageIDs.count <= 1, let id = service.pageID(at: index) else { return }
            selectedPageIDs = [id]
        }
        .onAppear {
            if let id = service.pageID(at: service.currentPageIndex) {
                expandedOutlines.insert(id)
            }
        }
        .alert(deleteAlertTitle, isPresented: deletingBinding) {
            Button("Cancel", role: .cancel) { pendingDeleteIDs = [] }
            Button("Delete", role: .destructive) {
                let ids = pendingDeleteIDs
                pendingDeleteIDs = []
                deletePages(ids)
            }
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("Rename Folder", isPresented: renamingBinding) {
            TextField("Folder name", text: $folderNameDraft)
            Button("Cancel", role: .cancel) { renamingFolderID = nil }
            Button("Rename") {
                if let id = renamingFolderID {
                    service.renameFolder(id: id, to: folderNameDraft)
                }
                renamingFolderID = nil
            }
        }
    }

    /// Mid-take: the page being read and its sections, and nothing else. Everything else in the
    /// library is a distraction while the camera is rolling.
    @ViewBuilder
    private var takeRows: some View {
        if let id = service.pageID(at: service.currentPageIndex) {
            Section {
                pageRow(id: id)
                ForEach(service.outline(for: id)) { section in
                    sectionRow(pageID: id, section: section)
                }
            } header: {
                Text("Now Reading")
                    .font(.system(size: sb(11), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The phone remote, pinned to the foot of the sidebar during a take.
    @ViewBuilder
    private var remotePanel: some View {
        if let url = RemoteConnection.url {
            VStack(spacing: 6) {
                if let qr = RemoteConnection.qrCode(for: url) {
                    Image(nsImage: qr)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .padding(6)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text("Scan to control from your phone")
                    .font(.system(size: sb(10)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(url)
                    .font(.system(size: sb(10), weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var libraryRows: some View {
            ForEach(service.folders) { folder in
                Section(isExpanded: expansionBinding(for: folder)) {
                    let ids = service.pageIDs(inFolder: folder.id)
                    if ids.isEmpty {
                        Text("Drag pages here")
                            .font(.system(size: sb(11)))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 2)
                    } else {
                        ForEach(sidebarItems(ids)) { item in
                            sidebarRow(item)
                        }
                    }
                } header: {
                    folderHeader(folder)
                }
            }

            // Only collapsible once there are folders: without a header there would be no
            // control to reopen the section with.
            if service.folders.isEmpty {
                Section {
                    ForEach(sidebarItems(service.pageIDs(inFolder: nil))) { item in
                        sidebarRow(item)
                    }
                }
            } else {
                Section(isExpanded: $service.ungroupedIsExpanded) {
                    ForEach(sidebarItems(service.pageIDs(inFolder: nil))) { item in
                        sidebarRow(item)
                    }
                } header: {
                    ungroupedHeader
                }
            }
    }

    private var ungroupedHeader: some View {
        Text("Pages")
            .font(.system(size: sb(11), weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                movePages(items, to: nil)
            }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 2) {
            Button {
                if isRecording {
                    stopRecording()
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = service.addPageNearSelection()
                }
            } label: {
                Label("Add Page", systemImage: "plus")
                    .font(.system(size: sb(12), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .help("Add a new page")

            Spacer(minLength: 0)

            sidebarSizeMenu

            Button {
                newFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: sb(12)))
                    .foregroundStyle(.secondary)
                    .frame(width: sb(28), height: sb(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New folder")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: sb(12)))
                    .foregroundStyle(.secondary)
                    .frame(width: sb(28), height: sb(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 4)
        .background(.bar)
    }

    /// Sizes the sidebar, right where the sidebar is. Narrow buttons rather than a stepper, so
    /// they still fit beside Add Page when the column is at its narrowest.
    private var sidebarSizeMenu: some View {
        HStack(spacing: 0) {
            sidebarSizeButton(
                "textformat.size.smaller",
                by: -1,
                help: "Smaller sidebar text (\u{2325}\u{2318}-)",
                disabled: NotchSettings.shared.sidebarFontSize <= NotchSettings.minSidebarFontSize
            )
            sidebarSizeButton(
                "textformat.size.larger",
                by: 1,
                help: "Bigger sidebar text (\u{2325}\u{2318}+)",
                disabled: NotchSettings.shared.sidebarFontSize >= NotchSettings.maxSidebarFontSize
            )
        }
        .contextMenu {
            Button("Reset Sidebar Text Size") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    NotchSettings.shared.sidebarFontSize = NotchSettings.defaultSidebarFontSize
                }
            }
        }
        .background {
            // Shortcut carriers: a Button is what makes a shortcut live, and these have no size.
            Group {
                sidebarSizeKey("+", by: 1)
                sidebarSizeKey("=", by: 1)
                sidebarSizeKey("-", by: -1)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func sidebarSizeButton(
        _ systemImage: String,
        by delta: Double,
        help: String,
        disabled: Bool
    ) -> some View {
        Button {
            adjustSidebarFontSize(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: sb(11)))
                .foregroundStyle(.secondary)
                .frame(width: sb(22), height: sb(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(help)
    }

    private func sidebarSizeKey(_ key: KeyEquivalent, by delta: Double) -> some View {
        Button {
            adjustSidebarFontSize(by: delta)
        } label: {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [.command, .option])
    }

    private func adjustSidebarFontSize(by delta: Double) {
        withAnimation(.easeInOut(duration: 0.15)) {
            NotchSettings.shared.sidebarFontSize = min(
                NotchSettings.maxSidebarFontSize,
                max(NotchSettings.minSidebarFontSize, NotchSettings.shared.sidebarFontSize + delta)
            )
        }
    }

    private func folderHeader(_ folder: PageFolder) -> some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isPinned ? "pin.fill" : "folder")
                .font(.system(size: sb(10)))
                .foregroundStyle(folder.isPinned ? Color.accentColor : .secondary)
            Text(folder.name)
                .font(.system(size: sb(11), weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(folder.pageIDs.count)")
                .font(.system(size: sb(10), design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .help("Double-click to rename")
        .onTapGesture(count: 2) {
            startRenaming(folder)
        }
        .dropDestination(for: String.self) { items, _ in
            movePages(items, to: folder.id)
        }
        .contextMenu {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = service.addPage(to: folder.id)
                }
            } label: {
                Label("Add Page to Folder", systemImage: "plus")
            }
            Button {
                startRenaming(folder)
            } label: {
                Label("Rename Folder…", systemImage: "pencil")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    service.togglePin(folderID: folder.id)
                }
            } label: {
                Label(folder.isPinned ? "Unpin Folder" : "Pin Folder",
                      systemImage: folder.isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button {
                service.moveFolder(id: folder.id, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            Button {
                service.moveFolder(id: folder.id, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            Divider()
            Button(role: .destructive) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    service.deleteFolder(id: folder.id)
                }
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    /// One line of the sidebar: a page, or one of the `##` sections listed under it.
    ///
    /// Pages and their sections are flattened into a single list rather than nested, because a
    /// List gives one row per element: emitting a page and its sections together made them a
    /// single row, which then highlighted as a block when the page was selected.
    private enum SidebarItem: Identifiable {
        case page(UUID)
        case section(pageID: UUID, section: ScriptSection)

        var id: String {
            switch self {
            case .page(let id): return id.uuidString
            case .section(let pageID, let section): return "\(pageID.uuidString)#\(section.id)"
            }
        }
    }

    /// The pages in a folder, each followed by its sections when its outline is open.
    private func sidebarItems(_ ids: [UUID]) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for id in ids {
            items.append(.page(id))
            guard expandedOutlines.contains(id) else { continue }
            for section in service.outline(for: id) {
                items.append(.section(pageID: id, section: section))
            }
        }
        return items
    }

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        switch item {
        case .page(let id):
            pageRow(id: id)
        case .section(let pageID, let section):
            sectionRow(pageID: pageID, section: section)
        }
    }

    /// The name a page goes by: its `#` title when it has one, otherwise its opening words.
    private func pageTitle(_ id: UUID) -> String {
        let text = service.text(for: id)
        if let title = MarkdownScript.documentTitle(from: text), !title.isEmpty {
            return title
        }
        return pagePreview(text)
    }

    private func pageRow(id: UUID) -> some View {
        let index = service.index(of: id) ?? 0
        let isPinned = service.isPinned(id)
        let hasOutline = !service.outline(for: id).isEmpty
        let isExpanded = expandedOutlines.contains(id)
        let isDone = service.isDone(id)
        return HStack(spacing: 5) {
            // The chevron is a button of its own, so opening the outline never moves the
            // selection off the page the operator is working on.
            if hasOutline {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        toggleOutline(id)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: sb(9), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: sb(12), height: sb(16))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide sections" : "Show sections")
            } else {
                Color.clear.frame(width: sb(12), height: sb(16))
            }

            Text("\(index + 1)")
                .font(.system(size: sb(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: sb(20), height: sb(20))
                .background(service.readPages.contains(index) ? Color.green.opacity(0.3) : Color.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: sb(5)))

            Text(pageTitle(id))
                .font(.system(size: sb(12)))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary)

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: sb(9)))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 0)

            checkbox(isDone: isDone, size: sb(12), help: isDone ? "Mark as not done" : "Mark as done") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    service.toggleDone(pageID: id)
                }
            }
        }
        .contentShape(Rectangle())
        .tag(id)
        .draggable(dragPayload(for: id))
        .dropDestination(for: String.self) { items, _ in
            movePages(items, before: id)
        }
        .contextMenu {
            pageMenu(for: id)
        }
    }

    private func sectionRow(pageID: UUID, section: ScriptSection) -> some View {
        let isCurrentPage = service.index(of: pageID) == service.currentPageIndex
        let isCurrent = isCurrentPage
            && !service.sections.isEmpty
            && service.currentSectionIndex == section.id
        let isRead = isCurrentPage && service.readSections.contains(section.id)
        let isDone = service.isDone(pageID: pageID, sectionTitle: section.title)
        return HStack(spacing: 6) {
            Text("\(section.id + 1).")
                .font(.system(size: sb(10), weight: .semibold, design: .monospaced))
                .foregroundStyle(isCurrent ? Color.accentColor : (isRead ? Color.green : Color.secondary.opacity(0.7)))
                .frame(minWidth: sb(15), alignment: .trailing)
            Text(section.title)
                .font(.system(size: sb(11), weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            checkbox(isDone: isDone, size: sb(11), help: isDone ? "Mark section as not done" : "Mark section as done") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    service.toggleDone(pageID: pageID, sectionTitle: section.title)
                }
            }
        }
        .padding(.leading, sb(21))
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(section.title)
        .selectionDisabled()
        .onTapGesture {
            openSection(pageID: pageID, section: section)
        }
    }

    /// The tick box on a sidebar row. A button of its own, so ticking something off never moves
    /// the selection or opens the page.
    private func checkbox(isDone: Bool, size: CGFloat = 12, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(isDone ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: size + 6, height: size + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleOutline(_ id: UUID) {
        if expandedOutlines.contains(id) {
            expandedOutlines.remove(id)
        } else {
            expandedOutlines.insert(id)
        }
    }

    /// Jumps to a section: mid-read the prompter starts reading it, otherwise the script pane
    /// scrolls to it and Play will pick up from there.
    private func openSection(pageID: UUID, section: ScriptSection) {
        if isRecording {
            stopRecording()
        }
        if let index = service.index(of: pageID), index != service.currentPageIndex {
            withAnimation(.easeInOut(duration: 0.15)) {
                service.currentPageIndex = index
            }
            selectedPageIDs = [pageID]
        }

        if isRunning {
            service.readSection(at: section.id)
        } else {
            service.refreshSections()
            if service.sections.indices.contains(section.id) {
                service.currentSectionIndex = section.id
            }
        }

        let location = section.headingRange?.location ?? 0
        if NotchSettings.shared.markdownPreviewEnabled && !isRunning {
            previewScrollTarget = location
        } else {
            editorScrollTarget = location
        }
    }

    /// Dragging a row inside a multi-selection carries the whole selection.
    private func dragPayload(for id: UUID) -> String {
        actionTargets(for: id).map(\.uuidString).joined(separator: " ")
    }

    @ViewBuilder
    private func pageMenu(for id: UUID) -> some View {
        let targets = actionTargets(for: id)
        let many = targets.count > 1
        let currentFolder = service.folder(containing: id)
        let allPinned = targets.allSatisfy { service.isPinned($0) }

        if !service.folders.isEmpty {
            Menu {
                ForEach(service.folders) { folder in
                    Button {
                        moveSelection(targets, to: folder.id)
                    } label: {
                        if !many && folder.id == currentFolder {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                Divider()
                Button("No Folder") {
                    moveSelection(targets, to: nil)
                }
            } label: {
                Label(many ? "Move \(targets.count) Pages to Folder" : "Move to Folder", systemImage: "folder")
            }
        }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                for target in targets {
                    if allPinned == service.isPinned(target) {
                        service.togglePin(pageID: target)
                    }
                }
            }
        } label: {
            Label(allPinned ? (many ? "Unpin Pages" : "Unpin Page") : (many ? "Pin Pages" : "Pin Page"),
                  systemImage: allPinned ? "pin.slash" : "pin")
        }

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                let allDone = targets.allSatisfy { service.isDone($0) }
                for target in targets where service.isDone(target) == allDone {
                    service.toggleDone(pageID: target)
                }
            }
        } label: {
            let allDone = targets.allSatisfy { service.isDone($0) }
            Label(allDone ? (many ? "Mark Pages Not Done" : "Mark Not Done")
                          : (many ? "Mark \(targets.count) Pages Done" : "Mark Done"),
                  systemImage: allDone ? "circle" : "checkmark.circle")
        }

        Button {
            newFolder(with: targets)
        } label: {
            Label(many ? "New Folder with \(targets.count) Pages" : "New Folder with Page",
                  systemImage: "folder.badge.plus")
        }

        if targets.count < service.pages.count {
            Divider()
            Button(role: .destructive) {
                requestDelete(targets)
            } label: {
                Label(many ? "Delete \(targets.count) Pages" : "Delete Page", systemImage: "trash")
            }
        }
    }

    private func startRenaming(_ folder: PageFolder) {
        folderNameDraft = folder.name
        renamingFolderID = folder.id
    }

    /// Deletes straight away when there is nothing to lose, and asks first when there is.
    /// The Delete key is easy to hit by accident and page deletion cannot be undone.
    private func requestDelete(_ ids: [UUID]) {
        let deletable = ids.filter { service.index(of: $0) != nil }
        guard !deletable.isEmpty, deletable.count < service.pages.count else { return }
        let hasContent = deletable.contains {
            !service.text(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasContent {
            pendingDeleteIDs = deletable
        } else {
            deletePages(deletable)
        }
    }

    private func deletePages(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.removePages(ids: ids)
        }
        selectedPageIDs = service.pageID(at: service.currentPageIndex).map { [$0] } ?? []
    }

    private var deleteAlertTitle: String {
        pendingDeleteIDs.count > 1 ? "Delete \(pendingDeleteIDs.count) Pages?" : "Delete Page?"
    }

    private var deleteAlertMessage: String {
        if pendingDeleteIDs.count > 1 {
            return "These pages have content that will be lost."
        }
        guard let id = pendingDeleteIDs.first, let index = service.index(of: id) else { return "" }
        return "Page \(index + 1) has content that will be lost.\n\n\(pagePreview(service.text(for: id)))"
    }

    private var deletingBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeleteIDs.isEmpty },
            set: { if !$0 { pendingDeleteIDs = [] } }
        )
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingFolderID != nil },
            set: { if !$0 { renamingFolderID = nil } }
        )
    }

    private func expansionBinding(for folder: PageFolder) -> Binding<Bool> {
        Binding(
            get: {
                service.folders.first { $0.id == folder.id }?.isExpanded ?? true
            },
            set: { newValue in
                guard let index = service.folders.firstIndex(where: { $0.id == folder.id }) else { return }
                service.folders[index].isExpanded = newValue
            }
        )
    }

    /// Handles a sidebar drop payload of page-ID strings.
    private func movePages(_ items: [String], to folderID: UUID?) -> Bool {
        let ids = decodeDrop(items)
        guard !ids.isEmpty else { return false }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.movePages(ids: ids, to: folderID)
        }
        return true
    }

    private func movePages(_ items: [String], before targetID: UUID) -> Bool {
        let ids = decodeDrop(items)
        guard !ids.isEmpty else { return false }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.movePages(ids: ids, before: targetID)
        }
        return true
    }

    private func decodeDrop(_ items: [String]) -> [UUID] {
        items
            .flatMap { $0.split(separator: " ") }
            .compactMap { UUID(uuidString: String($0)) }
    }

    private func moveSelection(_ ids: [UUID], to folderID: UUID?) {
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.movePages(ids: ids, to: folderID)
        }
    }

    private func newFolder(with pageIDs: [UUID] = []) {
        let name = "Folder \(service.folders.count + 1)"
        let folder = service.addFolder(named: name)
        if !pageIDs.isEmpty {
            service.movePages(ids: pageIDs, to: folder.id)
        }
        folderNameDraft = name
        renamingFolderID = folder.id
    }

    // MARK: - Actions

    private func removePage(at index: Int) {
        guard service.pages.count > 1 else { return }
        if isRecording {
            stopRecording()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.removePage(at: index)
        }
    }

    private func run() {
        guard hasAnyContent else { return }
        // Resign text editor focus before hiding the window to avoid ViewBridge crashes
        isTextFocused = false
        service.onOverlayDismissed = { [self] in
            isRunning = false
            service.readPages.removeAll()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        service.readPages.removeAll()
        // If the current page is empty, find the first non-empty page
        let currentText = service.currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentText.isEmpty {
            if let firstNonEmpty = service.pages.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                service.currentPageIndex = firstNonEmpty
            }
        }
        service.readCurrentPage()
        isRunning = true
    }

    @State private var isImporting = false

    private func handlePresentationDrop(url: URL) {
        guard service.confirmDiscardIfNeeded() else { return }
        if isRecording {
            stopRecording()
        }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    service.replacePages(notes)
                    service.savedPages = notes
                    service.currentFileURL = nil
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func stop() {
        followRange = nil
        service.overlayController.dismiss()
        service.readPages.removeAll()
        isRunning = false
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // App name & version
            VStack(spacing: 4) {
                Text("Textream")
                    .font(.system(size: 20, weight: .bold))
                Text("Version \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Description
            Text("A free, open-source teleprompter that highlights your script in real-time as you speak.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/f/textream")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("GitHub")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }

                Link(destination: URL(string: "https://donate.stripe.com/aFa8wO4NF2S96jDfn4dMI09")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.pink)
                        Text("Donate")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.pink.opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            Divider().padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text("Made by Fatih Kadir Akin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Original idea by Semih Kışlar")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button("OK") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    ContentView()
}

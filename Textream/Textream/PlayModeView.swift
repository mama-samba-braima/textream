//
//  PlayModeView.swift
//  Textream
//

import SwiftUI

/// What the talent is looking at, mirrored into the main window while a read is running.
///
/// The editor is useless mid-read, so this takes its place: the same script, the same live
/// highlight, on the same black ground as the prompter. It is also a control surface. Scrolling
/// it, tapping a word, or nudging with the arrows moves the read on every surface at once,
/// through the same scrub and seek path the phone remote uses.
struct PlayModeView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    /// Live position while dragging. Every surface follows, the recognizer is left alone.
    let onScrub: (Int) -> Void
    /// Settled position. The read resumes from here.
    let onSeek: (Int) -> Void

    /// Words a single arrow press moves the read by.
    private static let nudgeWords = 5

    @State private var timerWordProgress: Double = 0
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var words: [String] { content.words }
    private var totalCharCount: Int { content.totalCharCount }

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused: return speechRecognizer.isListening
        case .classic: return true
        }
    }

    /// Where the read currently sits. Mirrors the prompter's own calculation, including
    /// following a remote's scrub.
    private var effectiveCharCount: Int {
        if let scrub = content.scrubCharOffset { return scrub }
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    private func wordProgressForCharOffset(_ charOffset: Int) -> Double {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if charOffset <= end {
                let frac = Double(charOffset - offset) / Double(max(1, word.count))
                return Double(i) + frac
            }
            offset = end + 1
        }
        return Double(words.count)
    }

    var body: some View {
        GeometryReader { geo in
            let fontSize = max(16, min(34, geo.size.width / 26))

            ZStack {
                Color.black

                SpeechScrollView(
                    words: words,
                    lineBreaks: NotchSettings.shared.preserveLineBreaks ? content.lineBreaks : [:],
                    highlightedCharCount: effectiveCharCount,
                    font: .systemFont(ofSize: fontSize, weight: .semibold),
                    highlightColor: NotchSettings.shared.fontColorPreset.color,
                    cueColor: NotchSettings.shared.cueColorPreset.color,
                    cueUnreadOpacity: NotchSettings.shared.cueBrightness.unreadOpacity,
                    cueReadOpacity: NotchSettings.shared.cueBrightness.readOpacity,
                    onWordTap: { charOffset in
                        onSeek(charOffset)
                        timerWordProgress = wordProgressForCharOffset(charOffset)
                    },
                    onManualScroll: { scrolling, newProgress in
                        isUserScrolling = scrolling
                        let clamped = max(0, min(Double(words.count), newProgress))
                        let offset = charOffsetForWordProgress(clamped)
                        if scrolling {
                            onScrub(offset)
                        } else {
                            timerWordProgress = clamped
                            onSeek(offset)
                        }
                    },
                    smoothScroll: listeningMode != .wordTracking,
                    smoothWordProgress: timerWordProgress,
                    isListening: isEffectivelyListening
                )
                .padding(.horizontal, 28)
                .padding(.vertical, 16)

                nudgeControls
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear {
            timerWordProgress = wordProgressForCharOffset(effectiveCharCount)
        }
        .onChange(of: content.seekToken) { _, _ in
            timerWordProgress = wordProgressForCharOffset(content.seekCharOffset)
        }
        .onReceive(scrollTimer) { _ in
            guard !isUserScrolling else { return }
            let done = totalCharCount > 0 && charOffsetForWordProgress(timerWordProgress) >= totalCharCount
            guard !done else { return }
            let speed = NotchSettings.shared.scrollSpeed
            switch listeningMode {
            case .classic:
                timerWordProgress += speed * 0.05
            case .silencePaused:
                if speechRecognizer.isListening && speechRecognizer.isSpeaking {
                    timerWordProgress += speed * 0.05
                }
            case .wordTracking:
                break
            }
        }
    }

    private var nudgeControls: some View {
        VStack(spacing: 10) {
            nudgeButton(systemImage: "chevron.up", help: "Move the read back", words: -Self.nudgeWords)
            nudgeButton(systemImage: "chevron.down", help: "Move the read forward", words: Self.nudgeWords)
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func nudgeButton(systemImage: String, help: String, words delta: Int) -> some View {
        Button {
            nudge(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Moves the read by whole words, so a nudge always lands on a word boundary.
    private func nudge(by wordCount: Int) {
        let current = wordProgressForCharOffset(effectiveCharCount)
        let target = max(0, min(Double(words.count), (current.rounded() + Double(wordCount))))
        let offset = charOffsetForWordProgress(target)
        timerWordProgress = target
        onSeek(offset)
    }
}

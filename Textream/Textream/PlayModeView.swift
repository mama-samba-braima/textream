//
//  PlayModeView.swift
//  Textream
//

import SwiftUI

/// What the talent is looking at, mirrored into the main window while a read is running.
///
/// A true mirror: it renders the same view the prompter renders, at that surface's own size, then
/// scales the whole thing to fit the pane. Every wrap, every line break and every proportion is
/// therefore identical by construction rather than by imitation, which is what re-implementing the
/// layout could never guarantee.
///
/// It is also a control surface. Scrolling it, tapping a word, or nudging with the arrows moves the
/// read on every surface at once, through the same scrub and seek path the phone remote uses.
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
            let native = nativeSize
            // Scaling up a small overlay past 2x only softens it, so cap the enlargement.
            let scale = min(min(geo.size.width / native.width, geo.size.height / native.height), 2.0)

            ZStack {
                Color.black

                surface
                    .frame(width: native.width, height: native.height)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: native.width * scale, height: native.height * scale)
                    .clipped()
                    // The prompter's ground is black and so is the pane, so without this the
                    // edges of the monitor being mirrored are invisible.
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )

                nudgeControls
            }
        }
        .background(Color.black)
        .onAppear {
            timerWordProgress = wordProgressForCharOffset(effectiveCharCount)
        }
        .onChange(of: content.seekToken) { _, _ in
            timerWordProgress = wordProgressForCharOffset(content.seekCharOffset)
        }
        .onReceive(scrollTimer) { _ in
            // A shadow of the prompter's own timer, kept only so the arrows know where the read
            // currently is. Any seek resyncs it, so it cannot drift far.
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

    /// The live prompter view for whichever surface the talent is actually reading from.
    @ViewBuilder
    private var surface: some View {
        if isExternal {
            // Deliberately unmirrored: a beam splitter flips the image back for the talent, and a
            // flipped monitor is unreadable for the operator.
            ExternalDisplayView(
                content: TextreamService.shared.externalDisplayController.overlayContent,
                speechRecognizer: speechRecognizer,
                mirrorAxis: nil
            )
        } else {
            FloatingOverlayView(
                content: content,
                speechRecognizer: speechRecognizer,
                baseHeight: NotchSettings.shared.textAreaHeight
            )
        }
    }

    /// True once the external display has a script to show, so the mirror follows the field
    /// monitor rather than the notch.
    private var isExternal: Bool {
        NotchSettings.shared.externalDisplayMode != .off
            && !TextreamService.shared.externalDisplayController.overlayContent.words.isEmpty
    }

    /// The size the mirrored surface really is, so the mirror is a scaled copy of it.
    private var nativeSize: CGSize {
        if isExternal {
            let screen = TextreamService.shared.externalDisplayController.targetScreen()
            return screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        }
        return CGSize(
            width: NotchSettings.shared.notchWidth,
            height: NotchSettings.shared.textAreaHeight
        )
    }

    private var nudgeControls: some View {
        VStack(spacing: 10) {
            nudgeButton(
                systemImage: "chevron.up",
                help: "Move the read back (↑)",
                key: .upArrow,
                words: -Self.nudgeWords
            )
            nudgeButton(
                systemImage: "chevron.down",
                help: "Move the read forward (↓)",
                key: .downArrow,
                words: Self.nudgeWords
            )
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    /// The arrow keys are bound to the buttons themselves, so they are live exactly as long as
    /// this view is: during a read, and never while the editor has the window.
    private func nudgeButton(systemImage: String, help: String, key: KeyEquivalent, words delta: Int) -> some View {
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
        .keyboardShortcut(key, modifiers: [])
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

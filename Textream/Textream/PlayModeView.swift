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
    /// True when the mirror has the whole pane, false when it shares it with the script.
    var isExpanded: Bool = false
    /// False when nothing is being read: the pane stands by, showing the section that play would
    /// start, with a play button where stop lives during a take.
    var isRunning: Bool = true
    /// Starts the read. The pane is the transport, idle or not.
    var onPlay: (() -> Void)? = nil
    /// Live position while dragging. Every surface follows, the recognizer is left alone.
    let onScrub: (Int) -> Void
    /// Settled position. The read resumes from here.
    let onSeek: (Int) -> Void
    var onToggleExpand: (() -> Void)? = nil
    /// Ends the read. Lives here so it sits centred on the mirror in both layouts, rather than on
    /// the divider between the script and the mirror.
    var onStop: (() -> Void)? = nil
    /// Reports the word being read, so the script can follow along beside the mirror.
    var onWordIndexChange: ((Int) -> Void)? = nil

    /// Words a single arrow press moves the read by.
    private static let nudgeWords = 5

    @ObservedObject private var service = TextreamService.shared
    @State private var timerWordProgress: Double = 0
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    /// The live read, or the standing preview of what play would start.
    private var activeContent: OverlayContent {
        isRunning ? content : service.previewContent
    }

    private var words: [String] { activeContent.words }
    private var totalCharCount: Int { activeContent.totalCharCount }

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
        guard isRunning else { return 0 }
        if let scrub = content.scrubCharOffset { return scrub }
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    /// The word the read is on, which is what the script pane follows.
    private var currentWordIndex: Int {
        max(0, Int(wordProgressForCharOffset(effectiveCharCount)))
    }

    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<max(0, min(wholeWord, words.count)) {
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
        VStack(spacing: 0) {
            sectionHeader
            mirror
            readoutRow
        }
    }

    /// How far through the section the read is, right along the top edge, then which section it
    /// is. Only the section being read is named: the rest of the script is the sidebar's job, and
    /// a strip of every heading is one more thing to look past.
    private var sectionHeader: some View {
        VStack(spacing: 6) {
            if service.sections.indices.contains(service.currentSectionIndex) {
                Text(service.sections[service.currentSectionIndex].title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)

                Text("\(service.currentSectionIndex + 1)/\(service.sections.count)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.bottom, service.sections.isEmpty ? 0 : 12)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    /// Under the mirror: how much of this section is behind you, as a number. The bar above says
    /// the same thing at a glance; this says it exactly, which is what you want when deciding
    /// whether to push on or go again.
    private var readoutRow: some View {
        Text("\(percentComplete)%")
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(Color.black)
    }

    /// True when the read has reached the end of the section.
    private var isFinished: Bool {
        isRunning && totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    private var percentComplete: Int {
        guard totalCharCount > 0 else { return 0 }
        let fraction = Double(effectiveCharCount) / Double(totalCharCount)
        return Int((min(1, max(0, fraction)) * 100).rounded())
    }

    private var mirror: some View {
        GeometryReader { geo in
            let surfaceSize = nativeSize
            // Width is matched exactly, since band width and font size decide where lines wrap and
            // the mirror is worthless if it wraps differently from the monitor. Height is stretched
            // to whatever the pane offers, which is free look-ahead: the same read, more of the
            // script visible than the monitor can show.
            let widthScale = min(geo.size.width / surfaceSize.width, 2.5)
            // Stretch only when the pane is taller than the surface. In a short pane, matching the
            // width would crop the monitor's own top and bottom away, so fit instead.
            let canStretch = geo.size.height / widthScale >= surfaceSize.height
            let scale = canStretch ? widthScale : min(widthScale, geo.size.height / surfaceSize.height)
            let virtualHeight = max(surfaceSize.height, geo.size.height / scale)

            ZStack {
                Color.black

                surface
                    .frame(width: surfaceSize.width, height: virtualHeight)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if isRunning {
                    nudgeControls
                }
                expandControl
                sectionFooter
                stopControl
            }
        }
        .background(Color.black)
        .onAppear {
            timerWordProgress = wordProgressForCharOffset(effectiveCharCount)
        }
        .onChange(of: content.seekToken) { _, _ in
            timerWordProgress = wordProgressForCharOffset(content.seekCharOffset)
        }
        .onChange(of: currentWordIndex) { _, index in
            onWordIndexChange?(index)
        }
        .onReceive(scrollTimer) { _ in
            // A shadow of the prompter's own timer, kept only so the arrows know where the read
            // currently is. Any seek resyncs it, so it cannot drift far.
            guard isRunning, !isUserScrolling, !content.isPaused else { return }
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
                content: isRunning
                    ? TextreamService.shared.externalDisplayController.overlayContent
                    : service.previewContent,
                speechRecognizer: speechRecognizer,
                mirrorAxis: nil,
                showsMeter: false,
                isLive: isRunning,
                showsClock: false,
                showsDoneBar: false
            )
        } else {
            FloatingOverlayView(
                content: activeContent,
                speechRecognizer: speechRecognizer,
                baseHeight: NotchSettings.shared.textAreaHeight,
                isLive: isRunning,
                showsClock: false
            )
        }
    }

    /// True once the external display has a script to show, so the mirror follows the field
    /// monitor rather than the notch.
    private var isExternal: Bool {
        guard NotchSettings.shared.externalDisplayMode != .off else { return false }
        // Standing by, there is no live surface to follow, so show the one play would use.
        guard isRunning else { return true }
        return !TextreamService.shared.externalDisplayController.overlayContent.words.isEmpty
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

    /// Section stepping lives on the arrow keys. These carry the shortcuts without taking up any
    /// room, since a shortcut has to hang off a button to be live.
    @ViewBuilder
    private var sectionFooter: some View {
        // Only during a take. Standing by, the cursor is in the script, and a bare arrow key
        // belongs to whoever is typing.
        if isRunning && !service.sections.isEmpty {
            HStack(spacing: 0) {
                sectionKey(.leftArrow, enabled: service.hasPreviousSection) {
                    service.goToPreviousSection()
                }
                sectionKey(.rightArrow, enabled: service.hasNextSection) {
                    service.advanceToNextSection()
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    private func sectionKey(_ key: KeyEquivalent, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(key, modifiers: [])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The transport, at the foot of the mirror where the hand goes: play when standing by, stop
    /// and its neighbours during a take. One dock, one place, whatever the state.
    ///
    /// Built as Excalidraw builds a toolbar: uniform icon only cells on a floating slab, the tool
    /// you are meant to reach for filled with the accent colour, the one that ends things drawn in
    /// red, and the bare key shortcuts printed in the corner of the cells that have them.
    @ViewBuilder
    private var stopControl: some View {
        if !isRunning {
            if let onPlay {
                // Standing by there is one thing to press, and one thing is not a toolbar. A slab
                // around a single cell reads as a button inside a box, so play keeps the bare
                // accent circle it has always had and the dock appears when the take does.
                Button(action: onPlay) {
                    ZStack {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "play.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .offset(x: 1.5)
                    }
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .help(service.sections.isEmpty
                      ? "Start reading this page"
                      : "Start reading section \(service.currentSectionIndex + 1)")
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        } else if let onStop {
            VStack(spacing: 10) {
                // The clock belongs with the hand that stops the take, not in a far corner.
                if NotchSettings.shared.showElapsedTime {
                    ElapsedTimeView(fontSize: 16)
                }

                FloatingDock(tone: .dark, size: transportUnit) {
                    // Section stepping used to exist only on the arrow keys, with nothing on
                    // screen to say so. On a badged dock it can be both: a cell to press and the
                    // key printed on it.
                    if !service.sections.isEmpty {
                        DockButton(
                            systemImage: "chevron.left",
                            help: "Back to the previous section",
                            shortcut: "\u{2190}",
                            isDisabled: !service.hasPreviousSection,
                            tone: .dark,
                            size: transportUnit,
                            action: { service.goToPreviousSection() }
                        )
                        DockButton(
                            systemImage: "chevron.right",
                            help: "On to the next section",
                            shortcut: "\u{2192}",
                            isDisabled: !service.hasNextSection,
                            tone: .dark,
                            size: transportUnit,
                            action: { service.advanceToNextSection() }
                        )
                        DockDivider(tone: .dark, size: transportUnit)
                    }

                    DockButton(
                        systemImage: "arrow.counterclockwise",
                        help: "Read this section again from the top",
                        tone: .dark,
                        size: transportUnit,
                        action: { service.restartCurrentRead() }
                    )

                    // Holding a take is as much a part of the job as ending one, so it gets a
                    // cell the same size as stop rather than a smaller target beside it.
                    DockButton(
                        systemImage: service.isReadPaused ? "play.fill" : "pause.fill",
                        help: service.isReadPaused ? "Carry on reading" : "Hold the read here",
                        tint: service.isReadPaused ? .yellow.opacity(0.9) : .white,
                        tone: .dark,
                        size: transportUnit,
                        action: { service.togglePause() }
                    )

                    DockButton(
                        systemImage: "stop.fill",
                        help: "Stop the read",
                        isDestructive: true,
                        tone: .dark,
                        size: transportUnit,
                        action: onStop
                    )

                    // Only at the end of a section, and only if there is somewhere to go. Filled,
                    // because at that moment it is the only thing worth pressing.
                    if isFinished && service.hasNextChunk {
                        DockButton(
                            systemImage: "forward.end.fill",
                            help: content.nextIsSection ? "Read the next section" : "Read the next page",
                            isEmphasized: true,
                            tone: .dark,
                            size: transportUnit,
                            action: { speechRecognizer.shouldAdvancePage = true }
                        )
                    }

                    if listeningMode != .classic {
                        DockDivider(tone: .dark, size: transportUnit)
                        DockButton(
                            systemImage: speechRecognizer.isListening ? "mic.fill" : "mic.slash.fill",
                            help: speechRecognizer.isListening ? "Stop listening" : "Start listening",
                            tint: speechRecognizer.isListening ? .yellow.opacity(0.9) : .white.opacity(0.45),
                            tone: .dark,
                            size: transportUnit,
                            action: {
                                if speechRecognizer.isListening {
                                    speechRecognizer.stop()
                                } else {
                                    speechRecognizer.resume()
                                }
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /// The unit the transport dock is built from. Bigger than the writing side's, because this is
    /// the pane a hand reaches for mid-take without looking down.
    private var transportUnit: CGFloat { 26 }

    @ViewBuilder
    private var expandControl: some View {
        if let onToggleExpand {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show the script alongside" : "Fill the pane with the mirror")
            // Bottom right: the mirrored prompter puts its own timer top left and its mic top
            // right, and this must not sit on top of either.
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
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

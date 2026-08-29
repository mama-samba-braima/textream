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
    /// Live position while dragging. Every surface follows, the recognizer is left alone.
    let onScrub: (Int) -> Void
    /// Settled position. The read resumes from here.
    let onSeek: (Int) -> Void
    var onToggleExpand: (() -> Void)? = nil

    /// Words a single arrow press moves the read by.
    private static let nudgeWords = 5

    @ObservedObject private var service = TextreamService.shared
    /// Which chip the strip is parked on. Scrolling the bar never moves the read.
    @State private var scrollAnchor: Int = 0
    @State private var qrEnlarged = false
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
        VStack(spacing: 0) {
            if !service.sections.isEmpty {
                sectionBar
            }
            if let remoteURL = RemoteConnection.url {
                remoteStrip(url: remoteURL)
            }
            mirror
        }
    }

    /// The address to scan to drive the prompter from a phone, kept where the operator is already
    /// looking rather than buried in Settings. Only appears while the remote server is running.
    private func remoteStrip(url: String) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if let qr = RemoteConnection.qrCode(for: url) {
                // Smoothed rather than nearest-neighbour: at these sizes the code is scaled by a
                // fraction, and point sampling both biases it off centre and drops modules, which
                // is the one thing a code being scanned cannot afford.
                Image(nsImage: qr)
                    .resizable()
                    .scaledToFit()
                    .frame(width: qrSize, height: qrSize)
                    .frame(width: qrSize + 8, height: qrSize + 8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Scan to control from your phone")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                Text(url)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    qrEnlarged.toggle()
                }
            } label: {
                Image(systemName: qrEnlarged ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(qrEnlarged ? "Shrink the code" : "Enlarge the code to scan from further away")
            .padding(.trailing, 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var qrSize: CGFloat { qrEnlarged ? 96 : 44 }

    /// Every section of the script, in order, so the read can be started anywhere. The current one
    /// is marked, and sections already read are ticked, which is the whole state of a take at a
    /// glance.
    private var sectionBar: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                scrollArrow(systemImage: "chevron.left", step: -1, proxy: proxy)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(service.sections) { section in
                            sectionChip(section)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                }

                scrollArrow(systemImage: "chevron.right", step: 1, proxy: proxy)
            }
            .background(Color.black)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(height: 1)
            }
            .onAppear { scrollAnchor = service.currentSectionIndex }
            .onChange(of: service.currentSectionIndex) { _, index in
                scrollAnchor = index
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    /// Walks the strip without moving the read, for reaching a section that is off screen.
    private func scrollArrow(systemImage: String, step: Int, proxy: ScrollViewProxy) -> some View {
        let target = scrollAnchor + step
        let enabled = service.sections.indices.contains(target)

        return Button {
            guard service.sections.indices.contains(scrollAnchor + step) else { return }
            scrollAnchor += step
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(scrollAnchor, anchor: .center)
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.75 : 0.2))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(step > 0 ? "Scroll to later sections" : "Scroll to earlier sections")
    }

    private func sectionChip(_ section: ScriptSection) -> some View {
        let isCurrent = section.id == service.currentSectionIndex
        let isRead = service.readSections.contains(section.id)

        return Button {
            service.readSection(at: section.id)
        } label: {
            HStack(spacing: 5) {
                if isRead && !isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
                Text(section.title)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isCurrent ? Color.accentColor : Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "Playing this section" : "Play from this section")
    }

    private var mirror: some View {
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
                expandControl
                sectionFooter
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

    /// Where the read stands, and the way on to the next section once this one is finished.
    @ViewBuilder
    private var sectionFooter: some View {
        if !service.sections.isEmpty {
            HStack(spacing: 10) {
                Text("Section \(service.currentSectionIndex + 1) of \(service.sections.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                if service.hasNextSection {
                    Button {
                        service.advanceToNextSection()
                    } label: {
                        HStack(spacing: 5) {
                            Text("Next Section")
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Start the next section (→)")
                }
            }
            .padding(.leading, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

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

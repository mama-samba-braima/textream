//
//  ExternalDisplayController.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import SwiftUI
import Combine

class ExternalDisplayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    let overlayContent = OverlayContent()

    /// Find the target external screen based on saved screen ID, or first non-main screen
    func targetScreen() -> NSScreen? {
        let settings = NotchSettings.shared
        let screens = NSScreen.screens.filter { $0 != NSScreen.main }
        guard !screens.isEmpty else { return nil }

        // Try to find saved screen
        if settings.externalScreenID != 0 {
            if let match = screens.first(where: { $0.displayID == settings.externalScreenID }) {
                return match
            }
        }
        return screens.first
    }

    func show(speechRecognizer: SpeechRecognizer, words: [String], lineBreaks: [Int: Int] = [:], totalCharCount: Int, hasNextPage: Bool = false) {
        let settings = NotchSettings.shared
        guard settings.externalDisplayMode != .off else { return }
        guard let screen = targetScreen() else { return }

        dismiss()

        overlayContent.words = words
        overlayContent.lineBreaks = lineBreaks
        overlayContent.totalCharCount = totalCharCount
        overlayContent.hasNextPage = hasNextPage

        let mirrorAxis = settings.externalDisplayMode == .mirror ? settings.mirrorAxis : nil
        let screenFrame = screen.frame

        let content = ExternalDisplayView(
            content: overlayContent,
            speechRecognizer: speechRecognizer,
            mirrorAxis: mirrorAxis
        )

        let hostingView = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.setFrame(screenFrame, display: true)
        panel.orderFront(nil)
        self.panel = panel

        // Poll for dismiss signal
        Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, speechRecognizer.shouldDismiss else { return }
                self.cancellables.removeAll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.dismiss()
                }
            }
            .store(in: &cancellables)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        cancellables.removeAll()
    }
}

// MARK: - NSScreen extension to get display ID

extension NSScreen {
    var displayID: UInt32 {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return screenNumber.uint32Value
    }

    var displayName: String {
        return localizedName
    }
}

// MARK: - Lens Metrics

/// Geometry of the external prompter "lens": the padded band the scrolling text is confined to.
///
/// Padding is stored as a percentage of the screen edge it insets, so the same setting frames the
/// text identically on any display. Text is clipped to this band, which keeps eye movement inside
/// the small window a beam-splitter lens actually shows on camera.
struct ExternalLensMetrics {
    /// Padding on each side, in points.
    let hPad: CGFloat
    /// Padding on the top and bottom, in points.
    let vPad: CGFloat
    /// Width of the visible text band, in points.
    let lensWidth: CGFloat
    /// Prompter font size that fits the band.
    let fontSize: CGFloat

    /// Screen-corner inset for the elapsed timer, which sits outside the lens padding.
    static let timerInset = CGSize(width: 40, height: 20)
    /// Point size of the elapsed timer on the external display.
    static let timerFontSize: CGFloat = 44
    /// Height of the progress bar along the bottom edge.
    static let progressHeight: CGFloat = 26
    /// Gap between that bar and the edges of the screen.
    static let progressInset: CGFloat = 26

    init(screenSize: CGSize, paddingH: Double, paddingV: Double) {
        let clampedH = min(max(paddingH, 0), NotchSettings.maxExternalPadding)
        let clampedV = min(max(paddingV, 0), NotchSettings.maxExternalPadding)
        hPad = screenSize.width * CGFloat(clampedH) / 100
        vPad = screenSize.height * CGFloat(clampedV) / 100
        lensWidth = max(1, screenSize.width - hPad * 2)
        fontSize = max(24, min(96, lensWidth / 14))
    }

    init(screenSize: CGSize, settings: NotchSettings = .shared) {
        self.init(
            screenSize: screenSize,
            paddingH: settings.externalPaddingH,
            paddingV: settings.externalPaddingV
        )
    }
}

// MARK: - External Display SwiftUI View

struct ExternalDisplayView: View {
    @Bindable var content: OverlayContent
    @Bindable var speechRecognizer: SpeechRecognizer
    let mirrorAxis: MirrorAxis?
    /// The meter along the bottom edge. Off when this view is being mirrored into the app window,
    /// which has a progress bar of its own and does not need two.
    var showsMeter: Bool = true
    /// False when this is a standing preview of what pressing play would read, rather than a live
    /// read: it shows the script from the top and nothing moves it.
    var isLive: Bool = true

    private var words: [String] { content.words }
    private var lineBreaks: [Int: Int] {
        NotchSettings.shared.preserveLineBreaks ? content.lineBreaks : [:]
    }
    private var totalCharCount: Int { content.totalCharCount }
    private var hasNextPage: Bool { content.hasNextPage }

    // Timer-based scroll for classic & silence-paused modes
    @State private var timerWordProgress: Double = 0
    @State private var isUserScrolling: Bool = false
    private let scrollTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var listeningMode: ListeningMode {
        NotchSettings.shared.listeningMode
    }

    /// Convert fractional word index to char offset using actual word lengths
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

    /// Convert char offset back to fractional word index (for taps)
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

    private var effectiveCharCount: Int {
        // A preview always sits at the top of the section: nothing has been read yet.
        guard isLive else { return 0 }
        // While a remote is scrubbing, every surface follows the scrub position
        if let scrub = content.scrubCharOffset { return scrub }
        switch listeningMode {
        case .wordTracking:
            return speechRecognizer.recognizedCharCount
        case .classic, .silencePaused:
            return charOffsetForWordProgress(timerWordProgress)
        }
    }

    var isDone: Bool {
        totalCharCount > 0 && effectiveCharCount >= totalCharCount
    }

    private var isEffectivelyListening: Bool {
        switch listeningMode {
        case .wordTracking, .silencePaused:
            return speechRecognizer.isListening
        case .classic:
            return true
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            prompterView
        }
        .overlay(alignment: .bottom) {
            doneBar
        }
        .overlay(alignment: .topLeading) {
            // The clock times a take. Standing by, there is nothing to time.
            if isLive && NotchSettings.shared.showElapsedTime {
                // Deliberately outside the lens padding: the timer belongs in the corner of the
                // screen, not in the band the talent is reading from.
                ElapsedTimeView(fontSize: ExternalLensMetrics.timerFontSize)
                    .padding(.top, ExternalLensMetrics.timerInset.height)
                    .padding(.leading, ExternalLensMetrics.timerInset.width)
            }
        }
        .scaleEffect(x: mirrorAxis?.scaleX ?? 1, y: mirrorAxis?.scaleY ?? 1)
        .animation(.easeInOut(duration: 0.5), value: isDone)
        .onChange(of: isDone) { _, done in
            if done && listeningMode == .wordTracking {
                speechRecognizer.stop()
            }
        }
        .onReceive(scrollTimer) { _ in
            guard isLive, !isDone, !isUserScrolling else { return }
            let speed = NotchSettings.shared.scrollSpeed // words per second
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
        .onChange(of: content.seekToken) { _, _ in
            timerWordProgress = wordProgressForCharOffset(content.seekCharOffset)
        }
    }

    private var prompterView: some View {
        GeometryReader { geo in
            let lens = ExternalLensMetrics(screenSize: geo.size)

            ZStack {
                // The script, confined to the lens band
                SpeechScrollView(
                    words: words,
                    lineBreaks: lineBreaks,
                    highlightedCharCount: effectiveCharCount,
                    font: .systemFont(ofSize: lens.fontSize, weight: .semibold),
                    highlightColor: NotchSettings.shared.fontColorPreset.color,
                    cueColor: NotchSettings.shared.cueColorPreset.color,
                    cueUnreadOpacity: NotchSettings.shared.cueBrightness.unreadOpacity,
                    cueReadOpacity: NotchSettings.shared.cueBrightness.readOpacity,
                    onWordTap: { charOffset in
                        guard isLive else { return }
                        // Through the service, so every surface lands on the same word
                        timerWordProgress = wordProgressForCharOffset(charOffset)
                        TextreamService.shared.seek(toCharOffset: charOffset)
                    },
                    onManualScroll: { scrolling, newProgress in
                        guard isLive else { return }
                        isUserScrolling = scrolling
                        let clamped = max(0, min(Double(words.count), newProgress))
                        let offset = charOffsetForWordProgress(clamped)
                        if scrolling {
                            TextreamService.shared.scrub(toCharOffset: offset)
                        } else {
                            timerWordProgress = clamped
                            TextreamService.shared.seek(toCharOffset: offset)
                        }
                    },
                    smoothScroll: listeningMode != .wordTracking,
                    smoothWordProgress: timerWordProgress,
                    isListening: isEffectivelyListening
                )
                .padding(.horizontal, lens.hPad)
                .padding(.vertical, lens.vPad)

                // Everything below sits outside the lens padding, on the black the talent
                // cannot see through the glass, where it has room to be read at a glance.

                if listeningMode == .wordTracking {
                    Text(speechRecognizer.lastSpokenText.split(separator: " ").suffix(6).joined(separator: " "))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.leading, ExternalLensMetrics.timerInset.width)
                        .padding(.bottom, ExternalLensMetrics.progressHeight + 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                if showsMeter {
                    // The same shape as the app's stepper, so a glance at either screen reads the
                    // same way.
                    GeometryReader { bar in
                        let progress = totalCharCount > 0
                            ? min(1, max(0, Double(effectiveCharCount) / Double(totalCharCount)))
                            : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(ExternalLensMetrics.progressHeight, bar.size.width * progress))
                        }
                    }
                    .frame(height: ExternalLensMetrics.progressHeight)
                    .padding(.horizontal, ExternalLensMetrics.progressInset)
                    .padding(.bottom, ExternalLensMetrics.progressInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private var isFinished: Bool {
        isLive && isDone && (listeningMode == .wordTracking || hasNextPage)
    }

    /// The end of a read: what comes next, along the foot of the screen rather than in place of
    /// the script. The last line is the one most likely to be read again, and it cannot be read
    /// if the button has taken the screen.
    @ViewBuilder
    private var doneBar: some View {
        if isFinished {
            VStack(spacing: 0) {
                // Fades the script out under the control instead of cutting it off, so the words
                // above stay readable right up to it.
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 72)
                .allowsHitTesting(false)

                doneControls
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, doneBarInset)
                    .background(Color.black.opacity(0.92))
            }
            .transition(.opacity)
        }
    }

    /// Clear of the progress meter along the bottom edge, when there is one.
    private var doneBarInset: CGFloat {
        showsMeter
            ? ExternalLensMetrics.progressInset * 2 + ExternalLensMetrics.progressHeight
            : 20
    }

    @ViewBuilder
    private var doneControls: some View {
        if hasNextPage {
            Button {
                speechRecognizer.shouldAdvancePage = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold))
                    Text(content.nextIsSection ? "Next Section" : "Next Page")
                        .font(.system(size: 22, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 12)
        }
    }
}

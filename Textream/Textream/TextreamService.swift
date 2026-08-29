//
//  TextreamService.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A named group of pages in the sidebar. Membership is by page ID, order is explicit.
struct PageFolder: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var pageIDs: [UUID] = []
    var isExpanded: Bool = true
    /// Pinned folders float above unpinned ones.
    var isPinned: Bool = false

    init(id: UUID = UUID(), name: String, pageIDs: [UUID] = [], isExpanded: Bool = true, isPinned: Bool = false) {
        self.id = id
        self.name = name
        self.pageIDs = pageIDs
        self.isExpanded = isExpanded
        self.isPinned = isPinned
    }

    // Decoded field by field so documents written before a field existed still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        pageIDs = try container.decodeIfPresent([UUID].self, forKey: .pageIDs) ?? []
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

/// On-disk shape of a `.textream` file that uses folders.
///
/// Documents without folders are still written as a bare array of strings, the format every
/// released version of Textream reads, so organising pages never costs file compatibility.
private struct TextreamDocument: Codable {
    var version: Int = 2
    var pages: [String]
    var pageIDs: [UUID]
    var folders: [PageFolder]
    var pinnedPageIDs: [UUID] = []

    init(pages: [String], pageIDs: [UUID], folders: [PageFolder], pinnedPageIDs: [UUID]) {
        self.pages = pages
        self.pageIDs = pageIDs
        self.folders = folders
        self.pinnedPageIDs = pinnedPageIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        pages = try container.decode([String].self, forKey: .pages)
        pageIDs = try container.decode([UUID].self, forKey: .pageIDs)
        folders = try container.decodeIfPresent([PageFolder].self, forKey: .folders) ?? []
        pinnedPageIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedPageIDs) ?? []
    }
}

/// Everything needed to reopen exactly where the last session left off.
///
/// Written continuously to ~/.textream so that quitting, crashing or replacing the app never
/// costs work. Saving to a .textream file stays a separate, deliberate act.
private struct SessionSnapshot: Codable {
    var version: Int = 1
    var pages: [String]
    var pageIDs: [UUID]
    var folders: [PageFolder]
    var pinnedPageIDs: [UUID]
    var currentPageIndex: Int

    init(pages: [String], pageIDs: [UUID], folders: [PageFolder], pinnedPageIDs: [UUID], currentPageIndex: Int) {
        self.pages = pages
        self.pageIDs = pageIDs
        self.folders = folders
        self.pinnedPageIDs = pinnedPageIDs
        self.currentPageIndex = currentPageIndex
    }

    // Field by field, so a snapshot written by an older build still restores.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pages = try container.decode([String].self, forKey: .pages)
        pageIDs = try container.decodeIfPresent([UUID].self, forKey: .pageIDs) ?? []
        folders = try container.decodeIfPresent([PageFolder].self, forKey: .folders) ?? []
        pinnedPageIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedPageIDs) ?? []
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
    }
}

class TextreamService: NSObject, ObservableObject {
    static let shared = TextreamService()
    let overlayController = NotchOverlayController()
    let externalDisplayController = ExternalDisplayController()
    let browserServer = BrowserServer()
    let directorServer = DirectorServer()
    var onOverlayDismissed: (() -> Void)?
    var launchedExternally = false
    @Published var directorIsReading = false

    override init() {
        super.init()
        restoreSession()
        startAutosave()
        // Establish the file on first launch, so its absence always means a real problem
        // rather than "nothing has changed yet".
        DispatchQueue.main.async { [weak self] in
            self?.saveSession()
        }
    }

    @Published var pages: [String] = [""]
    /// Stable identity per page, parallel to `pages`. Folders reference pages by ID so that
    /// inserting, deleting or regrouping never corrupts membership the way indices would.
    @Published private(set) var pageIDs: [UUID] = [UUID()]
    /// Folders, in sidebar order. Their pages come first in the running order, ungrouped pages last.
    @Published var folders: [PageFolder] = []
    /// Expansion of the ungrouped "Pages" section. Owned here, not left to SwiftUI, so that adding
    /// a page can open the section it lands in.
    @Published var ungroupedIsExpanded: Bool = true
    /// Pages pinned to the top of the section they live in.
    @Published var pinnedPageIDs: Set<UUID> = []
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []
    /// Markdown `##` sections of the current page. Empty when the page has no headings, in which
    /// case the page is read whole, exactly as before.
    @Published var sections: [ScriptSection] = []
    @Published var currentSectionIndex: Int = 0
    @Published var readSections: Set<Int> = []

    var hasNextPage: Bool {
        for i in (currentPageIndex + 1)..<pages.count {
            if !pages[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    var currentPageText: String {
        guard currentPageIndex < pages.count else { return "" }
        return pages[currentPageIndex]
    }

    /// Starts a read.
    ///
    /// `fromExternalSource` marks a read handed to the app from outside, by the Services menu or a
    /// textream:// URL, where there is no document window to work in and the app should get out of
    /// the way. A read started from the app's own window is the opposite case: the window is the
    /// operator's monitor and control surface, so it stays up and in front.
    func readText(_ text: String, fromExternalSource: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if fromExternalSource {
            launchedExternally = true
            hideMainWindow()
        } else {
            keepMainWindowInFront()
        }

        overlayController.show(text: trimmed, hasNextPage: hasNextChunk) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        let nextIsSection = hasNextSection
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.nextIsSection = nextIsSection
        }

        // Also show on external display if configured (same parsing as overlay)
        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        let totalCharCount = words.joined(separator: " ").count
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            lineBreaks: tokenized.breaksBefore,
            totalCharCount: totalCharCount,
            hasNextPage: hasNextChunk
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                lineBreaks: tokenized.breaksBefore,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextChunk
            )
        }
    }

    func readCurrentPage() {
        refreshSections()
        if !sections.isEmpty {
            readSection(at: min(currentSectionIndex, sections.count - 1))
            return
        }
        let trimmed = MarkdownScript.plainText(from: currentPageText)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
        // Sections come first: a page is only finished once its last section is
        if hasNextSection {
            advanceToNextSection()
            return
        }
        // Skip empty pages
        var nextIndex = currentPageIndex + 1
        while nextIndex < pages.count {
            let text = pages[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { break }
            nextIndex += 1
        }
        guard nextIndex < pages.count else { return }
        jumpToPage(index: nextIndex)
    }

    func jumpToPage(index: Int) {
        guard index >= 0 && index < pages.count else { return }
        let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Mute mic before switching page content
        let wasListening = overlayController.speechRecognizer.isListening
        if wasListening {
            overlayController.speechRecognizer.stop()
        }

        currentPageIndex = index
        readPages.insert(currentPageIndex)

        // A new page starts at its first section, with its own progress
        currentSectionIndex = 0
        readSections.removeAll()
        refreshSections()
        if !sections.isEmpty {
            readSections.insert(0)
        }

        let trimmed = currentReadingText
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextChunk)
        updatePageInfo()

        // Also update external display content in-place
        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.lineBreaks = tokenized.breaksBefore
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextChunk
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.nextIsSection = hasNextSection
        }

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                lineBreaks: tokenized.breaksBefore,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextChunk
            )
        }

        // Unmute after new page content is loaded
        if wasListening {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let recognizer = self?.overlayController.speechRecognizer,
                      !recognizer.isListening,
                      !recognizer.isStarting else { return }
                recognizer.resume()
            }
        }
    }

    func updatePageInfo() {
        let content = overlayController.overlayContent
        content.pageCount = pages.count
        content.currentPageIndex = currentPageIndex
        content.pagePreviews = pages.enumerated().map { (i, text) in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let preview = String(trimmed.prefix(40))
            return preview + (trimmed.count > 40 ? "…" : "")
        }
    }

    func startAllPages() {
        readPages.removeAll()
        currentPageIndex = 0
        readCurrentPage()
    }

    /// Keeps the document window up and frontmost when a read starts from it. The overlay panels
    /// are non-activating, so the window stays key and the mirror stays watchable.
    func keepMainWindowInFront() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hideMainWindow() {
        DispatchQueue.main.async {
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
            }
        }
    }

    @Published var currentFileURL: URL?
    @Published var savedPages: [String] = [""]

    // MARK: - Script Sections

    /// The text actually being read: the current section when the page has headings, the whole
    /// page otherwise. Either way Markdown syntax is stripped, so no `#` ever reaches the screen.
    var currentReadingText: String {
        if sections.indices.contains(currentSectionIndex) {
            return sections[currentSectionIndex].body
        }
        return MarkdownScript.plainText(from: currentPageText)
    }

    var hasNextSection: Bool {
        !sections.isEmpty && currentSectionIndex + 1 < sections.count
    }

    /// True when finishing the current read leads somewhere, which is what the prompter's
    /// end-of-read button asks about.
    var hasNextChunk: Bool {
        hasNextSection || hasNextPage
    }

    /// Recomputes sections for the current page, keeping the reader on the same section where it
    /// still exists, so editing a script mid-read does not throw the talent to a different place.
    func refreshSections() {
        let parsed = MarkdownScript.sections(from: currentPageText)
        let previousTitle = sections.indices.contains(currentSectionIndex)
            ? sections[currentSectionIndex].title
            : nil
        sections = parsed
        if let previousTitle, let match = parsed.firstIndex(where: { $0.title == previousTitle }) {
            currentSectionIndex = match
        } else {
            currentSectionIndex = min(currentSectionIndex, max(0, parsed.count - 1))
        }
    }

    /// Reads one section and stops at its end. Continuing is a deliberate act, so the talent can
    /// breathe, reset, or retake without the prompter running on into the next part.
    func readSection(at index: Int) {
        refreshSections()
        guard sections.indices.contains(index) else {
            readCurrentPage()
            return
        }
        currentSectionIndex = index
        readSections.insert(index)
        readPages.insert(currentPageIndex)
        readText(sections[index].body)
    }

    func advanceToNextSection() {
        guard hasNextSection else { return }
        readSection(at: currentSectionIndex + 1)
    }

    // MARK: - Page Organization

    /// Ordered page IDs in `folderID`, or the ungrouped pages when it is nil.
    func pageIDs(inFolder folderID: UUID?) -> [UUID] {
        if let folderID {
            return folders.first { $0.id == folderID }?.pageIDs ?? []
        }
        let grouped = Set(folders.flatMap { $0.pageIDs })
        return pageIDs.filter { !grouped.contains($0) }
    }

    /// Flat page indices belonging to `folderID`, or the ungrouped pages when it is nil.
    func pageIndexes(inFolder folderID: UUID?) -> [Int] {
        pageIDs(inFolder: folderID).compactMap { index(of: $0) }
    }

    func index(of pageID: UUID) -> Int? {
        pageIDs.firstIndex(of: pageID)
    }

    func folderID(forPageAt index: Int) -> UUID? {
        guard let id = pageID(at: index) else { return nil }
        return folder(containing: id)
    }

    func folder(containing pageID: UUID) -> UUID? {
        folders.first { $0.pageIDs.contains(pageID) }?.id
    }

    func pageID(at index: Int) -> UUID? {
        pageIDs.indices.contains(index) ? pageIDs[index] : nil
    }

    func text(for pageID: UUID) -> String {
        guard let index = index(of: pageID), pages.indices.contains(index) else { return "" }
        return pages[index]
    }

    // MARK: Pinning

    func isPinned(_ pageID: UUID) -> Bool {
        pinnedPageIDs.contains(pageID)
    }

    /// Pinned items float to the top of the section they live in, keeping folder membership intact.
    func togglePin(pageID: UUID) {
        let kept = self.pageID(at: currentPageIndex)
        if pinnedPageIDs.contains(pageID) {
            pinnedPageIDs.remove(pageID)
        } else {
            pinnedPageIDs.insert(pageID)
        }
        rebuildOrder(keeping: kept)
    }

    func togglePin(folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let kept = pageID(at: currentPageIndex)
        folders[index].isPinned.toggle()
        rebuildOrder(keeping: kept)
    }

    // MARK: Mutation

    /// Repairs the ID list if pages were mutated directly, and drops stale references.
    func ensurePageIDs() {
        if pageIDs.count < pages.count {
            pageIDs.append(contentsOf: (0..<(pages.count - pageIDs.count)).map { _ in UUID() })
        } else if pageIDs.count > pages.count {
            pageIDs.removeLast(pageIDs.count - pages.count)
        }
        let known = Set(pageIDs)
        for index in folders.indices {
            folders[index].pageIDs.removeAll { !known.contains($0) }
        }
        pinnedPageIDs = pinnedPageIDs.intersection(known)
    }

    /// Adds a page to whichever folder the current page lives in, so a new page appears where you
    /// are working rather than at the bottom of the sidebar.
    @discardableResult
    func addPageNearSelection() -> Int {
        addPage(to: folderID(forPageAt: currentPageIndex))
    }

    /// Adds a page, expanding the target section so the new page is never added out of sight.
    @discardableResult
    func addPage(to folderID: UUID? = nil) -> Int {
        ensurePageIDs()
        let id = UUID()
        pages.append("")
        pageIDs.append(id)
        expand(folderID)
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].pageIDs.append(id)
        }
        rebuildOrder(keeping: id)
        return currentPageIndex
    }

    /// Opens the section a page is about to land in, so it is never added out of sight.
    private func expand(_ folderID: UUID?) {
        guard let folderID else {
            ungroupedIsExpanded = true
            return
        }
        if let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].isExpanded = true
        }
    }

    func removePage(at index: Int) {
        guard let id = pageID(at: index) else { return }
        removePages(ids: [id])
    }

    /// Deletes pages, always leaving at least one behind.
    func removePages(ids: [UUID]) {
        ensurePageIDs()
        let doomed = Set(ids).intersection(pageIDs)
        guard !doomed.isEmpty, doomed.count < pages.count else { return }

        let survivorID = pageID(at: currentPageIndex).flatMap { doomed.contains($0) ? nil : $0 }
        let readIDs = Set(readPages.compactMap { pageID(at: $0) }).subtracting(doomed)

        var keptTexts: [String] = []
        var keptIDs: [UUID] = []
        for (index, id) in pageIDs.enumerated() where !doomed.contains(id) {
            keptIDs.append(id)
            keptTexts.append(pages.indices.contains(index) ? pages[index] : "")
        }
        pages = keptTexts
        pageIDs = keptIDs
        for index in folders.indices {
            folders[index].pageIDs.removeAll { doomed.contains($0) }
        }
        pinnedPageIDs.subtract(doomed)
        readPages = Set(keptIDs.indices.filter { readIDs.contains(keptIDs[$0]) })
        currentPageIndex = max(0, min(currentPageIndex, pages.count - 1))
        rebuildOrder(keeping: survivorID)
    }

    /// Moves pages into a folder, or out to the ungrouped section when `folderID` is nil.
    /// The page being edited stays selected, even when the move reorders the document around it.
    func movePages(ids: [UUID], to folderID: UUID?) {
        ensurePageIDs()
        let moving = ids.filter { pageIDs.contains($0) }
        guard !moving.isEmpty else { return }
        let kept = pageID(at: currentPageIndex)

        for index in folders.indices {
            folders[index].pageIDs.removeAll { moving.contains($0) }
        }
        expand(folderID)
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].pageIDs.append(contentsOf: moving)
        }
        rebuildOrder(keeping: kept ?? moving.first)
    }

    func movePage(id: UUID, to folderID: UUID?) {
        movePages(ids: [id], to: folderID)
    }

    /// Drops pages immediately before `targetID`, joining the target's section on the way.
    /// This is both reordering within a section and moving between sections.
    func movePages(ids: [UUID], before targetID: UUID) {
        ensurePageIDs()
        let moving = ids.filter { pageIDs.contains($0) && $0 != targetID }
        guard !moving.isEmpty, pageIDs.contains(targetID) else { return }
        let kept = pageID(at: currentPageIndex)
        let destination = folder(containing: targetID)

        for index in folders.indices {
            folders[index].pageIDs.removeAll { moving.contains($0) }
        }
        expand(destination)

        if let destination, let index = folders.firstIndex(where: { $0.id == destination }) {
            let position = folders[index].pageIDs.firstIndex(of: targetID) ?? folders[index].pageIDs.count
            folders[index].pageIDs.insert(contentsOf: moving, at: position)
        } else {
            // Ungrouped pages take their order from the flat list, so reorder that directly.
            var flat = pageIDs
            flat.removeAll { moving.contains($0) }
            let position = flat.firstIndex(of: targetID) ?? flat.count
            flat.insert(contentsOf: moving, at: position)
            reorderFlat(to: flat)
        }
        // A page dropped before a pinned page cannot outrank it, so match the target's pin state.
        if isPinned(targetID) {
            pinnedPageIDs.formUnion(moving)
        } else {
            pinnedPageIDs.subtract(moving)
        }
        rebuildOrder(keeping: kept)
    }

    // MARK: Folders

    @discardableResult
    func addFolder(named name: String) -> PageFolder {
        let folder = PageFolder(name: name)
        folders.append(folder)
        return folder
    }

    func renameFolder(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
    }

    /// Removes the folder. Its pages survive and drop back into the ungrouped section.
    func deleteFolder(id: UUID) {
        let keptID = pageID(at: currentPageIndex)
        if folders.first(where: { $0.id == id })?.pageIDs.isEmpty == false {
            ungroupedIsExpanded = true
        }
        folders.removeAll { $0.id == id }
        if folders.isEmpty {
            ungroupedIsExpanded = true
        }
        rebuildOrder(keeping: keptID)
    }

    func moveFolder(id: UUID, by offset: Int) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard folders.indices.contains(target) else { return }
        let keptID = pageID(at: currentPageIndex)
        folders.swapAt(index, target)
        rebuildOrder(keeping: keptID)
    }

    /// Replaces the whole document. Used by open and import.
    func replacePages(
        _ newPages: [String],
        ids: [UUID]? = nil,
        folders newFolders: [PageFolder] = [],
        pinned: Set<UUID> = []
    ) {
        let texts = newPages.isEmpty ? [""] : newPages
        pages = texts
        pageIDs = ids?.count == texts.count ? (ids ?? []) : texts.map { _ in UUID() }
        folders = newFolders
        pinnedPageIDs = pinned
        currentPageIndex = 0
        readPages.removeAll()
        ungroupedIsExpanded = true
        rebuildOrder(keeping: pageIDs.first)
    }

    /// Applies an explicit flat order to `pages` and `pageIDs`.
    private func reorderFlat(to order: [UUID]) {
        guard order.count == pageIDs.count else { return }
        var textByID: [UUID: String] = [:]
        for (index, id) in pageIDs.enumerated() where pages.indices.contains(index) {
            textByID[id] = pages[index]
        }
        pageIDs = order
        pages = order.map { textByID[$0] ?? "" }
    }

    /// Reorders pages so folder contents are contiguous and in folder order, ungrouped pages last,
    /// with pinned items floating to the top of whichever section they live in. The sidebar shows
    /// this same order, so what you read is what you see.
    private func rebuildOrder(keeping selectedID: UUID?) {
        ensurePageIDs()
        var textByID: [UUID: String] = [:]
        for (index, id) in pageIDs.enumerated() where pages.indices.contains(index) {
            textByID[id] = pages[index]
        }
        let readIDs = Set(readPages.compactMap { pageID(at: $0) })

        // Pinned first, order otherwise untouched. A stable partition, which sorted(by:) is not.
        folders = folders.filter { $0.isPinned } + folders.filter { !$0.isPinned }
        for index in folders.indices {
            folders[index].pageIDs = pinnedFirst(folders[index].pageIDs)
        }

        let grouped = folders.flatMap { $0.pageIDs }
        let groupedSet = Set(grouped)
        let loose = pinnedFirst(pageIDs.filter { !groupedSet.contains($0) })
        let ordered = grouped + loose
        guard ordered.count == pageIDs.count else { return }

        pageIDs = ordered
        pages = ordered.map { textByID[$0] ?? "" }
        readPages = Set(ordered.indices.filter { readIDs.contains(ordered[$0]) })

        if let selectedID, let index = ordered.firstIndex(of: selectedID) {
            currentPageIndex = index
        } else {
            currentPageIndex = max(0, min(currentPageIndex, pages.count - 1))
        }
    }

    private func pinnedFirst(_ ids: [UUID]) -> [UUID] {
        ids.filter { pinnedPageIDs.contains($0) } + ids.filter { !pinnedPageIDs.contains($0) }
    }

    /// Pushes an edit made during a read to every surface, keeping the read position.
    /// The prompter, the external display and the phone remote all follow the new text.
    func refreshLiveScript() {
        guard overlayController.isShowing else { return }
        refreshSections()
        let text = currentReadingText

        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.apply(text: text)
            content.hasNextPage = hasNextPage
        }
        overlayController.speechRecognizer.updateScript(text)

        let tokenized = tokenizeText(text)
        let words = tokenized.words
        browserServer.updateContent(
            words: words,
            lineBreaks: tokenized.breaksBefore,
            totalCharCount: words.joined(separator: " ").count,
            hasNextPage: hasNextChunk
        )
    }

    // MARK: - Session Persistence

    /// Autosave lives here. Under the sandbox this resolves inside the app container, which also
    /// survives the app being replaced.
    var sessionDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".textream", isDirectory: true)
    }

    var sessionFile: URL {
        sessionDirectory.appendingPathComponent("session.json")
    }

    private var autosaveCancellable: AnyCancellable?
    private var isRestoringSession = false

    /// Writes on a delay after the last change, so typing costs one write rather than one per key.
    private func startAutosave() {
        // DispatchQueue rather than RunLoop: a run-loop scheduler stalls while a modal window or
        // an open menu holds the main loop, which is exactly when a read is being set up.
        autosaveCancellable = objectWillChange
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.saveSession()
            }

        // A debounce cannot help if the app is going away, so also write on the way out.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveSession()
        }
    }

    func saveSession() {
        guard !isRestoringSession else { return }
        ensurePageIDs()
        let snapshot = SessionSnapshot(
            pages: pages,
            pageIDs: pageIDs,
            folders: folders,
            pinnedPageIDs: Array(pinnedPageIDs),
            currentPageIndex: currentPageIndex
        )
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: sessionFile, options: .atomic)
        } catch {
            // Autosave is a convenience; a failure here must never interrupt a read.
            NSLog("Textream: could not save session: \(error.localizedDescription)")
        }
    }

    /// Restores the last session. A missing or unreadable file just leaves the defaults in place.
    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionFile),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              !snapshot.pages.isEmpty else { return }

        isRestoringSession = true
        defer { isRestoringSession = false }

        replacePages(
            snapshot.pages,
            ids: snapshot.pageIDs.count == snapshot.pages.count ? snapshot.pageIDs : nil,
            folders: snapshot.folders,
            pinned: Set(snapshot.pinnedPageIDs)
        )
        savedPages = snapshot.pages
        if pages.indices.contains(snapshot.currentPageIndex) {
            currentPageIndex = snapshot.currentPageIndex
        }
    }

    // MARK: - File Operations

    func saveFile() {
        if let url = currentFileURL {
            saveToURL(url)
        } else {
            saveFileAs()
        }
    }

    func saveFileAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "textream")!]
        panel.nameFieldStringValue = "Untitled.textream"
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToURL(url)
        }
    }

    private func saveToURL(_ url: URL) {
        do {
            ensurePageIDs()
            let data: Data
            if folders.isEmpty && pinnedPageIDs.isEmpty {
                data = try JSONEncoder().encode(pages)
            } else {
                let document = TextreamDocument(
                    pages: pages,
                    pageIDs: pageIDs,
                    folders: folders,
                    pinnedPageIDs: Array(pinnedPageIDs)
                )
                data = try JSONEncoder().encode(document)
            }
            try data.write(to: url, options: .atomic)
            currentFileURL = url
            savedPages = pages
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to save file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    var hasUnsavedChanges: Bool {
        pages != savedPages
    }

    func openFile() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "textream")!,
            .init(filenameExtension: "key")!,
            .init(filenameExtension: "pptx")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "key" {
                let alert = NSAlert()
                alert.messageText = "Keynote files can't be imported directly"
                alert.informativeText = "Please export your Keynote presentation as PowerPoint (.pptx) first:\n\nIn Keynote: File → Export To → PowerPoint"
                alert.alertStyle = .informational
                alert.runModal()
            } else if ext == "pptx" {
                self?.importPresentation(from: url)
            } else {
                self?.openFileAtURL(url)
            }
        }
    }

    func importPresentation(from url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    self?.replacePages(notes)
                    self?.savedPages = notes
                    self?.currentFileURL = nil
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Import Error"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    /// Returns true if it's safe to proceed (saved, discarded, or no changes).
    /// Returns false if the user cancelled.
    func confirmDiscardIfNeeded() -> Bool {
        guard hasUnsavedChanges else { return true }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Do you want to save your changes before opening another file?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            saveFile()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func openFileAtURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let loadedPages: [String]
            if let legacy = try? decoder.decode([String].self, from: data) {
                loadedPages = legacy
                guard !loadedPages.isEmpty else { return }
                replacePages(loadedPages)
            } else {
                let document = try decoder.decode(TextreamDocument.self, from: data)
                loadedPages = document.pages
                guard !loadedPages.isEmpty else { return }
                replacePages(
                    document.pages,
                    ids: document.pageIDs,
                    folders: document.folders,
                    pinned: Set(document.pinnedPageIDs)
                )
            }
            savedPages = pages
            currentFileURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to open file"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Browser Server

    func updateBrowserServer() {
        if NotchSettings.shared.browserServerEnabled {
            if !browserServer.isRunning {
                browserServer.start()
                wireBrowserCallbacks()
            }
        } else {
            browserServer.stop()
        }
    }

    private func wireBrowserCallbacks() {
        browserServer.onScrub = { [weak self] charOffset in
            self?.scrub(toCharOffset: charOffset)
        }
        browserServer.onSeek = { [weak self] charOffset in
            self?.seek(toCharOffset: charOffset)
        }
    }

    /// Follow a remote's live scroll. Every surface shows the scrubbed position,
    /// but the speech recognizer is deliberately left alone until the scroll
    /// settles so that dragging can't restart recognition on every update.
    func scrub(toCharOffset charOffset: Int) {
        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.scrubCharOffset = charOffset
        }
        browserServer.applyScrub(charOffset: charOffset)
    }

    /// Continue reading from an arbitrary point, requested by the remote.
    /// Applies to every surface: word-tracking follows the speech recognizer,
    /// while classic / silence-paused modes are driven by the scroll progress.
    func seek(toCharOffset charOffset: Int) {
        overlayController.speechRecognizer.jumpTo(charOffset: charOffset)

        for content in [overlayController.overlayContent, externalDisplayController.overlayContent] {
            content.scrubCharOffset = nil
            content.seekCharOffset = charOffset
            content.seekToken &+= 1
        }

        browserServer.applySeek(charOffset: charOffset)
    }

    // MARK: - Director Server

    func updateDirectorServer() {
        if NotchSettings.shared.directorModeEnabled {
            if !directorServer.isRunning {
                directorServer.start()
                wireDirectorCallbacks()
            }
        } else {
            directorServer.stop()
            if directorIsReading {
                overlayController.dismiss()
                directorIsReading = false
            }
        }
    }

    private func wireDirectorCallbacks() {
        directorServer.onSetText = { [weak self] text in
            self?.setTextFromDirector(text)
        }
        directorServer.onUpdateText = { [weak self] text, readCharCount in
            self?.updateTextFromDirector(text, readCharCount: readCharCount)
        }
        directorServer.onStop = { [weak self] in
            self?.stopDirectorReading()
        }
    }

    func setTextFromDirector(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Director mode is single page
        pages = [trimmed]
        currentPageIndex = 0
        readPages.removeAll()

        // Force word tracking mode for director
        let savedMode = NotchSettings.shared.listeningMode
        NotchSettings.shared.listeningMode = .wordTracking

        directorIsReading = true

        overlayController.show(text: trimmed, hasNextPage: false) { [weak self] in
            self?.directorIsReading = false
            self?.directorServer.hideContent()
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            // Restore listening mode
            NotchSettings.shared.listeningMode = savedMode
        }

        // Feed director server with speech recognizer
        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        let totalCharCount = words.joined(separator: " ").count
        directorServer.showContent(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            totalCharCount: totalCharCount
        )

        // Also show on external display & browser if configured
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            lineBreaks: tokenized.breaksBefore,
            totalCharCount: totalCharCount,
            hasNextPage: false
        )
        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                lineBreaks: tokenized.breaksBefore,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func updateTextFromDirector(_ text: String, readCharCount: Int) {
        guard directorIsReading else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pages = [trimmed]

        // Preserve read progress: only update unread portion
        let preservedCharCount = overlayController.speechRecognizer.recognizedCharCount

        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        let totalCharCount = words.joined(separator: " ").count

        // Update overlay content without resetting speech progress
        overlayController.overlayContent.words = words
        overlayController.overlayContent.lineBreaks = tokenized.breaksBefore
        overlayController.overlayContent.totalCharCount = totalCharCount
        overlayController.overlayContent.hasNextPage = false

        // Update the speech recognizer with new full text but keep char count
        overlayController.speechRecognizer.updateText(trimmed, preservingCharCount: preservedCharCount)

        // Update director server
        directorServer.updateContent(words: words, totalCharCount: totalCharCount)

        // Update external display & browser
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.lineBreaks = tokenized.breaksBefore
        externalDisplayController.overlayContent.totalCharCount = totalCharCount
        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                lineBreaks: tokenized.breaksBefore,
                totalCharCount: totalCharCount,
                hasNextPage: false
            )
        }
    }

    func stopDirectorReading() {
        guard directorIsReading else { return }
        overlayController.dismiss()
        directorIsReading = false
    }

    // macOS Services handler
    @objc func readInTextream(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = "No text found on pasteboard" as NSString
            return
        }
        readText(text, fromExternalSource: true)
    }

    // URL scheme handler: textream://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "textream" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam, fromExternalSource: true)
            }
        }
    }
}

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

    @Published var pages: [String] = [""]
    /// Stable identity per page, parallel to `pages`. Folders reference pages by ID so that
    /// inserting, deleting or regrouping never corrupts membership the way indices would.
    @Published private(set) var pageIDs: [UUID] = [UUID()]
    /// Folders, in sidebar order. Their pages come first in the running order, ungrouped pages last.
    @Published var folders: [PageFolder] = []
    @Published var currentPageIndex: Int = 0
    @Published var readPages: Set<Int> = []

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

    func readText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        launchedExternally = true
        hideMainWindow()

        overlayController.show(text: trimmed, hasNextPage: hasNextPage) { [weak self] in
            self?.externalDisplayController.dismiss()
            self?.browserServer.hideContent()
            self?.onOverlayDismissed?()
        }
        updatePageInfo()

        // Also show on external display if configured (same parsing as overlay)
        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        let totalCharCount = words.joined(separator: " ").count
        externalDisplayController.show(
            speechRecognizer: overlayController.speechRecognizer,
            words: words,
            lineBreaks: tokenized.breaksBefore,
            totalCharCount: totalCharCount,
            hasNextPage: hasNextPage
        )

        if browserServer.isRunning {
            browserServer.showContent(
                speechRecognizer: overlayController.speechRecognizer,
                words: words,
                totalCharCount: totalCharCount,
                hasNextPage: hasNextPage
            )
        }
    }

    func readCurrentPage() {
        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        readPages.insert(currentPageIndex)
        readText(trimmed)
    }

    func advanceToNextPage() {
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

        let trimmed = currentPageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Update content in-place without recreating the panel
        overlayController.updateContent(text: trimmed, hasNextPage: hasNextPage)
        updatePageInfo()

        // Also update external display content in-place
        let tokenized = tokenizeText(trimmed)
        let words = tokenized.words
        externalDisplayController.overlayContent.words = words
        externalDisplayController.overlayContent.lineBreaks = tokenized.breaksBefore
        externalDisplayController.overlayContent.totalCharCount = words.joined(separator: " ").count
        externalDisplayController.overlayContent.hasNextPage = hasNextPage

        if browserServer.isRunning {
            browserServer.updateContent(
                words: words,
                totalCharCount: words.joined(separator: " ").count,
                hasNextPage: hasNextPage
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

    // MARK: - Page Organization

    /// Flat page indices belonging to `folderID`, or the ungrouped pages when it is nil.
    func pageIndexes(inFolder folderID: UUID?) -> [Int] {
        let grouped = Set(folders.flatMap { $0.pageIDs })
        return pageIDs.indices.filter { index in
            let id = pageIDs[index]
            if let folderID {
                return folders.first { $0.id == folderID }?.pageIDs.contains(id) ?? false
            }
            return !grouped.contains(id)
        }
    }

    func folderID(forPageAt index: Int) -> UUID? {
        guard pageIDs.indices.contains(index) else { return nil }
        let id = pageIDs[index]
        return folders.first { $0.pageIDs.contains(id) }?.id
    }

    func pageID(at index: Int) -> UUID? {
        pageIDs.indices.contains(index) ? pageIDs[index] : nil
    }

    /// Repairs the ID list if pages were mutated directly, and drops stale folder references.
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
    }

    /// Adds a page to whichever folder the current page lives in, so a new page appears where you
    /// are working rather than at the bottom of the sidebar.
    @discardableResult
    func addPageNearSelection() -> Int {
        addPage(to: folderID(forPageAt: currentPageIndex))
    }

    /// Adds a page, expanding the target folder so the new page is never added out of sight.
    @discardableResult
    func addPage(to folderID: UUID? = nil) -> Int {
        ensurePageIDs()
        let id = UUID()
        pages.append("")
        pageIDs.append(id)
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].pageIDs.append(id)
            folders[index].isExpanded = true
        }
        rebuildOrder(keeping: id)
        return currentPageIndex
    }

    func removePage(at index: Int) {
        guard pages.count > 1, pages.indices.contains(index) else { return }
        ensurePageIDs()
        let removedID = pageIDs[index]
        let survivingID: UUID? = currentPageIndex == index ? nil : pageID(at: currentPageIndex)

        pages.remove(at: index)
        pageIDs.remove(at: index)
        for folderIndex in folders.indices {
            folders[folderIndex].pageIDs.removeAll { $0 == removedID }
        }
        readPages = Set(readPages.compactMap { page in
            if page == index { return nil }
            return page > index ? page - 1 : page
        })
        if currentPageIndex >= pages.count {
            currentPageIndex = pages.count - 1
        } else if currentPageIndex > index {
            currentPageIndex -= 1
        }
        rebuildOrder(keeping: survivingID)
    }

    /// Moves a page into a folder, or out to the ungrouped section when `folderID` is nil.
    /// The page being edited stays selected, even when the move reorders the document around it.
    func movePage(id: UUID, to folderID: UUID?) {
        ensurePageIDs()
        let keptID = pageID(at: currentPageIndex)
        for index in folders.indices {
            folders[index].pageIDs.removeAll { $0 == id }
        }
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].pageIDs.append(id)
            folders[index].isExpanded = true
        }
        rebuildOrder(keeping: keptID ?? id)
    }

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
        folders.removeAll { $0.id == id }
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
    func replacePages(_ newPages: [String], ids: [UUID]? = nil, folders newFolders: [PageFolder] = []) {
        let texts = newPages.isEmpty ? [""] : newPages
        pages = texts
        pageIDs = ids?.count == texts.count ? (ids ?? []) : texts.map { _ in UUID() }
        folders = newFolders
        currentPageIndex = 0
        readPages.removeAll()
        rebuildOrder(keeping: pageIDs.first)
    }

    /// Reorders pages so folder contents are contiguous and in folder order, ungrouped pages last.
    /// The sidebar shows this same order, so what you read is what you see.
    private func rebuildOrder(keeping selectedID: UUID?) {
        ensurePageIDs()
        var textByID: [UUID: String] = [:]
        for (index, id) in pageIDs.enumerated() where pages.indices.contains(index) {
            textByID[id] = pages[index]
        }
        let readIDs = Set(readPages.compactMap { pageID(at: $0) })

        let grouped = folders.flatMap { $0.pageIDs }
        let groupedSet = Set(grouped)
        let loose = pageIDs.filter { !groupedSet.contains($0) }
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
            if folders.isEmpty {
                data = try JSONEncoder().encode(pages)
            } else {
                let document = TextreamDocument(pages: pages, pageIDs: pageIDs, folders: folders)
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
                replacePages(document.pages, ids: document.pageIDs, folders: document.folders)
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
            }
        } else {
            browserServer.stop()
        }
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
        readText(text)
    }

    // URL scheme handler: textream://read?text=Hello%20World
    func handleURL(_ url: URL) {
        guard url.scheme == "textream" else { return }

        if url.host == "read" || url.path == "/read" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let textParam = components.queryItems?.first(where: { $0.name == "text" })?.value {
                readText(textParam)
            }
        }
    }
}

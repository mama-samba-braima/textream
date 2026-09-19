//
//  ProjectLibrary.swift
//  Textream
//

import AppKit
import Combine
import UniformTypeIdentifiers

/// What a file in a project is for.
///
/// Only scripts are read aloud. Everything else is there because it belongs with the script: the
/// take you recorded from it, the deck it came from, the notes you kept beside it.
enum ProjectFileKind: String, Codable {
    case script
    case video
    case audio
    case image
    case document

    static let scriptExtensions: Set<String> = ["md", "markdown", "txt"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aac", "caf"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]

    static func of(_ url: URL) -> ProjectFileKind {
        let ext = url.pathExtension.lowercased()
        if scriptExtensions.contains(ext) { return .script }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        return .document
    }

    var icon: String {
        switch self {
        case .script: return "doc.text"
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .document: return "doc"
        }
    }
}

/// A file in a project that is not a script: a take, a deck, a set of notes. Identified by path,
/// so a rescan never changes what is selected.
struct ProjectAsset: Identifiable, Equatable {
    var url: URL
    var kind: ProjectFileKind
    var size: Int64
    var modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// "4.2 MB · 12 Sep", the two things worth knowing about a take at a glance.
    var subtitle: String {
        let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        return "\(bytes) · \(day.string(from: modified))"
    }
}

/// Everything the app knows, as it stands on disk.
struct LibrarySnapshot {
    var projects: [PageFolder] = []
    var pages: [String] = []
    var pageIDs: [UUID] = []
    var pinnedPageIDs: Set<UUID> = []
    var donePageIDs: Set<UUID> = []
    var doneSectionTitles: [UUID: Set<String>] = [:]
    var currentPageIndex: Int = 0
}

// MARK: - Index

/// The index is the app's own bookkeeping: order, identity and what has been ticked off. It is
/// deliberately the only thing the app needs that the file system cannot tell it, so a project
/// folder holds nothing but the files the operator put there.
private struct LibraryIndex: Codable {
    struct File: Codable {
        var id: UUID
        var name: String
        var isPinned: Bool = false
        var isDone: Bool = false
        var doneSections: [String] = []
    }

    struct Project: Codable {
        var id: UUID
        var name: String
        var directory: String
        var isExpanded: Bool = true
        var isPinned: Bool = false
        var files: [File] = []
    }

    var version: Int = 1
    var projects: [Project] = []
    var currentPageID: UUID?
}

/// The projects folder: what is on disk, and every change the app makes to it.
///
/// A project is a plain folder in `~/Textream`, and a script is a plain Markdown file inside it.
/// Nothing about a project is locked inside the app: it can be opened in Finder, synced, backed
/// up and edited elsewhere, and the app picks up what changed.
final class ProjectLibrary: ObservableObject {
    static let shared = ProjectLibrary()

    /// Non-script files in each project, keyed by project. Published on its own so a take copied
    /// in from Finder appears without touching the script model.
    @Published private(set) var assets: [UUID: [ProjectAsset]] = [:]

    /// Directory name per project, kept here rather than on `PageFolder` so the `.textream`
    /// document format stays exactly as it was.
    private(set) var directories: [UUID: String] = [:]
    /// File name per script page.
    private(set) var fileNames: [UUID: String] = [:]

    private var watcher: DirectoryWatcher?
    /// What the app last wrote for each page, so autosave writes only the files that changed.
    private var writtenText: [UUID: String] = [:]

    var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Textream", isDirectory: true)
    }

    private var indexURL: URL {
        rootURL.appendingPathComponent(".library.json")
    }

    /// The old single-file session, left untouched after the move as a safety net.
    private var legacySessionURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".textream/session.json")
    }

    func url(forProject id: UUID) -> URL? {
        guard let directory = directories[id] else { return nil }
        return rootURL.appendingPathComponent(directory, isDirectory: true)
    }

    func url(forPage id: UUID, in projectID: UUID) -> URL? {
        guard let name = fileNames[id], let folder = url(forProject: projectID) else { return nil }
        return folder.appendingPathComponent(name)
    }

    func fileName(forPage id: UUID) -> String? { fileNames[id] }

    // MARK: - Loading

    /// Reads the library, moving the old session into it the first time.
    func load() -> LibrarySnapshot {
        let manager = FileManager.default
        if !manager.fileExists(atPath: indexURL.path) {
            migrateLegacySession()
        }
        try? manager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var index = readIndex() ?? LibraryIndex()
        index = reconcile(index)
        writeIndex(index)

        var snapshot = LibrarySnapshot()
        directories = [:]
        fileNames = [:]
        writtenText = [:]

        for project in index.projects {
            directories[project.id] = project.directory
            var folder = PageFolder(
                id: project.id,
                name: project.name,
                isExpanded: project.isExpanded,
                isPinned: project.isPinned
            )
            let projectURL = rootURL.appendingPathComponent(project.directory, isDirectory: true)
            for file in project.files {
                let url = projectURL.appendingPathComponent(file.name)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                snapshot.pages.append(text)
                snapshot.pageIDs.append(file.id)
                fileNames[file.id] = file.name
                writtenText[file.id] = text
                folder.pageIDs.append(file.id)
                if file.isPinned { snapshot.pinnedPageIDs.insert(file.id) }
                if file.isDone { snapshot.donePageIDs.insert(file.id) }
                if !file.doneSections.isEmpty { snapshot.doneSectionTitles[file.id] = Set(file.doneSections) }
            }
            snapshot.projects.append(folder)
        }

        if let current = index.currentPageID, let position = snapshot.pageIDs.firstIndex(of: current) {
            snapshot.currentPageIndex = position
        }
        rescanAssets()
        return snapshot
    }

    /// Brings the index in line with the folder: files added in Finder join the project, files
    /// deleted there leave it, and whole folders dropped into `~/Textream` become projects.
    private func reconcile(_ index: LibraryIndex) -> LibraryIndex {
        let manager = FileManager.default
        var result = index
        // A project folder deleted in Finder is a project deleted.
        result.projects.removeAll {
            !manager.fileExists(atPath: rootURL.appendingPathComponent($0.directory).path)
        }
        var seenDirectories = Set(result.projects.map(\.directory))

        for position in result.projects.indices {
            let projectURL = rootURL.appendingPathComponent(result.projects[position].directory, isDirectory: true)
            let onDisk = scriptFileNames(in: projectURL)
            result.projects[position].files.removeAll { !onDisk.contains($0.name) }
            let known = Set(result.projects[position].files.map(\.name))
            for name in onDisk.sorted() where !known.contains(name) {
                result.projects[position].files.append(LibraryIndex.File(id: UUID(), name: name))
            }
        }

        // A folder dropped into ~/Textream is a project the operator made in Finder.
        let contents = (try? manager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = url.lastPathComponent
            guard !seenDirectories.contains(name) else { continue }
            seenDirectories.insert(name)
            var project = LibraryIndex.Project(id: UUID(), name: name, directory: name)
            project.files = scriptFileNames(in: url).sorted().map { LibraryIndex.File(id: UUID(), name: $0) }
            result.projects.append(project)
        }

        // The app is a teleprompter: there is always somewhere to type.
        if result.projects.isEmpty {
            var project = LibraryIndex.Project(id: UUID(), name: "Scripts", directory: "Scripts")
            let projectURL = rootURL.appendingPathComponent("Scripts", isDirectory: true)
            try? manager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let name = "Untitled.md"
            try? "".write(to: projectURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
            project.files = [LibraryIndex.File(id: UUID(), name: name)]
            result.projects.append(project)
        }
        if result.projects.allSatisfy({ $0.files.isEmpty }), let first = result.projects.indices.first {
            let projectURL = rootURL.appendingPathComponent(result.projects[first].directory, isDirectory: true)
            try? manager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let name = uniqueFileName("Untitled.md", in: projectURL)
            try? "".write(to: projectURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
            result.projects[first].files.append(LibraryIndex.File(id: UUID(), name: name))
        }
        return result
    }

    /// Whether the scripts on disk are no longer the ones the app has open, which is the only
    /// reason to read the whole library back.
    func hasScriptChanges(in projects: [PageFolder]) -> Bool {
        var seen = Set<String>()
        for project in projects {
            guard let directory = directories[project.id] else { return true }
            seen.insert(directory)
            let url = rootURL.appendingPathComponent(directory, isDirectory: true)
            if scriptFileNames(in: url) != Set(project.pageIDs.compactMap { fileNames[$0] }) { return true }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders.contains {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && !seen.contains($0.lastPathComponent)
        }
    }

    /// Scripts whose file has been changed by something other than this app.
    ///
    /// Only a script the app has not touched since it last wrote it is offered back: if there is
    /// unwritten typing here, this app's copy is the newer one and the file is left to be
    /// overwritten by the next save, rather than the typing being thrown away.
    func externalEdits(for snapshot: LibrarySnapshot) -> [UUID: String] {
        var changed: [UUID: String] = [:]
        for project in snapshot.projects {
            guard let folder = url(forProject: project.id) else { continue }
            for id in project.pageIDs {
                guard let name = fileNames[id],
                      let written = writtenText[id],
                      let position = snapshot.pageIDs.firstIndex(of: id),
                      snapshot.pages.indices.contains(position),
                      snapshot.pages[position] == written,
                      let disk = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                      disk != written else { continue }
                changed[id] = disk
                writtenText[id] = disk
            }
        }
        return changed
    }

    private func scriptFileNames(in directory: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return Set(contents.filter { ProjectFileKind.of($0) == .script }.map(\.lastPathComponent))
    }

    // MARK: - Other files

    /// Re-reads the non-script files of every project.
    func rescanAssets() {
        var found: [UUID: [ProjectAsset]] = [:]
        for (id, directory) in directories {
            let url = rootURL.appendingPathComponent(directory, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []
            var files: [ProjectAsset] = []
            for file in contents {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                if values?.isDirectory == true { continue }
                let kind = ProjectFileKind.of(file)
                guard kind != .script else { continue }
                files.append(ProjectAsset(
                    url: file,
                    kind: kind,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                ))
            }
            // Newest first: the take you just recorded is the one you want to watch.
            found[id] = files.sorted { $0.modified > $1.modified }
        }
        if found != assets {
            assets = found
        }
    }

    func assets(for projectID: UUID) -> [ProjectAsset] {
        assets[projectID] ?? []
    }

    /// Copies files into a project. Takes, decks and notes come from elsewhere on disk, so they
    /// are copied rather than referenced: the project folder holds everything it needs.
    @discardableResult
    func importFiles(_ urls: [URL], into projectID: UUID) -> Int {
        guard let folder = url(forProject: projectID) else { return 0 }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = 0
        for source in urls {
            let name = uniqueFileName(source.lastPathComponent, in: folder)
            do {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                copied += 1
            } catch {
                NSLog("Textream: could not copy \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        rescanAssets()
        return copied
    }

    func trashAsset(_ asset: ProjectAsset) {
        try? FileManager.default.trashItem(at: asset.url, resultingItemURL: nil)
        rescanAssets()
    }

    // MARK: - Watching

    /// Watches the library so a take dropped into a project folder in Finder shows up in the
    /// sidebar without the app being told.
    func startWatching(onChange: @escaping () -> Void) {
        watcher = DirectoryWatcher(url: rootURL) { [weak self] in
            self?.rescanAssets()
            onChange()
        }
    }

    // MARK: - Writing

    /// Writes the index, and any script whose text has changed since it was last written.
    func save(_ snapshot: LibrarySnapshot) {
        let manager = FileManager.default
        try? manager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        var snapshot = snapshot
        // A page belonging to no project has nowhere to be written, and would be gone by the next
        // launch. Whatever put it there, it gets a file in the first project rather than be lost.
        let filed = Set(snapshot.projects.flatMap(\.pageIDs))
        if !snapshot.projects.isEmpty {
            for (position, id) in snapshot.pageIDs.enumerated() where !filed.contains(id) {
                let text = snapshot.pages.indices.contains(position) ? snapshot.pages[position] : ""
                attachScript(id: id, to: snapshot.projects[0].id, title: MigrationTitle.of(text), text: text)
                snapshot.projects[0].pageIDs.append(id)
            }
        }

        var index = LibraryIndex()
        for project in snapshot.projects {
            guard let directory = directories[project.id] else { continue }
            let projectURL = rootURL.appendingPathComponent(directory, isDirectory: true)
            try? manager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            var entry = LibraryIndex.Project(
                id: project.id,
                name: project.name,
                directory: directory,
                isExpanded: project.isExpanded,
                isPinned: project.isPinned
            )
            for pageID in project.pageIDs {
                guard let name = fileNames[pageID] else { continue }
                if let position = snapshot.pageIDs.firstIndex(of: pageID), snapshot.pages.indices.contains(position) {
                    let text = snapshot.pages[position]
                    if writtenText[pageID] != text {
                        do {
                            try text.write(to: projectURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
                            writtenText[pageID] = text
                        } catch {
                            NSLog("Textream: could not write \(name): \(error.localizedDescription)")
                        }
                    }
                }
                entry.files.append(LibraryIndex.File(
                    id: pageID,
                    name: name,
                    isPinned: snapshot.pinnedPageIDs.contains(pageID),
                    isDone: snapshot.donePageIDs.contains(pageID),
                    doneSections: Array(snapshot.doneSectionTitles[pageID] ?? [])
                ))
            }
            index.projects.append(entry)
        }
        if snapshot.pageIDs.indices.contains(snapshot.currentPageIndex) {
            index.currentPageID = snapshot.pageIDs[snapshot.currentPageIndex]
        }
        writeIndex(index)
    }

    private func readIndex() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    private func writeIndex(_ index: LibraryIndex) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Textream: could not write the library index: \(error.localizedDescription)")
        }
    }

    // MARK: - Projects

    /// Makes a project folder and returns its id and the name it ended up with.
    func createProject(named name: String) -> (id: UUID, name: String)? {
        let id = UUID()
        let directory = uniqueDirectoryName(from: name)
        do {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("Textream: could not make the project folder: \(error.localizedDescription)")
            return nil
        }
        directories[id] = directory
        return (id, directory)
    }

    /// Renames the project folder to match. The name on screen is the name in Finder.
    @discardableResult
    func renameProject(id: UUID, to name: String) -> String? {
        guard let old = directories[id] else { return nil }
        let directory = uniqueDirectoryName(from: name, excluding: old)
        guard directory != old else { return old }
        let source = rootURL.appendingPathComponent(old, isDirectory: true)
        let destination = rootURL.appendingPathComponent(directory, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            NSLog("Textream: could not rename the project folder: \(error.localizedDescription)")
            return nil
        }
        directories[id] = directory
        return directory
    }

    /// Puts the whole project folder in the Trash, takes and all, so nothing is destroyed
    /// outright and the operator can put it back.
    func trashProject(id: UUID) {
        guard let url = url(forProject: id) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        directories[id] = nil
        assets[id] = nil
    }

    // MARK: - Scripts

    /// Makes an empty script file in a project.
    func createScript(in projectID: UUID, named title: String = "Untitled") -> UUID? {
        addScript(to: projectID, title: title, text: "")
    }

    /// Adopts text that came from somewhere else: an import, an open, a paste.
    func addScript(to projectID: UUID, title: String, text: String) -> UUID? {
        let id = UUID()
        guard attachScript(id: id, to: projectID, title: title, text: text) != nil else { return nil }
        return id
    }

    /// Gives a page that has no file one, keeping the identity it already has.
    @discardableResult
    func attachScript(id: UUID, to projectID: UUID, title: String, text: String) -> String? {
        guard let folder = url(forProject: projectID) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueFileName(fileName(from: title), in: folder)
        do {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            NSLog("Textream: could not write the script: \(error.localizedDescription)")
            return nil
        }
        fileNames[id] = name
        writtenText[id] = text
        return name
    }

    @discardableResult
    func renameScript(id: UUID, in projectID: UUID, to title: String) -> String? {
        guard let folder = url(forProject: projectID), let old = fileNames[id] else { return nil }
        let ext = URL(fileURLWithPath: old).pathExtension
        let name = uniqueFileName(
            fileName(from: title, extension: ext.isEmpty ? "md" : ext),
            in: folder,
            excluding: old
        )
        guard name != old else { return old }
        do {
            try FileManager.default.moveItem(
                at: folder.appendingPathComponent(old),
                to: folder.appendingPathComponent(name)
            )
        } catch {
            NSLog("Textream: could not rename the script: \(error.localizedDescription)")
            return nil
        }
        fileNames[id] = name
        return name
    }

    func trashScript(id: UUID, in projectID: UUID) {
        if let url = url(forPage: id, in: projectID) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        fileNames[id] = nil
        writtenText[id] = nil
    }

    /// Moves a script's file when it is dragged into another project.
    func moveScript(id: UUID, from source: UUID, to destination: UUID) {
        guard source != destination,
              let from = url(forPage: id, in: source),
              let folder = url(forProject: destination),
              let old = fileNames[id] else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = uniqueFileName(old, in: folder)
        do {
            try FileManager.default.moveItem(at: from, to: folder.appendingPathComponent(name))
            fileNames[id] = name
        } catch {
            NSLog("Textream: could not move the script: \(error.localizedDescription)")
        }
    }

    // MARK: - Names

    /// A file name that keeps the title readable and is still legal on every disk.
    func fileName(from title: String, extension ext: String = "md") -> String {
        var cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.isEmpty { cleaned = "Untitled" }
        return "\(cleaned).\(ext)"
    }

    private func uniqueFileName(_ name: String, in folder: URL, excluding keep: String? = nil) -> String {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        var candidate = name
        var counter = 2
        while candidate != keep,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func uniqueDirectoryName(from name: String, excluding keep: String? = nil) -> String {
        var base = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Project" }
        var candidate = base
        var counter = 2
        while candidate != keep,
              FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: - Migration

    /// Moves the old single-file session into the projects folder, once. Each folder becomes a
    /// project and each page becomes a Markdown file named after its title, so everything that
    /// was in the app is now a file the operator can see, move and back up. The old session file
    /// is left exactly where it was.
    private func migrateLegacySession() {
        let manager = FileManager.default
        guard let data = try? Data(contentsOf: legacySessionURL),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = session["pages"] as? [String], !pages.isEmpty else { return }

        let pageIDStrings = session["pageIDs"] as? [String] ?? []
        let pageIDs: [UUID] = (0..<pages.count).map { position in
            position < pageIDStrings.count ? (UUID(uuidString: pageIDStrings[position]) ?? UUID()) : UUID()
        }
        let pinned = Set((session["pinnedPageIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        let done = Set((session["donePageIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
        var doneSections: [UUID: [String]] = [:]
        for (key, value) in (session["doneSections"] as? [String: [String]] ?? [:]) {
            if let id = UUID(uuidString: key) { doneSections[id] = value }
        }

        var textByID: [UUID: String] = [:]
        for (position, id) in pageIDs.enumerated() { textByID[id] = pages[position] }

        var grouped: [UUID] = []
        var index = LibraryIndex()
        try? manager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        func write(_ ids: [UUID], intoProject name: String, expanded: Bool, isPinned: Bool) {
            guard !ids.isEmpty else { return }
            let directory = uniqueDirectoryName(from: name)
            let folder = rootURL.appendingPathComponent(directory, isDirectory: true)
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            var project = LibraryIndex.Project(
                id: UUID(),
                name: name,
                directory: directory,
                isExpanded: expanded,
                isPinned: isPinned
            )
            for id in ids {
                let text = textByID[id] ?? ""
                let file = uniqueFileName(fileName(from: MigrationTitle.of(text)), in: folder)
                try? text.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
                project.files.append(LibraryIndex.File(
                    id: id,
                    name: file,
                    isPinned: pinned.contains(id),
                    isDone: done.contains(id),
                    doneSections: doneSections[id] ?? []
                ))
            }
            index.projects.append(project)
        }

        for folder in (session["folders"] as? [[String: Any]] ?? []) {
            let name = (folder["name"] as? String) ?? "Project"
            let ids = (folder["pageIDs"] as? [String] ?? [])
                .compactMap(UUID.init(uuidString:))
                .filter { textByID[$0] != nil }
            grouped.append(contentsOf: ids)
            write(
                ids,
                intoProject: name,
                expanded: (folder["isExpanded"] as? Bool) ?? true,
                isPinned: (folder["isPinned"] as? Bool) ?? false
            )
        }

        let loose = pageIDs.filter { !grouped.contains($0) }
        write(loose, intoProject: "Scripts", expanded: true, isPinned: false)

        let current = session["currentPageIndex"] as? Int ?? 0
        if pageIDs.indices.contains(current) { index.currentPageID = pageIDs[current] }
        for project in index.projects { directories[project.id] = project.directory }
        writeIndex(index)
        NSLog("Textream: moved \(pages.count) pages into \(index.projects.count) projects at \(rootURL.path)")
    }
}

/// The title a migrated page takes as its file name.
private enum MigrationTitle {
    static func of(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: " ")
        return preview.isEmpty ? "Untitled" : preview
    }
}

/// Tells the app when anything in the library changes on disk. One stream for the whole tree, so
/// a project added in Finder is noticed as readily as a file added to one.
private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

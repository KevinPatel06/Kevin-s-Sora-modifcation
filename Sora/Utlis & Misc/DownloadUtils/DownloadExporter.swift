//
//  DownloadExporter.swift
//  Sora
//
//  Copies downloaded episodes out of the app sandbox into a user-chosen
//  folder in the Files app, one subfolder per show.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

// MARK: - Types
//
// Declared at file scope rather than nested in DownloadExporter: a type nested in a
// @MainActor class inherits that isolation, which conflicts with the nonisolated
// requirements of Equatable, Sendable and LocalizedError.

struct ExportProgress: Equatable {
    var current: Int
    var total: Int
    var name: String
}

struct ExportSummary: Equatable {
    var showCount: Int = 0
    var exported: Int = 0
    var skippedExisting: Int = 0
    var skippedHLS: Int = 0
    var failed: Int = 0
    var destinationPath: String = ""
}

/// A single file copy resolved ahead of time so the copy loop needs no model access.
private struct ExportJob: Sendable {
    let showFolder: String
    let baseName: String
    let source: URL
    let subtitle: URL?
    /// The asset's stored name, used to re-find the file if its path went stale.
    let assetName: String
}

private enum ExportJobResult: Sendable {
    case exported
    case alreadyExists
    case notExportable
    case failed
}

/// Folder created inside whatever the user picked.
private let exportRootFolderName = "Sora"

enum ExportError: LocalizedError {
    case noDestination
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .noDestination:
            return NSLocalizedString("No export folder has been chosen yet.", comment: "")
        case .destinationUnavailable:
            return NSLocalizedString("The export folder is no longer available. Please choose it again.", comment: "")
        }
    }
}

/// Presents the Files folder picker over whatever is on screen.
///
/// SwiftUI's `.fileImporter` proved unreliable in folder mode — the picker appears but
/// tapping Open never delivers a URL — so this drives `UIDocumentPickerViewController`
/// directly. The coordinator keeps itself alive until the delegate fires.
@MainActor
final class FolderPickerCoordinator: NSObject, UIDocumentPickerDelegate {

    private var onPick: ((URL?) -> Void)?
    private var retained: FolderPickerCoordinator?

    /// Presents the picker and calls back with the chosen folder, or nil if cancelled.
    func present(completion: @escaping (URL?) -> Void) {
        guard let presenter = Self.topViewController() else {
            Logger.shared.log("Export: no view controller available to present the folder picker", type: "Error")
            completion(nil)
            return
        }

        onPick = completion
        retained = self

        // Some providers vend directories as public.directory rather than public.folder;
        // accepting both makes more of the Files hierarchy selectable.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder, .directory],
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        presenter.present(picker, animated: true)

        Logger.shared.log("Export: folder picker presented", type: "Info")
    }

    private func finish(with url: URL?, reason: String) {
        Logger.shared.log("Export: folder picker \(reason) — \(url?.path ?? "no URL")", type: "Info")
        let callback = onPick
        onPick = nil
        retained = nil
        callback?(url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(with: urls.first, reason: urls.isEmpty ? "picked an empty selection" : "picked a folder")
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(with: nil, reason: "was cancelled or dismissed")
    }

    /// Walks past anything already presented so the picker isn't presented on a busy controller.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }

        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

/// Exports downloaded episodes into `<user picked folder>/Sora/<Show Title>/`.
///
/// The destination is picked once through the Files folder picker and kept as a
/// security-scoped bookmark, so later exports need no prompt.
@MainActor
final class DownloadExporter: ObservableObject {

    // MARK: - State

    @Published private(set) var progress: ExportProgress?
    @Published private(set) var hasDestination: Bool
    /// True once we've given up on the Files picker and are writing inside the app.
    @Published private(set) var usingAppFolder: Bool

    private static let bookmarkKey = "exportDestinationBookmark"
    private static let appFolderKey = "exportUsesAppFolder"

    init() {
        hasDestination = UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
        usingAppFolder = UserDefaults.standard.bool(forKey: Self.appFolderKey)
    }

    /// `Documents/Sora` inside the app's own container — always writable, no picker
    /// and no security scope involved. Reachable from the Files app.
    nonisolated static var appExportFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(exportRootFolderName, isDirectory: true)
    }

    /// Switches exports to the app's own Documents folder.
    func useAppFolder() {
        UserDefaults.standard.set(true, forKey: Self.appFolderKey)
        usingAppFolder = true
        Logger.shared.log("Export: falling back to the app's own folder at \(Self.appExportFolder.path)", type: "Info")
    }

    // MARK: - Destination

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if targetEnvironment(macCatalyst)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if targetEnvironment(macCatalyst)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    /// Hands the exported folder to Files in *export* mode, where the system performs
    /// the copy itself. This needs no security-scoped grant, so it still works when
    /// picking a destination folder doesn't.
    func shareExportedFolder() -> Bool {
        let folder = Self.appExportFolder

        // Sharing an empty folder looks like a failure, so treat it as one.
        let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var fileCount = 0
        while let item = contents?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { fileCount += 1 }
        }
        guard fileCount > 0 else {
            Logger.shared.log("Export: nothing to share, \(folder.path) holds no files", type: "Info")
            return false
        }
        Logger.shared.log("Export: sharing \(fileCount) files from \(folder.path)", type: "Download")

        guard let presenter = FolderPickerCoordinator.topViewController() else { return false }

        let picker = UIDocumentPickerViewController(forExporting: [folder], asCopy: true)
        presenter.present(picker, animated: true)
        Logger.shared.log("Export: sharing \(folder.path) via the export picker", type: "Info")
        return true
    }

    /// Shows the Files folder picker and stores the result.
    /// Calls back with `true` when a destination is now available.
    func pickDestination(completion: @escaping (Bool) -> Void) {
        let coordinator = FolderPickerCoordinator()
        coordinator.present { [weak self] url in
            guard let self = self, let url = url else {
                completion(false)
                return
            }
            do {
                try self.saveDestination(url)
                completion(true)
            } catch {
                Logger.shared.log("Export: could not save destination: \(error.localizedDescription)", type: "Error")
                completion(false)
            }
        }
    }

    /// Stores the folder the user picked in the Files app.
    func saveDestination(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        UserDefaults.standard.set(false, forKey: Self.appFolderKey)
        usingAppFolder = false

        let data = try url.bookmarkData(
            options: Self.bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        hasDestination = true
        Logger.shared.log("Export destination set to \(url.path)", type: "Info")
    }

    func clearDestination() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        hasDestination = false
    }

    /// The folder episodes actually go into.
    ///
    /// If the user already picked a folder called "Sora", use it as-is rather than
    /// nesting another one inside it.
    private nonisolated static func exportRoot(under destination: URL) -> URL {
        if destination.lastPathComponent.caseInsensitiveCompare(exportRootFolderName) == .orderedSame {
            return destination
        }
        return destination.appendingPathComponent(exportRootFolderName, isDirectory: true)
    }

    /// Human-readable path of the current destination, for display in the UI.
    var destinationDisplayPath: String? {
        guard let url = try? resolveDestination() else { return nil }
        return Self.exportRoot(under: url).path
    }

    /// Resolves the stored bookmark. The caller is responsible for balancing
    /// `startAccessingSecurityScopedResource()`.
    private func resolveDestination() throws -> URL {
        if usingAppFolder {
            return Self.appExportFolder
        }

        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            throw ExportError.noDestination
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            clearDestination()
            throw ExportError.destinationUnavailable
        }

        if isStale {
            // Refresh the bookmark so it keeps resolving on future launches.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
            }
        }

        return url
    }

    // MARK: - Export

    /// Copies every asset of the given shows into `<destination>/Sora/<Show>/`.
    ///
    /// Episodes stored as `.movpkg` bundles (HLS downloads) are counted as
    /// skipped rather than copied — they are not playable outside the app.
    /// Files already present at the destination are left alone.
    func export(shows: [(title: String, assets: [DownloadedAsset])]) async throws -> ExportSummary {
        let destination = try resolveDestination()

        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }

        var summary = ExportSummary(showCount: shows.count)
        let root = Self.exportRoot(under: destination)

        Logger.shared.log(
            "Export starting: \(shows.count) shows into \(root.path) (security scope \(accessed ? "granted" : "denied"))",
            type: "Download"
        )

        if let downloads = Self.downloadsDirectory,
           let files = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
            let byExtension = Dictionary(grouping: files, by: { $0.pathExtension.lowercased() })
                .map { "\($0.value.count) .\($0.key.isEmpty ? "(none)" : $0.key)" }
                .sorted()
            Logger.shared.log("Export: downloads folder holds \(byExtension.joined(separator: ", "))", type: "Download")
        } else {
            Logger.shared.log("Export: downloads folder is missing or unreadable", type: "Error")
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Logger.shared.log("Failed to create export root at \(root.path): \(error.localizedDescription)", type: "Error")
            throw ExportError.destinationUnavailable
        }
        summary.destinationPath = root.path

        // Resolve everything up front so the copy loop is pure file work.
        var jobs: [ExportJob] = []
        for show in shows {
            let folder = Self.sanitize(show.title)
            for asset in show.assets {
                jobs.append(
                    ExportJob(
                        showFolder: folder,
                        baseName: Self.episodeBaseName(for: asset),
                        source: asset.localURL,
                        subtitle: asset.localSubtitleURL,
                        assetName: asset.name
                    )
                )
            }
        }

        progress = ExportProgress(current: 0, total: jobs.count, name: "")
        defer { progress = nil }

        for (index, job) in jobs.enumerated() {
            progress = ExportProgress(current: index + 1, total: jobs.count, name: job.baseName)

            let result = await Task.detached(priority: .userInitiated) {
                Self.perform(job, under: root)
            }.value

            switch result {
            case .exported:        summary.exported += 1
            case .alreadyExists:   summary.skippedExisting += 1
            case .notExportable:   summary.skippedHLS += 1
            case .failed:          summary.failed += 1
            }
        }

        Logger.shared.log(
            "Export finished: \(summary.exported) copied, \(summary.skippedExisting) already present, "
            + "\(summary.skippedHLS) not exportable, \(summary.failed) failed",
            type: "Download"
        )

        return summary
    }

    // MARK: - File work (off the main actor)

    /// Where the app currently keeps finished downloads.
    private nonisolated static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SoraDownloads", isDirectory: true)
    }

    /// Finds the file an asset actually points at.
    ///
    /// iOS changes the container UUID between installs, so the absolute `localURL`
    /// stored with an asset goes stale even though the file is still on disk. The
    /// filename survives, so rebuild the path against the current container before
    /// giving up. This mirrors what `verifyAssetFileExists` does before playback.
    private nonisolated static func resolveSource(_ url: URL, assetName: String) -> URL? {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) { return url }
        guard let downloads = downloadsDirectory else { return nil }

        let rebuilt = downloads.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: rebuilt.path) {
            Logger.shared.log("Export: repaired stale path for \(url.lastPathComponent)", type: "Download")
            return rebuilt
        }

        guard let files = try? fileManager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let match = files.first(where: { $0.lastPathComponent == url.lastPathComponent })
            ?? files.first(where: { !assetName.isEmpty && $0.lastPathComponent.contains(assetName) }) {
            Logger.shared.log("Export: matched \(url.lastPathComponent) to \(match.lastPathComponent)", type: "Download")
            return match
        }

        return nil
    }

    private nonisolated static func perform(_ job: ExportJob, under root: URL) -> ExportJobResult {
        let fileManager = FileManager.default

        guard let source = resolveSource(job.source, assetName: job.assetName) else {
            Logger.shared.log("Export skipped, file not found anywhere: \(job.source.lastPathComponent)", type: "Error")
            return .failed
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            Logger.shared.log("Export skipped, missing file: \(source.path)", type: "Error")
            return .failed
        }

        // HLS downloads land as .movpkg bundles, which are useless outside the app.
        if isDirectory.boolValue || source.pathExtension.lowercased() == "movpkg" {
            Logger.shared.log("Export: \(job.baseName) is an HLS bundle, not exportable", type: "Download")
            return .notExportable
        }

        let showFolder = root.appendingPathComponent(job.showFolder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: showFolder, withIntermediateDirectories: true)
        } catch {
            Logger.shared.log("Export failed to create \(showFolder.path): \(error.localizedDescription)", type: "Error")
            return .failed
        }

        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let target = showFolder.appendingPathComponent("\(job.baseName).\(ext)")

        if fileManager.fileExists(atPath: target.path) {
            copySubtitle(job, to: showFolder)
            return .alreadyExists
        }

        do {
            try fileManager.copyItem(at: source, to: target)
        } catch {
            Logger.shared.log("Export failed for \(job.baseName): \(error.localizedDescription)", type: "Error")
            // Don't leave a half-written file behind.
            try? fileManager.removeItem(at: target)
            return .failed
        }

        copySubtitle(job, to: showFolder)
        return .exported
    }

    /// Copies the sidecar subtitle next to the video, using the same base name.
    private nonisolated static func copySubtitle(_ job: ExportJob, to showFolder: URL) {
        guard let stored = job.subtitle,
              let subtitle = resolveSource(stored, assetName: job.assetName) else { return }

        let ext = subtitle.pathExtension.isEmpty ? "vtt" : subtitle.pathExtension
        let target = showFolder.appendingPathComponent("\(job.baseName).\(ext)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }

        do {
            try FileManager.default.copyItem(at: subtitle, to: target)
        } catch {
            Logger.shared.log("Export failed for subtitle of \(job.baseName): \(error.localizedDescription)", type: "Error")
        }
    }

    // MARK: - Naming

    /// `S01E03 - Episode Title`, falling back to the stored asset name.
    nonisolated static func episodeBaseName(for asset: DownloadedAsset) -> String {
        let season = asset.metadata?.seasonNumber ?? asset.metadata?.season
        let episode = asset.metadata?.episode

        var prefix = ""
        if let episode = episode {
            prefix = String(format: "S%02dE%02d", season ?? 1, episode)
        }

        let title = asset.metadata?.episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let combined: String
        switch (prefix.isEmpty, title.isEmpty) {
        case (false, false): combined = "\(prefix) - \(title)"
        case (false, true):  combined = prefix
        default:             combined = asset.name
        }

        let sanitized = sanitize(combined)
        return sanitized.isEmpty ? sanitize(asset.name) : sanitized
    }

    /// Strips characters that are illegal or awkward in file names.
    nonisolated static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .components(separatedBy: .newlines)
            .joined(separator: " ")

        // Collapse the runs of whitespace the replacements can leave behind.
        let collapsed = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Trailing dots confuse some file browsers.
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(120))
    }
}

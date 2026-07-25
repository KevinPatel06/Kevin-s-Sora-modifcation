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

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        presenter.present(picker, animated: true)

        Logger.shared.log("Export: folder picker presented", type: "Info")
    }

    private func finish(with url: URL?) {
        Logger.shared.log("Export: folder picker returned \(url?.path ?? "nothing")", type: "Info")
        let callback = onPick
        onPick = nil
        retained = nil
        callback?(url)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(with: urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(with: nil)
    }

    /// Walks past anything already presented so the picker isn't presented on a busy controller.
    private static func topViewController() -> UIViewController? {
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

    private static let bookmarkKey = "exportDestinationBookmark"

    init() {
        hasDestination = UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil
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
                        subtitle: asset.localSubtitleURL
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

    private nonisolated static func perform(_ job: ExportJob, under root: URL) -> ExportJobResult {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: job.source.path, isDirectory: &isDirectory) else {
            Logger.shared.log("Export skipped, missing file: \(job.source.path)", type: "Error")
            return .failed
        }

        // HLS downloads land as .movpkg bundles, which are useless outside the app.
        if isDirectory.boolValue || job.source.pathExtension.lowercased() == "movpkg" {
            return .notExportable
        }

        let showFolder = root.appendingPathComponent(job.showFolder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: showFolder, withIntermediateDirectories: true)
        } catch {
            Logger.shared.log("Export failed to create \(showFolder.path): \(error.localizedDescription)", type: "Error")
            return .failed
        }

        let ext = job.source.pathExtension.isEmpty ? "mp4" : job.source.pathExtension
        let target = showFolder.appendingPathComponent("\(job.baseName).\(ext)")

        if fileManager.fileExists(atPath: target.path) {
            copySubtitle(job, to: showFolder)
            return .alreadyExists
        }

        do {
            try fileManager.copyItem(at: job.source, to: target)
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
        guard let subtitle = job.subtitle,
              FileManager.default.fileExists(atPath: subtitle.path) else { return }

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

import Foundation

enum MediaOutputFormat: String, Equatable, Sendable {
    case mp4
    case wav
    case webm
}

struct FileStore {
    private static let defaultStartupCleanup: Void = {
        if let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first {
            let root = documents.appendingPathComponent("Exports", isDirectory: true)
            try? cleanupIncompleteExports(in: root, fileManager: .default)
        }
        if let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first {
            let root = caches.appendingPathComponent("HLSJobs", isDirectory: true)
            try? cleanupAbandonedJobs(in: root, fileManager: .default)
        }
    }()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        _ = Self.defaultStartupCleanup
    }

    func makeJobDirectory() throws -> URL {
        let root = try jobsRoot()
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }

    func outputLocations(
        for sourceURL: URL,
        format: MediaOutputFormat = .mp4
    ) throws -> (temporary: URL, final: URL) {
        let root = try exportsRoot()
        let base = sanitizedBaseName(sourceURL.host ?? sourceURL.deletingPathExtension().lastPathComponent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let stem = "\(base)-\(timestamp)"

        var final = root.appendingPathComponent("\(stem).\(format.rawValue)")
        var suffix = 2
        while fileManager.fileExists(atPath: final.path) {
            final = root.appendingPathComponent("\(stem)-\(suffix).\(format.rawValue)")
            suffix += 1
        }
        let temporary = root.appendingPathComponent(
            ".\(final.deletingPathExtension().lastPathComponent).part.\(format.rawValue)"
        )
        return (temporary, final)
    }

    func removeJobDirectory(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    /// Copies a potentially large clear-media file into a placeholder that is
    /// protected before the first byte is written. The final move preserves
    /// the protected inode.
    func copyProtectedFile(from sourceURL: URL, to destinationURL: URL) async throws {
        guard sourceURL.isFileURL,
              destinationURL.isFileURL,
              sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw WidevineProcessingError.invalidOutput
        }
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let parentValues = try destinationURL.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let maximumOutputBytes = try LocalFFmpegOutputLimit.maximumBytes(
            for: destinationURL,
            fileManager: fileManager
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0,
              Int64(sourceSize) < maximumOutputBytes,
              parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true else {
            throw WidevineProcessingError.invalidOutput
        }

        try? fileManager.removeItem(at: destinationURL)
        let created = fileManager.createFile(
            atPath: destinationURL.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        guard created else { throw WidevineProcessingError.invalidOutput }

        do {
            let source = try FileHandle(forReadingFrom: sourceURL)
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? source.close()
                try? destination.close()
            }
            var writtenBytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try source.read(upToCount: 1_024 * 1_024),
                      !chunk.isEmpty else {
                    break
                }
                let chunkBytes = Int64(chunk.count)
                guard writtenBytes < maximumOutputBytes,
                      chunkBytes < maximumOutputBytes - writtenBytes else {
                    throw HLSError.exportFailed("copied output exceeded its storage limit")
                }
                try destination.write(contentsOf: chunk)
                writtenBytes += chunkBytes
            }
            guard writtenBytes == Int64(sourceSize) else {
                throw WidevineProcessingError.invalidOutput
            }
            try destination.synchronize()
            try LocalFFmpegOutputLimit.validateCompletedOutput(
                at: destinationURL,
                maximumBytes: maximumOutputBytes
            )
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    static func cleanupIncompleteExports(
        in root: URL,
        fileManager: FileManager = .default
    ) throws {
        let normalizedRoot = root.standardizedFileURL
        guard fileManager.fileExists(atPath: normalizedRoot.path) else { return }
        let rootValues = try normalizedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw WidevineProcessingError.invalidOutput
        }
        let children = try fileManager.contentsOfDirectory(
            at: normalizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for child in children {
            let normalized = child.standardizedFileURL
            let name = normalized.lastPathComponent
            guard normalized.deletingLastPathComponent() == normalizedRoot,
                  name.hasPrefix("."),
                  (name.hasSuffix(".part.mp4")
                    || name.hasSuffix(".part.wav")
                    || name.hasSuffix(".part.webm")) else {
                continue
            }
            let values = try normalized.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try fileManager.removeItem(at: normalized)
        }
    }

    /// Removes only UUID-named job directories created by this app. This also
    /// clears protected SAMPLE-AES key files left by a force-quit or reboot.
    static func cleanupAbandonedJobs(
        in root: URL,
        fileManager: FileManager = .default
    ) throws {
        let normalizedRoot = root.standardizedFileURL
        guard fileManager.fileExists(atPath: normalizedRoot.path) else { return }
        let rootValues = try normalizedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw WidevineProcessingError.invalidOutput
        }
        let children = try fileManager.contentsOfDirectory(
            at: normalizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for child in children {
            let normalized = child.standardizedFileURL
            guard normalized.deletingLastPathComponent() == normalizedRoot,
                  UUID(uuidString: normalized.lastPathComponent) != nil else {
                continue
            }
            let values = try normalized.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try fileManager.removeItem(at: normalized)
        }
    }

    private func jobsRoot() throws -> URL {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw HLSError.network("Cachesフォルダを開けません")
        }
        let root = caches.appendingPathComponent("HLSJobs", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func exportsRoot() throws -> URL {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw HLSError.network("Documentsフォルダを開けません")
        }
        let root = documents.appendingPathComponent("Exports", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        let values = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw WidevineProcessingError.invalidOutput
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: root.path
        )
        return root
    }

    private func sanitizedBaseName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "video" : String(value.prefix(60))
    }
}

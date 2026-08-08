import Foundation

struct FileStore: Sendable {
    private let fileManager = FileManager.default

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

    func outputLocations(for sourceURL: URL) throws -> (temporary: URL, final: URL) {
        let root = try exportsRoot()
        let base = sanitizedBaseName(sourceURL.host ?? sourceURL.deletingPathExtension().lastPathComponent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let stem = "\(base)-\(timestamp)"

        var final = root.appendingPathComponent("\(stem).mp4")
        var suffix = 2
        while fileManager.fileExists(atPath: final.path) {
            final = root.appendingPathComponent("\(stem)-\(suffix).mp4")
            suffix += 1
        }
        let temporary = root.appendingPathComponent(".\(final.deletingPathExtension().lastPathComponent).part.mp4")
        return (temporary, final)
    }

    func removeJobDirectory(_ url: URL) {
        try? fileManager.removeItem(at: url)
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
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sanitizedBaseName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "video" : String(value.prefix(60))
    }
}


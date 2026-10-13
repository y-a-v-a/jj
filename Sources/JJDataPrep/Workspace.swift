import Foundation

struct PrepError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The package being prepared: where raw downloads are cached and where the
/// processed resources go.
struct Workspace: Sendable {
    let root: URL

    init(root path: String?) throws {
        let fm = FileManager.default
        func isPackage(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) }
        if let path {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard isPackage(url) else { throw PrepError("\(url.path) does not contain Package.swift") }
            root = url
            return
        }
        var url = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true).standardizedFileURL
        while !isPackage(url) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                throw PrepError("no Package.swift in the current directory or its parents; pass --root")
            }
            url = parent
        }
        root = url
    }

    var rawDirectory: URL { root.appendingPathComponent("data/raw", isDirectory: true) }
    var earthDirectory: URL { root.appendingPathComponent("Sources/MyriaData/Resources/Earth", isDirectory: true) }

    func output(_ name: String) -> URL { earthDirectory.appendingPathComponent(name) }

    /// The cached raw file `data/raw/<name>`, downloaded from `source` first if missing.
    func raw(_ name: String, from source: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let destination = rawDirectory.appendingPathComponent(name)
        if let size = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int, size > 0 {
            return destination
        }
        print("   downloading \(source)")
        let partial = rawDirectory.appendingPathComponent(name + ".part")
        try? fm.removeItem(at: partial)
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "--fail", "--silent", "--show-error", "--location", "--globoff",
            "--retry", "3", "--retry-delay", "5", "--connect-timeout", "30", "--max-time", "1800",
            "--output", partial.path, source,
        ]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            try? fm.removeItem(at: partial)
            throw PrepError("download failed (curl exit \(curl.terminationStatus)): \(source)")
        }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }

    /// Writes a resource into the Earth folder and reports its size.
    @discardableResult
    func write(_ data: Data, to name: String) throws -> Int {
        try FileManager.default.createDirectory(at: earthDirectory, withIntermediateDirectories: true)
        try data.write(to: output(name), options: .atomic)
        print("   wrote \(name): \(formatBytes(data.count))")
        return data.count
    }
}

func formatBytes(_ count: Int) -> String {
    switch count {
    case ..<1024: "\(count) B"
    case ..<(1024 * 1024): String(format: "%.1f KB", Double(count) / 1024)
    default: String(format: "%.2f MB", Double(count) / 1_048_576)
    }
}

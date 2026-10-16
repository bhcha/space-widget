import Foundation
import Darwin

/// PeonPing's default presentation: project title, separate completion status.
/// Read labels and repository metadata only; never read transcripts or run project scripts.
enum AgentProjectName {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(50))
    }

    static func resolve(cwd: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let label = clean(environment["CLAUDE_SESSION_NAME"]) { return label }
        guard let cwd, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 else { return nil }
        let directory = URL(fileURLWithPath: cwd).standardizedFileURL
        if let label = read(directory.appendingPathComponent(".peon-label"), limit: 4096)?.components(separatedBy: .newlines).first,
           let label = clean(label) { return label }
        if let git = gitDirectory(from: directory),
           let config = read(git.appendingPathComponent("config"), limit: 262_144),
           let remote = originRemote(in: config) {
            let leaf = remote.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? ""
            // SCP-style URLs without an organization separator may still contain a colon.
            let name = leaf.components(separatedBy: ":").last ?? leaf
            if let label = clean(name.hasSuffix(".git") ? String(name.dropLast(4)) : name) { return label }
        }
        return directory.path == "/" ? nil : clean(directory.lastPathComponent)
    }

    private static func gitDirectory(from directory: URL) -> URL? {
        var cursor = directory
        for _ in 0..<64 {
            let dotgit = cursor.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotgit.path, isDirectory: &isDirectory) {
                var git = dotgit
                if !isDirectory.boolValue {
                    guard let pointer = read(dotgit, limit: 4096), pointer.hasPrefix("gitdir:") else { return nil }
                    let path = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    git = URL(fileURLWithPath: path, relativeTo: cursor).standardizedFileURL
                }
                if let common = read(git.appendingPathComponent("commondir"), limit: 4096)?.trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
                    git = URL(fileURLWithPath: common, relativeTo: git).standardizedFileURL
                }
                return git
            }
            guard cursor.path != "/" else { break }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func originRemote(in config: String) -> String? {
        var isOrigin = false
        for raw in config.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { isOrigin = line == "[remote \"origin\"]"; continue }
            guard isOrigin, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func read(_ url: URL, limit: Int) -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

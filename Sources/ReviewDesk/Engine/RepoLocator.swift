import Foundation

/// Maps GitHub repositories to local clones, cloning ones that aren't found.
actor RepoLocator {
    private var index: [String: String] = [:]
    private var scannedAt = Date.distantPast

    /// Scans `roots` for git repositories and indexes them by the GitHub repos their remotes point at.
    @discardableResult
    func scan(roots: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for root in roots {
            Self.walk(URL(fileURLWithPath: Tools.expand(root)), depth: 0, into: &found)
        }
        index = found
        scannedAt = Date()
        return found
    }

    func path(for slug: String, roots: [String]) -> String? {
        let key = slug.lowercased()
        if let path = index[key], FileManager.default.fileExists(atPath: path) { return path }
        if Date().timeIntervalSince(scannedAt) > 30 { scan(roots: roots) }
        return index[key]
    }

    /// Makes a blobless clone with no checkout; reviews only ever use worktrees of it.
    func clone(slug: String, into cloneDir: String, git: Git) async throws -> String {
        let destination = Tools.expand(cloneDir) + "/" + slug
        if FileManager.default.fileExists(atPath: destination + "/.git") { return destination }
        try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try await git.run(["clone", "--filter=blob:none", "--no-checkout", "--quiet",
                           "https://github.com/\(slug).git", destination], in: nil)
        index[slug.lowercased()] = destination
        return destination
    }

    private static let skippedDirectories: Set<String> = ["node_modules", "build", "target", "dist", "vendor", "Pods"]

    private static func walk(_ dir: URL, depth: Int, into found: inout [String: String]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let gitDir = dir.appendingPathComponent(".git")
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            for slug in remoteSlugs(config: gitDir.appendingPathComponent("config")) where found[slug] == nil {
                found[slug] = dir.path
            }
            return
        }
        guard depth < 3,
              let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { return }
        for child in children where !skippedDirectories.contains(child.lastPathComponent) {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(child, depth: depth + 1, into: &found)
            }
        }
    }

    static func remoteSlugs(config: URL) -> [String] {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        var slugs: [String] = []
        var inRemote = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRemote = line.hasPrefix("[remote ")
            } else if inRemote, line.hasPrefix("url"), let equals = line.firstIndex(of: "=") {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let slug = githubSlug(value) { slugs.append(slug) }
            }
        }
        return slugs
    }

    /// `owner/repo` (lowercased) for a github.com remote URL in any of git's URL forms.
    static func githubSlug(_ url: String) -> String? {
        var rest: Substring?
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/", "git://github.com/"]
        where url.hasPrefix(prefix) {
            rest = url.dropFirst(prefix.count)
        }
        guard var path = rest else { return nil }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])".lowercased()
    }
}

import Foundation

/// Creates and removes the temporary worktrees reviews run in.
/// Worktrees share the local clone's objects and leave its working tree and branches alone.
enum WorkspaceBuilder {
    static func prepare(pr: PullRequest, repoPath: String, git: Git,
                        log: @escaping @Sendable (String) -> Void) async throws -> Workspace {
        let key = pr.key
        let name = "\(key.owner)-\(key.repo)-\(key.number)-\(pr.headSha.prefix(7))-\(UUID().uuidString.prefix(4).lowercased())"
        var workspace = Workspace(repoPath: repoPath, runDir: Paths.runs + "/" + name)

        var missing: [String] = []
        for sha in [pr.headSha, pr.baseSha] where !missing.contains(sha) {
            if !(await git.succeeds(["cat-file", "-e", "\(sha)^{commit}"], in: repoPath)) { missing.append(sha) }
        }
        if !missing.isEmpty {
            log("Fetching \(missing.count) commit\(missing.count == 1 ? "" : "s") from GitHub…")
            try await git.run(["fetch", "--no-tags", "--no-write-fetch-head", "--quiet",
                               "https://github.com/\(key.slug).git"] + missing, in: repoPath)
        }

        try FileManager.default.createDirectory(atPath: workspace.contextDir, withIntermediateDirectories: true)
        do {
            try record(workspace)
            log("Checking out \(pr.headSha.prefix(7)) in a temporary worktree…")
            try await git.run(["worktree", "add", "--detach", "--quiet", workspace.worktree, pr.headSha], in: repoPath)

            let mergeBase = try await git.run(["merge-base", pr.baseSha, pr.headSha], in: repoPath)
            workspace.mergeBase = mergeBase
            try record(workspace)

            let range = [mergeBase, pr.headSha]
            let diff = try await git.output(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M"] + range, in: repoPath)
            let stat = try await git.output(["diff", "--no-color", "--stat=160", "-M"] + range, in: repoPath)
            let commits = try await git.output(["log", "--no-color", "--reverse", "--format=- %h %s (%an)",
                                                "\(mergeBase)..\(pr.headSha)"], in: repoPath)
            try diff.write(toFile: workspace.rawDiffPath, atomically: true, encoding: .utf8)
            try DiffIndex.annotate(diff).write(toFile: workspace.contextDir + "/pr.diff", atomically: true, encoding: .utf8)
            try describe(pr, mergeBase: mergeBase, stat: stat, commits: commits)
                .write(toFile: workspace.contextDir + "/pr.md", atomically: true, encoding: .utf8)
            return workspace
        } catch {
            let ws = workspace
            await Task.detached { await remove(ws) }.value
            throw error
        }
    }

    static func remove(_ workspace: Workspace) async {
        if let git = Git.make(), FileManager.default.fileExists(atPath: workspace.worktree) {
            _ = try? await git.run(["worktree", "remove", "--force", workspace.worktree], in: workspace.repoPath)
        }
        try? FileManager.default.removeItem(atPath: workspace.runDir)
    }

    /// Removes run directories left behind by reviews that are no longer kept.
    static func cleanOrphans(keeping keep: Set<String>) async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Paths.runs) else { return }
        for name in names {
            let dir = Paths.runs + "/" + name
            if keep.contains(dir) { continue }
            if let data = FileManager.default.contents(atPath: dir + "/run.json"),
               let workspace = try? JSONDecoder().decode(Workspace.self, from: data) {
                await remove(workspace)
            } else {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }
    }

    private static func record(_ workspace: Workspace) throws {
        try JSONEncoder().encode(workspace).write(to: URL(fileURLWithPath: workspace.runDir + "/run.json"))
    }

    private static func describe(_ pr: PullRequest, mergeBase: String, stat: String, commits: String) -> String {
        let body = pr.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            # \(pr.title)

            - Pull request: \(pr.url)
            - Author: @\(pr.author)
            - Base: \(pr.baseRef) (merge base \(mergeBase.prefix(10)))
            - Head: \(pr.headRef) (\(pr.headSha.prefix(10)))
            - Size: +\(pr.additions) -\(pr.deletions) in \(pr.changedFiles) files

            ## Description

            \(body.isEmpty ? "(No description.)" : body)

            ## Commits

            \(commits.trimmingCharacters(in: .whitespacesAndNewlines))

            ## Files changed

            \(stat.trimmingCharacters(in: .newlines))
            """
    }
}

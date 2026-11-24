import Foundation

struct PipelineResult: Sendable {
    var pr: PullRequest
    var workspace: Workspace
    var output: RunOutput
}

/// Runs a whole review: fetch the PR, find or clone the repo, check out a worktree, run Claude.
/// On failure or cancellation the worktree is removed; on success the caller owns it.
enum Pipeline {
    struct Options: Sendable {
        var settings: AppSettings
        var model: String
        var effort: String
        /// Zero means no limit.
        var budgetUSD: Double
        var timeoutMinutes: Double
        var scope: String
        var voice: String
        var extra: String
    }

    static func run(key: PRKey, options: Options, locator: RepoLocator,
                    onStage: @escaping @Sendable (ReviewStatus) -> Void,
                    log: @escaping @Sendable (LogEntry) -> Void) async throws -> PipelineResult {
        let settings = options.settings
        guard let claude = Tools.locate("claude", override: settings.claudePath) else {
            throw RunError(message: "Couldn't find the claude CLI. Set its path in Settings → Local Setup.")
        }
        let credentials = try await GitHubCredentials.resolve(settings)
        guard let git = Git.make(token: credentials.token(for: key.owner)) else {
            throw RunError(message: "Couldn't find git.")
        }

        let (viewer, pr) = try await GitHub(credentials: credentials).pullRequest(key)
        log(.info("Head is \(pr.headSha.prefix(7)), +\(pr.additions) -\(pr.deletions) in \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")."))

        let roots = settings.repoRoots + [settings.cloneDir]
        let repoPath: String
        if let local = await locator.path(for: key.slug, roots: roots) {
            repoPath = local
            log(.info("Using the local clone at \(Tools.abbreviate(local))."))
        } else {
            log(.info("No local clone of \(key.slug) found; cloning it into \(settings.cloneDir)…"))
            repoPath = try await locator.clone(slug: key.slug, into: settings.cloneDir, git: git)
        }

        let workspace = try await WorkspaceBuilder.prepare(pr: pr, repoPath: repoPath, git: git) { log(.info($0)) }
        do {
            try Task.checkCancellation()
            onStage(.running)
            log(.info("Starting Claude (\(options.model), \(options.effort) effort)…"))
            var output = try await ReviewRunner.run(
                pr: pr, viewer: viewer, workspace: workspace,
                claude: ClaudeOptions(path: claude, model: options.model, effort: options.effort,
                                      maxBudgetUSD: options.budgetUSD, timeoutMinutes: options.timeoutMinutes),
                scope: options.scope, voice: options.voice, extra: options.extra, log: log)

            let index = DiffIndex(path: workspace.rawDiffPath)
            for i in output.comments.indices { index.place(&output.comments[i]) }
            let outside = output.comments.filter { !$0.inDiff }.count
            log(.info("Draft ready: \(output.comments.count) comment\(output.comments.count == 1 ? "" : "s")"
                      + (outside > 0 ? ", \(outside) not on changed lines." : ".")))
            return PipelineResult(pr: pr, workspace: workspace, output: output)
        } catch {
            await Task.detached { await WorkspaceBuilder.remove(workspace) }.value
            throw error
        }
    }
}

import Foundation

/// Command-line entry points for scripting and testing without the UI. Nothing here posts to GitHub.
enum Headless {
    static let commands: Set<String> = ["--list", "--scan", "--review", "--help"]

    static func run(_ args: [String]) async -> Int32 {
        let settings = AppSettings.load()
        let presets = Presets.builtIn + Store.load("presets.json", default: [Preset]())

        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        do {
            switch args[0] {
            case "--list":
                let github = GitHub(credentials: try await GitHubCredentials.resolve(settings))
                let listing = try await github.listing(watch: settings.watchedScopes, days: settings.watchDays, added: [], known: [:])
                print("Open pull requests for @\(listing.viewer):")
                for pr in listing.requested + listing.watched {
                    let kind = listing.requested.contains(pr) ? (pr.requestedDirectly ? "you  " : "team ") : "watch"
                    print("  \(pr.key.id)\t\(kind)\t\(pr.headSha.prefix(8))\t\(pr.title)")
                }
                for warning in listing.warnings { FileHandle.standardError.write(Data("warning: \(warning)\n".utf8)) }

            case "--scan":
                let found = await RepoLocator().scan(roots: settings.repoRoots + [settings.cloneDir])
                for (slug, path) in found.sorted(by: { $0.key < $1.key }) { print("\(slug)\t\(Tools.abbreviate(path))") }

            case "--review":
                guard args.count >= 2, let key = PRKey(args[1]) else { printUsage(); return 2 }
                let policy = settings.policy(for: key.slug)
                var options = policy.options(automatic: false)
                if let model = value(after: "--model") { options.model = model }
                if let effort = value(after: "--effort") { options.effort = effort }
                if let budget = value(after: "--budget").flatMap(Double.init) { options.budget = Limit(on: budget > 0, value: budget) }
                if let scope = value(after: "--scope") { options.scopePresetID = "builtin.scope.\(scope)" }
                if let voice = value(after: "--voice") { options.voicePresetID = "builtin.voice.\(voice)" }
                let scope = presets.first { $0.id == options.scopePresetID } ?? presets.first { $0.kind == .scope }!
                let voice = presets.first { $0.id == options.voicePresetID } ?? presets.first { $0.kind == .voice }!

                let result = try await Pipeline.run(
                    key: key,
                    options: .init(settings: settings, model: options.model, effort: options.effort,
                                   budgetUSD: options.budget.effective, timeoutMinutes: options.timeLimit.effective,
                                   scope: scope.text, voice: voice.text, extra: options.instructions),
                    locator: RepoLocator(),
                    onStage: { _ in },
                    log: { entry in FileHandle.standardError.write(Data("[\(entry.kind.rawValue)] \(entry.text)\n".utf8)) })

                var review = Review(pr: result.pr, options: options)
                review.apply(result)
                print("== Summary (\(review.event.label)) ==\n\(review.summary)\n")
                for comment in review.comments {
                    print("== [\(comment.severity.rawValue)] \(comment.location)\(comment.inDiff ? "" : "  (not in diff)") ==\n\(comment.body)\n")
                }
                let payload = Poster.payload(for: review, event: review.event, footer: policy[\.footer])
                let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                print("== Payload that would be posted (not posted) ==\n\(String(decoding: json, as: UTF8.self))")
                if let cost = review.costUSD { print("\nAPI-equivalent cost: $\(String(format: "%.2f", cost))") }

                if args.contains("--save") {
                    review.status = .drafted
                    review.finishedAt = Date()
                    Store.save([review] + Store.load("reviews.json", default: [Review]()), "reviews.json")
                    print("Saved as a draft in Review Desk.")
                } else if args.contains("--keep") {
                    print("Worktree kept. Continue with: cd '\(result.workspace.worktree)' && claude --resume \(review.sessionID ?? "")")
                } else {
                    await WorkspaceBuilder.remove(result.workspace)
                }

            default:
                printUsage()
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func printUsage() {
        print("""
            Usage:
              ReviewDesk --list                     List open PRs requesting your review or in watched repositories
              ReviewDesk --scan                     List local clones found in the configured folders
              ReviewDesk --review <owner/repo#N|URL> [--model M] [--effort E] [--budget USD]
                                  [--scope standard|bugs|thorough|security] [--voice colleague|terse|mentor]
                                  [--keep | --save]
                                                    Review a PR and print the draft. Never posts.
                                                    --keep leaves the worktree for `claude --resume`.
                                                    --save adds the draft to the app (quit the app first).

            Set REVIEWDESK_TOKEN to use that GitHub token instead of the one configured in Settings.
            """)
    }
}

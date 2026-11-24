import Foundation

struct GitHubError: LocalizedError {
    var message: String
    var unprocessable = false
    var errorDescription: String? { message }
}

/// GitHub tokens, chosen by repository owner.
struct GitHubCredentials: Sendable {
    struct Entry: Sendable {
        var owner: String
        var token: String
    }

    var entries: [Entry]

    /// The owner's token, or else the token that has no owner.
    func token(for owner: String) -> String? {
        entries.first { !$0.owner.isEmpty && $0.owner.caseInsensitiveCompare(owner) == .orderedSame }?.token
            ?? entries.first { $0.owner.isEmpty }?.token
    }

    var allTokens: [String] {
        var seen = Set<String>()
        return entries.map(\.token).filter { seen.insert($0).inserted }
    }

    static func resolve(_ settings: AppSettings) async throws -> GitHubCredentials {
        if let token = ProcessInfo.processInfo.environment["REVIEWDESK_TOKEN"], !token.isEmpty {
            return GitHubCredentials(entries: [Entry(owner: "", token: token)])
        }
        switch settings.githubAuth {
        case .ghCLI:
            guard let gh = Tools.locate("gh", override: settings.ghPath) else {
                throw GitHubError(message: "Couldn't find the gh CLI. Set its path in Settings → GitHub, or use personal access tokens.")
            }
            let token = try await Shell.check(gh, ["auth", "token"])
            return GitHubCredentials(entries: [Entry(owner: "", token: token)])
        case .tokens:
            let entries = settings.githubTokens.compactMap { entry in
                Keychain.read(entry.id).map { Entry(owner: entry.owner.trimmingCharacters(in: .whitespaces), token: $0) }
            }
            guard !entries.isEmpty else { throw GitHubError(message: "Add a GitHub token in Settings → GitHub.") }
            return GitHubCredentials(entries: entries)
        }
    }
}

/// The GitHub REST API.
struct GitHub: Sendable {
    let credentials: GitHubCredentials

    static let requestedQuery = "is:pr is:open archived:false review-requested:@me"

    struct Listing: Sendable {
        var viewer: String
        var requested: [PullRequest] = []
        var watched: [PullRequest] = []
        /// The added pull requests that are still open.
        var added: [PullRequest] = []
        /// The added pull requests that have been closed or merged.
        var closed: [PRKey] = []
        /// Pull requests or searches that couldn't be loaded.
        var warnings: [String] = []
    }

    /// Open pull requests that request a review from the viewer or one of their teams; those in the `watch`
    /// owners and repositories (except the viewer's own) updated within `days` days; and the `added` ones.
    /// Copies in `known` are reused while GitHub reports them unchanged.
    func listing(watch: [String], days: Int, added: [PRKey], known: [String: PullRequest]) async throws -> Listing {
        let tokens = credentials.allTokens
        guard let first = tokens.first else { throw GitHubError(message: "No GitHub token is set up.") }
        let viewer = try await viewerLogin(token: first)
        var listing = Listing(viewer: viewer)

        var seen = Set<PRKey>()
        var requested: [Job] = []
        var failures: [Error] = []
        // Each token can see different repositories, so search with all of them.
        for token in tokens {
            do {
                for item in try await search(Self.requestedQuery, token: token) {
                    guard let key = item.key, seen.insert(key).inserted else { continue }
                    requested.append(Job(key: key, token: credentials.token(for: key.owner) ?? token, updatedAt: item.updated_at))
                }
            } catch {
                failures.append(error)
            }
        }
        if requested.isEmpty, let failure = failures.first { throw failure }
        listing.warnings = failures.map { "A token's search failed: \($0.localizedDescription)" }

        var watched: [Job] = []
        let since = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
        for scope in watch {
            let owner = String(scope.split(separator: "/").first ?? "")
            let token = credentials.token(for: owner) ?? first
            var query = "is:pr is:open archived:false \(scope.contains("/") ? "repo" : "user"):\(scope)"
            if let since { query += " updated:>=\(Self.day(since))" }
            do {
                for item in try await search(query, token: token, perPage: 100) {
                    guard let key = item.key, item.user?.login.caseInsensitiveCompare(viewer) != .orderedSame,
                          seen.insert(key).inserted else { continue }
                    watched.append(Job(key: key, token: token, updatedAt: item.updated_at))
                }
            } catch {
                listing.warnings.append("Couldn't list pull requests in \(scope): \(error.localizedDescription)")
            }
        }

        let addedJobs = added.filter { !seen.contains($0) }.map {
            Job(key: $0, token: credentials.token(for: $0.owner) ?? first, updatedAt: nil)
        }
        let results = await load(requested + watched + addedJobs, viewer: viewer, known: known)
        func collect(_ jobs: [Job]) -> [PullRequest] {
            jobs.compactMap { job in
                switch results[job.key] {
                case .success(let pr)?: return pr
                case .failure(let error)?: listing.warnings.append("Couldn't load \(job.key.id): \(error.localizedDescription)")
                case nil: break
                }
                return nil
            }
        }
        listing.requested = collect(requested)
        listing.watched = collect(watched)
        for pr in collect(addedJobs) {
            if pr.isOpen { listing.added.append(pr) } else { listing.closed.append(pr.key) }
        }
        listing.added += listing.requested.filter { added.contains($0.key) } + listing.watched.filter { added.contains($0.key) }
        return listing
    }

    private struct Job: Sendable {
        var key: PRKey
        var token: String
        /// From search results, to tell whether a known copy is current.
        var updatedAt: String?
    }

    /// Loads pull requests a few at a time.
    private func load(_ jobs: [Job], viewer: String, known: [String: PullRequest]) async -> [PRKey: Result<PullRequest, Error>] {
        var results: [PRKey: Result<PullRequest, Error>] = [:]
        var remaining: [Job] = []
        for job in jobs {
            if let cached = known[job.key.id], let updated = job.updatedAt,
               cached.updatedAt == ISO8601DateFormatter().date(from: updated) {
                results[job.key] = .success(cached)
            } else {
                remaining.append(job)
            }
        }
        await withTaskGroup(of: (PRKey, Result<PullRequest, Error>).self) { group in
            var queue = remaining.makeIterator()
            func next() -> Bool {
                guard let job = queue.next() else { return false }
                group.addTask {
                    do { return (job.key, .success(try await pull(job.key, viewer: viewer, token: job.token))) }
                    catch { return (job.key, .failure(error)) }
                }
                return true
            }
            for _ in 0..<6 where !next() { break }
            while let (key, result) = await group.next() {
                results[key] = result
                _ = next()
            }
        }
        return results
    }

    private func search(_ query: String, token: String, perPage: Int = 50) async throws -> [SearchResult.Item] {
        let data = try await get("search/issues", query: ["q": query, "per_page": String(perPage), "sort": "updated"], token: token)
        return try JSONDecoder().decode(SearchResult.self, from: data).items
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The canonical name of an owner, or of an owner/repo, as the credentials see it.
    func canonicalName(_ scope: String) async throws -> String {
        let owner = String(scope.split(separator: "/").first ?? "")
        guard let token = credentials.token(for: owner) ?? credentials.allTokens.first else {
            throw GitHubError(message: "No GitHub token is set up.")
        }
        if scope.contains("/") {
            struct Repo: Decodable { let full_name: String }
            return try JSONDecoder().decode(Repo.self, from: try await get("repos/\(scope)", token: token)).full_name
        }
        return try JSONDecoder().decode(Login.self, from: try await get("users/\(scope)", token: token)).login
    }

    func pullRequest(_ key: PRKey) async throws -> (viewer: String, pr: PullRequest) {
        guard let token = credentials.token(for: key.owner) ?? credentials.allTokens.first else {
            throw GitHubError(message: "No GitHub token is set up.")
        }
        let viewer = try await viewerLogin(token: token)
        return (viewer, try await pull(key, viewer: viewer, token: token))
    }

    /// When the viewer was last asked to review the pull request, or one of the requested teams was if the
    /// viewer was only requested through a team. Nil if no such request is found.
    func latestReviewRequest(for pr: PullRequest, viewer: String) async throws -> Date? {
        guard let token = credentials.token(for: pr.key.owner) ?? credentials.allTokens.first else { return nil }
        // Events are oldest first, so the newest requests are on the last page or the one before it.
        let first = try await fetch(Self.url("repos/\(pr.key.slug)/issues/\(pr.key.number)/events", query: ["per_page": "100"]), token: token)
        var pages = [first]
        if let lastURL = Self.page("last", in: first.link) {
            let last = try await fetch(lastURL, token: token)
            pages = [last]
            if let previousURL = Self.page("prev", in: last.link) {
                pages.insert(try await fetch(previousURL, token: token), at: 0)
            }
        }
        let formatter = ISO8601DateFormatter()
        return pages
            .flatMap { (try? JSONDecoder().decode([IssueEvent].self, from: $0.data)) ?? [] }
            .filter { event in
                guard event.event == "review_requested" else { return false }
                if let login = event.requested_reviewer?.login { return login.caseInsensitiveCompare(viewer) == .orderedSame }
                return event.requested_team != nil && !pr.requestedDirectly
            }
            .compactMap { formatter.date(from: $0.created_at) }
            .max()
    }

    /// Creates a review. Without an `event` in the payload, GitHub leaves it pending for the user to submit.
    func submitReview(_ key: PRKey, payload: Data) async throws -> (url: String?, nodeID: String?) {
        let token = try reviewToken(key)
        let (data, response) = try await Self.send("POST", url: Self.url("repos/\(key.slug)/pulls/\(key.number)/reviews"),
                                                   token: token, body: payload)
        try Self.check(response, data)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["html_url"] as? String, object?["node_id"] as? String)
    }

    /// A review as it is now on GitHub, or nil if it was deleted.
    func postedReview(_ key: PRKey, nodeID: String) async throws -> PostedReview? {
        let query = """
            query($id: ID!) { node(id: $id) { ... on PullRequestReview {
              state body url comments(first: 100) { nodes { path line startLine body url } }
            } } }
            """
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": ["id": nodeID]])
        let (data, response) = try await Self.send("POST", url: Self.url("graphql"), token: try reviewToken(key), body: body)
        try Self.check(response, data)
        let result = try JSONDecoder().decode(ReviewQuery.self, from: data)
        if let node = result.data?.node {
            return PostedReview(state: node.state, body: node.body, url: node.url, comments: node.comments.nodes)
        }
        if result.errors?.contains(where: { $0.type == "NOT_FOUND" }) == true { return nil }
        throw GitHubError(message: result.errors?.first?.message ?? "Unexpected response from GitHub.")
    }

    /// The node ID of the review a `#pullrequestreview-` URL points to.
    func reviewNodeID(_ key: PRKey, url: String) async throws -> String? {
        guard let id = url.components(separatedBy: "#pullrequestreview-").last.flatMap({ Int($0) }) else { return nil }
        struct Review: Decodable { let node_id: String }
        let data = try await get("repos/\(key.slug)/pulls/\(key.number)/reviews/\(id)", token: try reviewToken(key))
        return try JSONDecoder().decode(Review.self, from: data).node_id
    }

    private func reviewToken(_ key: PRKey) throws -> String {
        guard let token = credentials.token(for: key.owner) else {
            throw GitHubError(message: "No GitHub token is set up for \(key.owner). Add one in Settings → GitHub.")
        }
        return token
    }

    /// Whether the token works, and a short description of what it can see or why it doesn't work.
    static func describe(token: String) async -> (ok: Bool, text: String) {
        do {
            let (data, response) = try await send("GET", url: url("user"), token: token)
            try check(response, data)
            let login = try JSONDecoder().decode(Login.self, from: data).login
            var text = "Works as @\(login)"
            if let expiry = response.value(forHTTPHeaderField: "github-authentication-token-expiration") {
                text += ", expires \(expiry.prefix(10))"
            }
            // Only classic tokens report scopes.
            if let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes"),
               !scopes.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "repo" }) {
                text += ". Without the repo scope it can't see private repositories"
            }
            let (searchData, searchResponse) = try await send("GET", url: url("search/issues", query: ["q": requestedQuery, "per_page": "1"]), token: token)
            try check(searchResponse, searchData)
            struct Count: Decodable { let total_count: Int }
            let count = try JSONDecoder().decode(Count.self, from: searchData).total_count
            text += ". It can see \(count) open review request\(count == 1 ? "" : "s")."
            return (true, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func viewerLogin(token: String) async throws -> String {
        try JSONDecoder().decode(Login.self, from: try await get("user", token: token)).login
    }

    /// Renders Markdown as GitHub does in comments, with `repo` as the context for issue and commit references.
    func renderMarkdown(_ text: String, repo: String) async throws -> String {
        let owner = String(repo.split(separator: "/").first ?? "")
        guard let token = credentials.token(for: owner) ?? credentials.allTokens.first else {
            throw GitHubError(message: "No GitHub token is set up.")
        }
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "mode": "gfm", "context": repo])
        let (data, response) = try await Self.send("POST", url: Self.url("markdown"), token: token, body: body, accept: "text/html")
        try Self.check(response, data)
        return String(decoding: data, as: UTF8.self)
    }

    private func pull(_ key: PRKey, viewer: String, token: String) async throws -> PullRequest {
        // The "full" media type adds body_html, the description as GitHub renders it.
        let data = try await get("repos/\(key.slug)/pulls/\(key.number)", token: token, accept: "application/vnd.github.full+json")
        return try JSONDecoder().decode(RESTPull.self, from: data).pullRequest(key: key, viewer: viewer)
    }

    // MARK: - HTTP

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static let etags = ETagCache()

    /// GETs with conditional requests; GitHub doesn't count unchanged (304) responses against the rate limit.
    private func get(_ path: String, query: [String: String] = [:], token: String,
                     accept: String = GitHub.defaultAccept) async throws -> Data {
        try await fetch(Self.url(path, query: query), token: token, accept: accept).data
    }

    /// Returns the body and the pagination Link header.
    private func fetch(_ url: URL, token: String, accept: String = GitHub.defaultAccept) async throws -> (data: Data, link: String?) {
        let key = "\(token.hashValue)|\(accept)|\(url.absoluteString)"
        let cached = await Self.etags.entry(key)
        let (data, response) = try await Self.send("GET", url: url, token: token, etag: cached?.etag, accept: accept)
        if response.statusCode == 304, let cached { return (cached.data, cached.link) }
        try Self.check(response, data)
        let link = response.value(forHTTPHeaderField: "Link")
        if let etag = response.value(forHTTPHeaderField: "ETag") {
            await Self.etags.store(key, entry: .init(etag: etag, data: data, link: link))
        }
        return (data, link)
    }

    /// The URL for `rel` ("last", "prev", …) in a Link header.
    private static func page(_ rel: String, in link: String?) -> URL? {
        for part in (link ?? "").split(separator: ",") where part.contains("rel=\"\(rel)\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }

    private static func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: "https://api.github.com/" + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private static let defaultAccept = "application/vnd.github+json"

    private static func send(_ method: String, url: URL, token: String, etag: String? = nil,
                             body: Data? = nil, accept: String = defaultAccept) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ReviewDesk", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError(message: "Unexpected response from GitHub.")
        }
        return (data, http)
    }

    private static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        var detail = object?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        if let errors = object?["errors"] as? [Any], !errors.isEmpty {
            detail += ": " + errors.map { ($0 as? [String: Any])?["message"] as? String ?? "\($0)" }.joined(separator: "; ")
        }
        switch response.statusCode {
        case 401:
            detail += ". The token may be wrong, expired or revoked."
        case 403, 404:
            detail += ". Check that the token's owner and permissions cover this repository."
        default:
            break
        }
        throw GitHubError(message: "GitHub returned \(response.statusCode): \(detail)", unprocessable: response.statusCode == 422)
    }
}

private actor ETagCache {
    struct Entry {
        var etag: String
        var data: Data
        var link: String?
    }

    private var entries: [String: Entry] = [:]

    func entry(_ key: String) -> Entry? { entries[key] }
    func store(_ key: String, entry: Entry) { entries[key] = entry }
}

// MARK: - Response shapes

private struct Login: Decodable { let login: String }

private struct ReviewQuery: Decodable {
    let data: Result?
    let errors: [Failure]?

    struct Result: Decodable { let node: Node? }
    struct Node: Decodable {
        let state: String
        let body: String
        let url: String
        let comments: Comments
    }
    struct Comments: Decodable { let nodes: [PostedReview.Comment] }
    struct Failure: Decodable {
        let type: String?
        let message: String
    }
}

private struct IssueEvent: Decodable {
    let event: String
    let created_at: String
    let requested_reviewer: Login?
    let requested_team: Team?

    struct Team: Decodable { let slug: String }
}

private struct SearchResult: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let number: Int
        let repository_url: String
        let updated_at: String?
        let user: Login?

        var key: PRKey? {
            let parts = repository_url.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            return PRKey(owner: String(parts[parts.count - 2]), repo: String(parts[parts.count - 1]), number: number)
        }
    }
}

private struct RESTPull: Decodable {
    let title: String
    let html_url: String
    let body: String?
    let body_html: String?
    let draft: Bool?
    let state: String?
    let created_at: String?
    let updated_at: String
    let user: Login?
    let head: Ref
    let base: Ref
    let additions: Int?
    let deletions: Int?
    let changed_files: Int?
    let requested_reviewers: [Login]?
    let requested_teams: [Team]?

    struct Ref: Decodable {
        let sha: String
        let ref: String
    }

    struct Team: Decodable { let slug: String }

    func pullRequest(key: PRKey, viewer: String) -> PullRequest {
        PullRequest(
            // GitHub's spelling of the owner and repository, whatever the caller used.
            key: PRKey(html_url).flatMap { $0.number == key.number ? $0 : nil } ?? key,
            title: title,
            author: user?.login ?? "ghost",
            url: html_url,
            isDraft: draft ?? false,
            updatedAt: ISO8601DateFormatter().date(from: updated_at) ?? Date(),
            headSha: head.sha,
            headRef: head.ref,
            baseRef: base.ref,
            baseSha: base.sha,
            additions: additions ?? 0,
            deletions: deletions ?? 0,
            changedFiles: changed_files ?? 0,
            body: body ?? "",
            requestedDirectly: (requested_reviewers ?? []).contains { $0.login.caseInsensitiveCompare(viewer) == .orderedSame },
            requestedTeams: (requested_teams ?? []).map { "\(key.owner)/\($0.slug)" },
            bodyHTML: body_html,
            createdAt: created_at.flatMap { ISO8601DateFormatter().date(from: $0) },
            state: state
        )
    }
}

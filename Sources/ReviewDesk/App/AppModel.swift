import SwiftUI

enum PRSection: Int, CaseIterable, Identifiable {
    case drafts, pending, inProgress, toReview, added, watching, done, ignored

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .drafts: "Drafts to post"
        case .pending: "Pending on GitHub"
        case .inProgress: "Reviewing"
        case .toReview: "Review requested"
        case .added: "Added by you"
        case .watching: "Watching"
        case .done: "Done"
        case .ignored: "Ignored"
        }
    }
}

/// Why an open pull request is listed.
enum PRSource {
    case requested, added, watched
}

/// A pull request in the sidebar: one that's listed, has a review here, or both.
struct PRItem: Identifiable {
    var pr: PullRequest
    var latest: Review?
    /// Nil when it's only here because of a review.
    var source: PRSource?
    var ignored = false
    var unread = false

    var id: String { pr.id }
    var requested: Bool { source == .requested }
    var kind: PRKind { requested ? (pr.requestedDirectly ? .direct : .team) : .other }

    var outdated: Bool { latest.map { $0.pr.headSha != pr.headSha } ?? false }

    /// Requested and watched pull requests can be ignored unless a review of them is running or waiting to be posted or submitted.
    var canIgnore: Bool {
        (source == .requested || source == .watched)
            && (latest.map { !$0.status.isActive && !$0.status.isUnsent } ?? true)
    }

    private var openSection: PRSection? {
        switch source {
        case .requested?: .toReview
        case .added?: .added
        case .watched?: .watching
        case nil: nil
        }
    }

    var section: PRSection {
        if ignored && canIgnore { return .ignored }
        guard let latest else { return openSection ?? .done }
        if latest.status.isActive { return .inProgress }
        if latest.status == .drafted { return .drafts }
        if latest.status == .pending { return .pending }
        if let open = openSection, latest.status == .failed || outdated { return open }
        return .done
    }

    var sortDate: Date { max(pr.updatedAt, latest?.createdAt ?? .distantPast) }
}

/// The last successful check of GitHub, shown at launch until a fresh check finishes.
struct RequestedCache: Codable {
    var viewer = ""
    var checkedAt: Date?
    var prs: [PullRequest] = []
    var watched: [PullRequest] = []
}

/// Which listed pull requests have been seen in the list before, and which are new to me.
struct Inbox: Codable {
    /// "requested|id" or "watched|id".
    var known: [String] = []
    var unread: [String] = []
}

struct RepoEntry: Identifiable, Hashable {
    var slug: String
    var path: String
    var id: String { slug }
}

@MainActor
@Observable
final class AppModel {
    var settings: AppSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    var userPresets: [Preset] {
        didSet { Store.save(userPresets, "presets.json") }
    }
    /// Newest first.
    var reviews: [Review] {
        didSet { scheduleSave() }
    }
    /// Ignored requests, keyed by PR id, with the time of the request that was ignored.
    var ignored: [String: Date] {
        didSet {
            Store.save(ignored, "ignored.json")
            updateBadge()
        }
    }
    var requested: [PullRequest] = []
    var watched: [PullRequest] = []
    /// Pull requests I added myself.
    var added: [PullRequest] {
        didSet { Store.save(added, "added.json") }
    }
    /// Listed pull requests I haven't looked at.
    var unread: Set<String> = [] {
        didSet {
            saveInbox()
            updateBadge()
        }
    }
    var showingAddPR = false
    var viewer = ""
    var lastPoll: Date?
    var pollError: String?
    var isPolling = false
    var selection: String? = UserDefaults.standard.string(forKey: "selection") {
        didSet {
            UserDefaults.standard.set(selection, forKey: "selection")
            if let selection, unread.contains(selection) { unread.remove(selection) }
        }
    }
    var repos: [RepoEntry] = []
    /// Reviews with a discussion reply in progress.
    var discussing: Set<UUID> = []

    let locator = RepoLocator()
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// The draft.json contents last written or read for each review, to tell outside edits from our own.
    @ObservationIgnored private var draftFiles: [UUID: Data] = [:]
    @ObservationIgnored private var credentials: GitHubCredentials?
    @ObservationIgnored private var renderedMarkdown: [String: String] = [:]
    /// Nil until the first check after the inbox was created.
    @ObservationIgnored private var known: Set<String>?
    @ObservationIgnored private var pollAgain = false
    /// Incremented when the GitHub sign-in settings change, so checks begun before then are discarded.
    @ObservationIgnored private var authGeneration = 0
    @ObservationIgnored private var editingAuth = false
    /// When the sign-in settings changed without a check since.
    @ObservationIgnored private var authChangedAt: Date?

    init() {
        settings = AppSettings.load()
        userPresets = Store.load("presets.json", default: [Preset]())
        reviews = Store.load("reviews.json", default: [Review]())
        ignored = Store.load("ignored.json", default: [String: Date]())
        added = Store.load("added.json", default: [PullRequest]())
        let cache = Store.load("requested.json", default: RequestedCache())
        viewer = cache.viewer
        requested = cache.prs
        watched = cache.watched
        lastPoll = cache.checkedAt
        if FileManager.default.fileExists(atPath: Store.url("inbox.json").path) {
            let inbox = Store.load("inbox.json", default: Inbox())
            known = Set(inbox.known)
            unread = Set(inbox.unread)
        }
        recoverAfterLaunch()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        if settings.notify { Notifier.requestAuthorization() }
        applyAppearance()
        DebugHooks.install(model: self)
        startPolling()
        importChangedDraftFiles()
        writeDraftFiles()
        watchDraftFiles()
    }

    // MARK: - Sidebar

    var items: [PRItem] {
        var byID: [String: PRItem] = [:]
        for (prs, source) in [(requested, PRSource.requested), (added, .added), (watched, .watched)] {
            for pr in prs where byID[pr.id] == nil {
                byID[pr.id] = PRItem(pr: pr, source: source, ignored: ignored[pr.id] != nil, unread: unread.contains(pr.id))
            }
        }
        for review in reviews {
            if var item = byID[review.pr.id] {
                if item.latest == nil {
                    item.latest = review
                    byID[review.pr.id] = item
                }
            } else {
                byID[review.pr.id] = PRItem(pr: review.pr, latest: review)
            }
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        return byID.values
            .filter { $0.section != .done || $0.sortDate > cutoff }
            .sorted { $0.sortDate > $1.sortDate }
    }

    func item(_ id: String) -> PRItem? { items.first { $0.id == id } }

    func review(_ id: UUID) -> Review? { reviews.first { $0.id == id } }

    func binding(for id: UUID) -> Binding<Review>? {
        guard let current = review(id) else { return nil }
        return Binding(
            get: { [weak self] in self?.review(id) ?? current },
            set: { [weak self] new in self?.update(id) { $0 = new } }
        )
    }

    // MARK: - Presets

    var allPresets: [Preset] { Presets.builtIn + userPresets }

    func presets(_ kind: PresetKind) -> [Preset] { allPresets.filter { $0.kind == kind } }

    func preset(_ id: String, _ kind: PresetKind) -> Preset {
        allPresets.first { $0.id == id && $0.kind == kind } ?? presets(kind)[0]
    }

    func defaultPresetID(_ kind: PresetKind) -> String {
        let policy = settings.policy(for: "")
        return kind == .scope ? policy[\.scopePresetID] : policy[\.voicePresetID]
    }

    func setDefaultPreset(_ id: String, _ kind: PresetKind) {
        if kind == .scope { settings.reviewDefaults.scopePresetID = id } else { settings.reviewDefaults.voicePresetID = id }
    }

    /// Copies any preset, built-in or not, into a new editable one and returns its ID.
    func duplicatePreset(_ preset: Preset) -> String {
        let copy = Preset(id: "user." + UUID().uuidString, kind: preset.kind, name: "\(preset.name) copy", text: preset.text)
        userPresets.append(copy)
        return copy.id
    }

    func deletePreset(_ id: String) {
        userPresets.removeAll { $0.id == id }
        var updated = settings
        // All repositories fall back to the built-in presets; organizations and repositories inherit instead.
        func clear(_ policy: inout ReviewPolicy, useBuiltIn: Bool) {
            if policy.scopePresetID == id { policy.scopePresetID = useBuiltIn ? Presets.defaultScopeID : nil }
            if policy.voicePresetID == id { policy.voicePresetID = useBuiltIn ? Presets.defaultVoiceID : nil }
        }
        clear(&updated.reviewDefaults, useBuiltIn: true)
        for key in updated.orgs.keys { clear(&updated.orgs[key]!, useBuiltIn: false) }
        for key in updated.repos.keys { clear(&updated.repos[key]!, useBuiltIn: false) }
        settings = updated
    }

    func presetBinding(_ id: String) -> Binding<Preset>? {
        guard let current = userPresets.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.userPresets.first { $0.id == id } ?? current },
            set: { [weak self] new in
                guard let self, let i = self.userPresets.firstIndex(where: { $0.id == id }) else { return }
                self.userPresets[i] = new
            }
        )
    }

    // MARK: - Polling

    /// Checks now, then on the configured interval. With no interval, checks only when asked.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll()
            while !Task.isCancelled {
                guard let minutes = self?.settings.pollMinutes, minutes > 0 else { return }
                try? await Task.sleep(for: .seconds(minutes * 60))
                if Task.isCancelled { return }
                await self?.poll()
            }
        }
    }

    func poll() async {
        if isPolling {
            pollAgain = true
            return
        }
        // While the GitHub settings are being edited, wait for them to settle.
        if editingAuth, let changed = authChangedAt, Date().timeIntervalSince(changed) < 600 { return }
        isPolling = true
        let generation = authGeneration
        let settings = settings
        let known = Dictionary((requested + watched + added).map { ($0.id, $0) }) { first, _ in first }
        do {
            let credentials = try await GitHubCredentials.resolve(settings)
            let github = GitHub(credentials: credentials)
            let listing = try await github.listing(watch: settings.watchedScopes, days: settings.watchDays,
                                                   added: added.map(\.key), known: known)
            if generation == authGeneration {
                self.credentials = credentials
                await apply(listing, github: github)
            } else {
                pollAgain = true
            }
        } catch {
            if generation == authGeneration {
                pollError = error.localizedDescription
            } else {
                pollAgain = true
            }
        }
        isPolling = false
        if pollAgain {
            pollAgain = false
            await poll()
        }
    }

    private func apply(_ listing: GitHub.Listing, github: GitHub) async {
        viewer = listing.viewer
        requested = listing.requested
        let requestedIDs = Set(requested.map(\.id))
        // Settings may have changed during the check.
        watched = listing.watched.filter { !requestedIDs.contains($0.id) && settings.policy(for: $0.key.slug).watched }
        let refreshed = Dictionary((listing.added).map { ($0.id, $0) }) { first, _ in first }
        added = added.compactMap { listing.closed.contains($0.key) ? nil : refreshed[$0.id] ?? $0 }
        lastPoll = Date()
        Store.save(RequestedCache(viewer: viewer, checkedAt: lastPoll, prs: requested, watched: watched), "requested.json")
        let complete = listing.warnings.isEmpty
        if complete {
            // Ignoring stops when a pull request is no longer listed; if it comes back, it's new.
            let current = requestedIDs.union(watched.map(\.id))
            for id in ignored.keys where !current.contains(id) { ignored[id] = nil }
        }
        await showRequestsMadeAgain(github: github, viewer: listing.viewer)
        await syncPendingReviews(github: github)
        handleArrivals(prune: complete)
        pollError = complete ? nil : listing.warnings.joined(separator: "\n")
        autoQueue()
        updateBadge()
    }

    /// Applies each pull request's arrival setting the first time it's listed for a given reason.
    private func handleArrivals(prune: Bool) {
        let listed = requested.map { ("requested|" + $0.id, $0, $0.requestedDirectly ? PRKind.direct : .team) }
            + watched.map { ("watched|" + $0.id, $0, PRKind.other) }
        guard var known else {
            // The first check after updating: what's listed now isn't new.
            self.known = Set(listed.map(\.0))
            let reviewed = Set(reviews.map(\.pr.id))
            unread = Set(requested.map(\.id).filter { !reviewed.contains($0) })
            return
        }
        var unread = unread
        var arrivals: [(PullRequest, PRKind)] = []
        for (key, pr, kind) in listed where !known.contains(key) {
            known.insert(key)
            let policy = settings.policy(for: pr.key.slug)
            // Pull requests opened before watching began aren't news.
            let predatesWatch = kind == .other && policy.watchingSince.map { (pr.createdAt ?? .distantPast) < $0 } ?? true
            switch policy.arrival(kind) {
            case .unread where !predatesWatch:
                unread.insert(pr.id)
                arrivals.append((pr, kind))
            case .unread, .read:
                unread.remove(pr.id)
            case .ignore:
                unread.remove(pr.id)
                if ignored[pr.id] == nil { ignore(pr) }
            }
        }
        if prune {
            known.formIntersection(listed.map(\.0))
            unread.formIntersection(listed.map(\.1.id) + added.map(\.id))
        }
        self.known = known
        self.unread = unread
        guard settings.notify, !arrivals.isEmpty else { return }
        if arrivals.count > 3 {
            Notifier.post(title: "\(arrivals.count) new pull requests", body: arrivals.map(\.0.key.id).joined(separator: ", "))
        } else {
            for (pr, kind) in arrivals {
                Notifier.post(title: kind == .other ? "New pull request" : "Review requested", body: "\(pr.key.id): \(pr.title)")
            }
        }
    }

    func markUnread(_ id: String, _ isUnread: Bool) {
        if isUnread { unread.insert(id) } else { unread.remove(id) }
    }

    private func saveInbox() {
        Store.save(Inbox(known: known.map { $0.sorted() } ?? [], unread: unread.sorted()), "inbox.json")
    }

    /// Stops ignoring requests that have been made again since they were ignored.
    private func showRequestsMadeAgain(github: GitHub, viewer: String) async {
        for pr in requested {
            guard let ignoredRequest = ignored[pr.id],
                  let latest = try? await github.latestReviewRequest(for: pr, viewer: viewer),
                  latest > ignoredRequest else { continue }
            ignored[pr.id] = nil
            if settings.notify {
                Notifier.post(title: "Review requested again", body: "\(pr.key.id): \(pr.title)")
            }
        }
    }

    /// Hides a pull request until my review is requested again.
    func ignore(_ pr: PullRequest) {
        ignored[pr.id] = Date()
        unread.remove(pr.id)
        if selection == pr.id { selection = nil }
        let settings = settings, viewer = viewer
        // Record GitHub's time for the request being ignored, so a later request is recognized
        // regardless of differences between this Mac's clock and GitHub's.
        Task {
            guard let credentials = try? await GitHubCredentials.resolve(settings),
                  let requestedAt = try? await GitHub(credentials: credentials).latestReviewRequest(for: pr, viewer: viewer),
                  ignored[pr.id] != nil else { return }
            ignored[pr.id] = requestedAt
        }
    }

    func stopIgnoring(_ id: String) {
        ignored[id] = nil
    }

    private func autoQueue() {
        let candidates = requested.map { ($0, $0.requestedDirectly ? PRKind.direct : .team) } + watched.map { ($0, PRKind.other) }
        for (pr, kind) in candidates where ignored[pr.id] == nil {
            let policy = settings.policy(for: pr.key.slug)
            guard policy.autoReview(kind) else { continue }
            // Only pull requests opened since watching began, so starting to watch doesn't review everything.
            if kind == .other {
                guard let since = policy.watchingSince, let created = pr.createdAt, created >= since else { continue }
            }
            if policy[\.skipDraftPRs] && pr.isDraft { continue }
            let existing = reviews.filter { $0.pr.key == pr.key }
            if existing.contains(where: { $0.status.isActive || $0.status.isUnsent }) { continue }
            if existing.contains(where: { $0.pr.headSha == pr.headSha }) { continue }
            if !existing.isEmpty && !policy[\.reReviewOnPush] { continue }
            startReview(pr, options: policy.options(automatic: true), automatic: true)
        }
    }

    /// Picks up edits, submission or deletion on GitHub of reviews sent as pending.
    private func syncPendingReviews(github: GitHub) async {
        for review in reviews where review.status == .pending {
            do {
                var nodeID = review.postedReviewID
                if nodeID == nil, let url = review.postedURL {
                    nodeID = try await github.reviewNodeID(review.pr.key, url: url)
                }
                guard let nodeID else { continue }
                let posted = try await github.postedReview(review.pr.key, nodeID: nodeID)
                guard posted == nil || posted != review.onGitHub || review.postedReviewID == nil else { continue }
                update(review.id) {
                    guard $0.status == .pending else { return }
                    $0.postedReviewID = nodeID
                    $0.sync(posted)
                }
            } catch {
                continue
            }
        }
    }

    // MARK: - Added pull requests

    /// Adds a pull request by URL or owner/repo#number and selects it.
    func addPullRequest(_ text: String) async throws {
        guard let key = PRKey(text) else {
            throw GitHubError(message: "Enter a pull request URL or owner/repo#number.")
        }
        func listed(_ key: PRKey) -> PRItem? {
            items.first { $0.source != nil && $0.id.caseInsensitiveCompare(key.id) == .orderedSame }
        }
        if let item = listed(key) {
            selection = item.id
            return
        }
        let credentials = try await GitHubCredentials.resolve(settings)
        let (_, pr) = try await GitHub(credentials: credentials).pullRequest(key)
        guard pr.isOpen else { throw GitHubError(message: "\(pr.key.id) is closed.") }
        if let item = listed(pr.key) {
            selection = item.id
            return
        }
        if !added.contains(where: { $0.key == key }) { added.append(pr) }
        selection = pr.id
    }

    func removeAdded(_ id: String) {
        added.removeAll { $0.id == id }
    }

    // MARK: - Organizations and repositories

    /// Adds settings for an owner or owner/repo, and for a repository's owner too.
    func addScope(_ scope: String) {
        if scope.contains("/") {
            let owner = AppSettings.owner(of: scope)
            if settings.orgKey(owner) == nil { settings.orgs[owner] = ReviewPolicy() }
            if settings.repoKey(scope) == nil { settings.repos[scope] = ReviewPolicy() }
        } else if settings.orgKey(scope) == nil {
            settings.orgs[scope] = ReviewPolicy()
        }
    }

    /// Removes an owner's or repository's settings. Removing an owner removes its repositories' too.
    func removeScope(_ scope: String) {
        var updated = settings
        if scope.contains("/") {
            if let key = updated.repoKey(scope) { updated.repos[key] = nil }
        } else {
            if let key = updated.orgKey(scope) { updated.orgs[key] = nil }
            for key in updated.repos.keys where AppSettings.owner(of: key).caseInsensitiveCompare(scope) == .orderedSame {
                updated.repos[key] = nil
            }
        }
        settings = updated
    }

    /// The owner or owner/repo as GitHub names it, checking that it exists and the token can see it.
    func lookUpScope(_ scope: String) async throws -> String {
        if credentials == nil { credentials = try await GitHubCredentials.resolve(settings) }
        return try await GitHub(credentials: credentials!).canonicalName(scope)
    }

    /// Owners and repositories seen in pull requests and local clones, without settings of their own yet.
    var scopeSuggestions: [String] {
        let slugs = Set((requested + watched + added + reviews.map(\.pr)).map(\.key.slug) + repos.map(\.slug))
        let owners = Set(slugs.map { AppSettings.owner(of: $0) })
        return (owners.filter { settings.orgKey($0) == nil }.sorted { $0.lowercased() < $1.lowercased() }
                + slugs.filter { settings.repoKey($0) == nil }.sorted { $0.lowercased() < $1.lowercased() })
    }

    // MARK: - GitHub sign-in

    /// Call when a token in the keychain changes. Settings changes call it themselves.
    func githubAuthChanged() {
        authGeneration += 1
        credentials = nil
        pollError = nil
        authChangedAt = Date()
        if !editingAuth { refreshAfterAuthChange() }
    }

    /// Checks GitHub are held while the sign-in settings are being edited, then run once editing ends.
    func setEditingAuth(_ editing: Bool) {
        editingAuth = editing
        if !editing { refreshAfterAuthChange() }
    }

    func authTestSucceeded() {
        refreshAfterAuthChange()
    }

    private func refreshAfterAuthChange() {
        guard authChangedAt != nil else { return }
        authChangedAt = nil
        Task { await poll() }
    }

    // MARK: - Reviews

    /// The settings a review of the pull request starts with.
    func reviewOptions(for pr: PullRequest, automatic: Bool = false) -> ReviewOptions {
        settings.policy(for: pr.key.slug).options(automatic: automatic)
    }

    func startReview(_ pr: PullRequest, options: ReviewOptions, extra: String = "", automatic: Bool = false) {
        for review in reviews where review.pr.key == pr.key && review.status == .drafted {
            dismiss(review.id)
        }
        reviews.insert(Review(pr: pr, options: options, extra: extra, automatic: automatic), at: 0)
        pump()
    }

    func cancel(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel()
        } else {
            update(id) { if $0.status == .queued { $0.status = .failed; $0.error = "Cancelled." } }
        }
    }

    func dismiss(_ id: UUID) {
        update(id) { $0.status = .dismissed }
        cleanupWorkspace(id)
    }

    /// Posts the draft. A nil event creates a pending review on GitHub instead.
    func post(_ id: UUID, event: ReviewEvent?, notify: Bool = false) {
        guard let review = review(id), review.status == .drafted else { return }
        update(id) { $0.status = .posting; $0.error = nil }
        let footer = settings.policy(for: review.pr.key.slug)[\.footer]
        let settings = settings
        Task {
            do {
                let credentials = try await GitHubCredentials.resolve(settings)
                let outcome = try await Poster.post(review, event: event, footer: footer, github: GitHub(credentials: credentials))
                update(id) {
                    $0.status = event == nil ? .pending : .posted
                    $0.postedURL = outcome.url
                    $0.postedReviewID = outcome.reviewID
                    $0.postedBody = outcome.body
                    $0.postedEvent = event
                    $0.postedNote = outcome.note
                }
                cleanupWorkspace(id)
                if notify && settings.notify {
                    let how = event.map { "Posted (\($0.label.lowercased()))" } ?? "Sent as a pending review"
                    Notifier.post(title: how, body: "\(review.pr.key.id): \(review.pr.title)")
                }
                await poll()
            } catch {
                update(id) { $0.status = .drafted; $0.error = "Couldn't post: \(error.localizedDescription)" }
                if notify && settings.notify {
                    Notifier.post(title: "Couldn't post a review", body: "\(review.pr.key.id): \(error.localizedDescription)")
                }
            }
        }
    }

    private func pump() {
        var free = settings.maxConcurrent - reviews.filter { $0.status == .preparing || $0.status == .running }.count
        for review in reviews.reversed() where review.status == .queued && free > 0 {
            free -= 1
            let id = review.id
            update(id) { $0.status = .preparing; $0.startedAt = Date() }
            tasks[id] = Task { await self.execute(id) }
        }
    }

    private func execute(_ id: UUID) async {
        guard let review = review(id) else { return }
        let limits = limits(for: review)
        let options = Pipeline.Options(settings: settings, model: review.model, effort: review.effort,
                                       budgetUSD: limits.budget, timeoutMinutes: limits.minutes,
                                       scope: preset(review.scopePresetID, .scope).text,
                                       voice: preset(review.voicePresetID, .voice).text,
                                       extra: review.extraInstructions)
        do {
            let result = try await Pipeline.run(
                key: review.pr.key, options: options, locator: locator,
                onStage: { [weak self] stage in
                    Task { @MainActor in self?.update(id) { if $0.status.isActive { $0.status = stage } } }
                },
                log: { [weak self] entry in
                    Task { @MainActor in self?.appendLog(entry, to: id) }
                })
            update(id) {
                $0.apply(result)
                $0.status = .drafted
                $0.finishedAt = Date()
            }
            switch review.completion ?? .keep {
            case .keep:
                if settings.notify {
                    Notifier.post(title: "Review ready", body: "\(result.pr.key.id): \(result.pr.title)")
                }
            case .pending:
                post(id, event: nil, notify: true)
            case .submit:
                let rules = review.verdict ?? settings.policy(for: review.pr.key.slug).verdict
                post(id, event: rules.event(comments: result.output.comments, recommended: result.output.event), notify: true)
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            update(id) {
                $0.status = .failed
                $0.finishedAt = Date()
                $0.error = cancelled ? "Cancelled." : error.localizedDescription
            }
        }
        tasks[id] = nil
        pump()
    }

    /// The review's cost and time limits; zero means none.
    private func limits(for review: Review) -> (budget: Double, minutes: Double) {
        let policy = settings.policy(for: review.pr.key.slug)
        return ((review.budget ?? policy[\.budget]).effective, (review.timeLimit ?? policy[\.timeLimit]).effective)
    }

    // MARK: - Markdown

    /// HTML for Markdown as GitHub would render it in a comment on `repo`.
    func renderMarkdown(_ text: String, repo: String) async throws -> String {
        let key = repo + "\n" + text
        if let html = renderedMarkdown[key] { return html }
        if credentials == nil { credentials = try await GitHubCredentials.resolve(settings) }
        let html = try await GitHub(credentials: credentials!).renderMarkdown(text, repo: repo)
        if renderedMarkdown.count > 300 { renderedMarkdown.removeAll() }
        renderedMarkdown[key] = html
        return html
    }

    // MARK: - Discussion

    /// Sends a message about a draft to the review's Claude session. Claude may revise the draft in reply.
    func discuss(_ id: UUID, message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !discussing.contains(id), let review = review(id), review.status == .drafted,
              let workspace = review.workspace, let session = review.sessionID else { return }
        guard let claude = Tools.locate("claude", override: settings.claudePath) else {
            update(id) { $0.conversation.append(ChatMessage(role: .error, text: "Couldn't find the claude CLI.")) }
            return
        }
        let limits = limits(for: review)
        let options = ClaudeOptions(path: claude, model: review.model, effort: review.effort,
                                    maxBudgetUSD: limits.budget, timeoutMinutes: limits.minutes)
        let draft = DraftFile(review: review)
        update(id) { $0.conversation.append(ChatMessage(role: .user, text: message)) }
        discussing.insert(id)
        Task {
            defer { discussing.remove(id) }
            do {
                let reply = try await Discussion.send(
                    message: message, draft: draft, session: session, workspace: workspace, claude: options,
                    log: { [weak self] entry in Task { @MainActor in self?.appendLog(entry, to: id) } })
                let index = DiffIndex(path: workspace.rawDiffPath)
                update(id) { review in
                    review.sessionID = reply.sessionID ?? review.sessionID
                    if let cost = reply.costUSD { review.costUSD = (review.costUSD ?? 0) + cost }
                    review.conversation.append(ChatMessage(role: .assistant, text: reply.text))
                    guard let revised = reply.revised, review.status == .drafted else { return }
                    let before = DraftFile(review: review)
                    revised.apply(to: &review, index: index)
                    if let changes = DraftFile(review: review).changes(from: before) {
                        review.previousDraft = before
                        review.conversation.append(ChatMessage(role: .note, text: "Claude \(changes)."))
                    }
                }
            } catch {
                update(id) { $0.conversation.append(ChatMessage(role: .error, text: error.localizedDescription)) }
            }
        }
    }

    func undoDraftChange(_ id: UUID) {
        guard let review = review(id), let previous = review.previousDraft, let workspace = review.workspace else { return }
        let index = DiffIndex(path: workspace.rawDiffPath)
        update(id) {
            previous.apply(to: &$0, index: index)
            $0.previousDraft = nil
            $0.conversation.append(ChatMessage(role: .note, text: "Undid the last change to the draft."))
        }
    }

    func terminalCommand(for id: UUID) -> String? {
        guard let review = review(id), let workspace = review.workspace, let session = review.sessionID else { return nil }
        writeDraftFiles()
        return Discussion.terminalCommand(workspace: workspace, session: session)
    }

    /// Picks up edits made to a draft's draft.json outside the app, for example by Claude in a terminal.
    private func watchDraftFiles() {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.importChangedDraftFiles()
            }
        }
    }

    private func importChangedDraftFiles() {
        for review in reviews where review.status == .drafted {
            guard let workspace = review.workspace,
                  let data = FileManager.default.contents(atPath: workspace.draftPath),
                  data != draftFiles[review.id],
                  let file = try? JSONDecoder().decode(DraftFile.self, from: data) else { continue }
            draftFiles[review.id] = data
            let current = DraftFile(review: review)
            guard let changes = file.changes(from: current) else { continue }
            let index = DiffIndex(path: workspace.rawDiffPath)
            update(review.id) {
                $0.previousDraft = current
                file.apply(to: &$0, index: index)
                $0.conversation.append(ChatMessage(role: .note, text: "draft.json was edited: \(changes)."))
            }
        }
    }

    private func writeDraftFiles() {
        for review in reviews where review.status == .drafted {
            guard let workspace = review.workspace else { continue }
            let data = DraftFile(review: review).encoded
            guard data != draftFiles[review.id] else { continue }
            if (try? data.write(to: URL(fileURLWithPath: workspace.draftPath), options: .atomic)) != nil {
                draftFiles[review.id] = data
            }
        }
    }

    func update(_ id: UUID, _ change: (inout Review) -> Void) {
        guard let i = reviews.firstIndex(where: { $0.id == id }) else { return }
        change(&reviews[i])
    }

    private func appendLog(_ entry: LogEntry, to id: UUID) {
        update(id) {
            $0.log.append(entry)
            if $0.log.count > 500 { $0.log.removeFirst($0.log.count - 500) }
        }
    }

    private func cleanupWorkspace(_ id: UUID) {
        guard let workspace = review(id)?.workspace else { return }
        update(id) { $0.workspace = nil }
        Task.detached { await WorkspaceBuilder.remove(workspace) }
    }

    private func recoverAfterLaunch() {
        var keep = Set<String>()
        for i in reviews.indices {
            switch reviews[i].status {
            case .queued, .preparing, .running:
                reviews[i].status = .failed
                reviews[i].error = "Interrupted because Review Desk quit."
            case .posting:
                reviews[i].status = .drafted
                reviews[i].error = "Posting was interrupted. Check GitHub before posting again."
            case .posted where reviews[i].postedEvent == nil && reviews[i].onGitHub == nil:
                // Sent as pending by a version without the pending status.
                reviews[i].status = .pending
            default:
                break
            }
            if reviews[i].status == .drafted, let workspace = reviews[i].workspace {
                keep.insert(workspace.runDir)
            } else {
                reviews[i].workspace = nil
            }
        }
        Task.detached { await WorkspaceBuilder.cleanOrphans(keeping: keep) }
    }

    // MARK: - Repositories

    func rescanRepos() async {
        let found = await locator.scan(roots: settings.repoRoots + [settings.cloneDir])
        repos = found.map { RepoEntry(slug: $0.key, path: $0.value) }.sorted { $0.slug < $1.slug }
    }

    // MARK: - Persistence

    private func settingsChanged(from old: AppSettings) {
        Store.save(settings, "settings.json")
        if settings.appearance != old.appearance { applyAppearance() }
        if settings.pollMinutes != old.pollMinutes { startPolling() }
        if settings.githubAuth != old.githubAuth || settings.githubTokens != old.githubTokens || settings.ghPath != old.ghPath {
            githubAuthChanged()
        } else if settings.watchedScopes != old.watchedScopes || settings.watchDays != old.watchDays
                    || watched.contains(where: { !settings.policy(for: $0.key.slug).watched }) {
            Task { await poll() }
        }
        if settings.notify && !old.notify { Notifier.requestAuthorization() }
        if settings.reviewDefaults != old.reviewDefaults || settings.orgs != old.orgs || settings.repos != old.repos {
            autoQueue()
        }
        if settings.maxConcurrent != old.maxConcurrent { pump() }
    }

    private func scheduleSave() {
        updateBadge()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        Store.save(reviews, "reviews.json")
        writeDraftFiles()
    }

    private func applyAppearance() {
        NSApplication.shared.appearance = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func updateBadge() {
        let count = items.filter { $0.section == .drafts || $0.section == .pending || ($0.unread && $0.section != .ignored) }.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

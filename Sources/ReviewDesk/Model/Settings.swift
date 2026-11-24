import Foundation

/// How a pull request relates to me, for settings that treat them differently.
enum PRKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct, team, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .direct: "Requested from me"
        case .team: "Requested from my team"
        case .other: "Other pull requests"
        }
    }

    var autoReviewKey: WritableKeyPath<ReviewPolicy, Bool?> {
        switch self {
        case .direct: \.autoReviewDirect
        case .team: \.autoReviewTeam
        case .other: \.autoReviewOther
        }
    }

    var arrivalKey: WritableKeyPath<ReviewPolicy, Arrival?> {
        switch self {
        case .direct: \.arrivalDirect
        case .team: \.arrivalTeam
        case .other: \.arrivalOther
        }
    }
}

/// What to do with a pull request when it first appears.
enum Arrival: String, Codable, CaseIterable, Identifiable, Sendable {
    case unread, read, ignore

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: "Show as new"
        case .read: "Show as read"
        case .ignore: "Ignore"
        }
    }
}

/// What to do with a review when it finishes.
enum Completion: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, pending, submit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keep: "Keep it here to edit and post"
        case .pending: "Send it to GitHub as a pending review"
        case .submit: "Submit it on GitHub"
        }
    }
}

enum AutoCompletion: String, Codable, CaseIterable, Identifiable, Sendable {
    case same, keep, pending, submit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .same: "Same as reviews I start"
        case .keep: Completion.keep.label
        case .pending: Completion.pending.label
        case .submit: Completion.submit.label
        }
    }

    func resolve(manual: Completion) -> Completion {
        switch self {
        case .same: manual
        case .keep: .keep
        case .pending: .pending
        case .submit: .submit
        }
    }
}

enum RequestChangesRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, claude, blocking, important

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .claude: "When Claude recommends it"
        case .blocking: "When there are blocking findings"
        case .important: "When there are important or blocking findings"
        }
    }
}

enum ApproveRule: String, Codable, CaseIterable, Identifiable, Sendable {
    case never, claude, clean, nits, minor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .claude: "When Claude recommends it"
        case .clean: "When there are no findings"
        case .nits: "When there are only nits"
        case .minor: "When there are only suggestions and nits"
        }
    }
}

/// Chooses whether a submitted review approves, requests changes or just comments.
struct VerdictRules: Codable, Equatable, Sendable {
    var requestChanges: RequestChangesRule
    var approve: ApproveRule

    func event(comments: [DraftComment], recommended: ReviewEvent) -> ReviewEvent {
        let severities = comments.filter(\.include).map(\.severity)
        let requestsChanges = switch requestChanges {
        case .never: false
        case .claude: recommended == .requestChanges
        case .blocking: severities.contains(.blocking)
        case .important: severities.contains { $0 == .blocking || $0 == .important }
        }
        if requestsChanges { return .requestChanges }
        let approves = switch approve {
        case .never: false
        case .claude: recommended == .approve
        case .clean: severities.isEmpty
        case .nits: severities.allSatisfy { $0 == .nit }
        case .minor: severities.allSatisfy { $0 == .nit || $0 == .suggestion }
        }
        return approves ? .approve : .comment
    }
}

struct Limit: Codable, Equatable, Sendable {
    var on: Bool
    var value: Double

    /// Zero when there's no limit.
    var effective: Double { on ? max(0, value) : 0 }
}

/// Review settings for all repositories, an organization or a repository. A nil value is inherited from
/// the less specific level.
struct ReviewPolicy: Codable, Equatable, Sendable {
    /// List every open pull request, not only those requesting my review. Organizations and repositories only.
    var watch: Bool?
    var watchingSince: Date?

    var autoReviewDirect: Bool?
    var autoReviewTeam: Bool?
    var autoReviewOther: Bool?
    var arrivalDirect: Arrival?
    var arrivalTeam: Arrival?
    var arrivalOther: Arrival?
    var skipDraftPRs: Bool?
    var reReviewOnPush: Bool?

    var model: String?
    var effort: String?
    var budget: Limit?
    var timeLimit: Limit?

    var scopePresetID: String?
    var voicePresetID: String?
    /// Added to the instructions from less specific levels rather than replacing them.
    var instructions: String?

    var afterManual: Completion?
    var afterAuto: AutoCompletion?
    var requestChanges: RequestChangesRule?
    var approve: ApproveRule?
    var footer: String?

    static let builtIn = ReviewPolicy(
        autoReviewDirect: false, autoReviewTeam: false, autoReviewOther: false,
        arrivalDirect: .unread, arrivalTeam: .unread, arrivalOther: .unread,
        skipDraftPRs: true, reReviewOnPush: false,
        model: "opus", effort: "high",
        budget: Limit(on: true, value: 5), timeLimit: Limit(on: true, value: 30),
        scopePresetID: Presets.defaultScopeID, voicePresetID: Presets.defaultVoiceID, instructions: "",
        afterManual: .keep, afterAuto: .same, requestChanges: .blocking, approve: .nits, footer: "")
}

/// The settings that apply somewhere, combined from each level.
struct EffectivePolicy: Sendable {
    /// Least specific first. The first is `ReviewPolicy.builtIn`.
    let layers: [ReviewPolicy]

    subscript<T>(_ key: KeyPath<ReviewPolicy, T?>) -> T {
        for layer in layers.reversed() {
            if let value = layer[keyPath: key] { return value }
        }
        preconditionFailure("ReviewPolicy.builtIn has no value for \(key)")
    }

    var watched: Bool { layers.last { $0.watch != nil }?.watch ?? false }
    var watchingSince: Date? { layers.last { $0.watch != nil }?.watchingSince }

    var instructions: String {
        layers.compactMap { $0.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func autoReview(_ kind: PRKind) -> Bool { self[kind.autoReviewKey] }
    func arrival(_ kind: PRKind) -> Arrival { self[kind.arrivalKey] }

    func completion(automatic: Bool) -> Completion {
        automatic ? self[\.afterAuto].resolve(manual: self[\.afterManual]) : self[\.afterManual]
    }

    var verdict: VerdictRules { VerdictRules(requestChanges: self[\.requestChanges], approve: self[\.approve]) }

    func options(automatic: Bool) -> ReviewOptions {
        ReviewOptions(model: self[\.model], effort: self[\.effort], budget: self[\.budget], timeLimit: self[\.timeLimit],
                      scopePresetID: self[\.scopePresetID], voicePresetID: self[\.voicePresetID],
                      instructions: instructions, completion: completion(automatic: automatic), verdict: verdict)
    }
}

/// The settings for one review.
struct ReviewOptions: Equatable, Sendable {
    var model: String
    var effort: String
    var budget: Limit
    var timeLimit: Limit
    var scopePresetID: String
    var voicePresetID: String
    var instructions: String
    var completion: Completion
    var verdict: VerdictRules
}

enum GitHubAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tokens, ghCLI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tokens: "Personal access tokens (recommended)"
        case .ghCLI: "My GitHub CLI (gh) login"
        }
    }
}

/// A personal access token's settings. The token itself is kept in the keychain under `id`.
struct TokenEntry: Codable, Hashable, Identifiable, Sendable {
    var id = UUID().uuidString
    /// The user or organization whose repositories the token is for. Empty means any owner.
    var owner = ""
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct AppSettings: Codable, Equatable, Sendable {
    /// Zero means only when asked.
    var pollMinutes: Double = 5
    /// Watched pull requests not updated in this many days aren't listed. Zero lists them all.
    var watchDays = 30
    var maxConcurrent = 2
    var notify = true
    var appearance: AppearanceMode = .system

    var githubAuth: GitHubAuthMode = .tokens
    var githubTokens: [TokenEntry] = []

    var repoRoots: [String] = AppSettings.defaultRepoRoots
    var cloneDir = "~/Library/Application Support/ReviewDesk/clones"
    var claudePath = ""
    var ghPath = ""

    /// Review settings for all repositories.
    var reviewDefaults = ReviewPolicy.builtIn
    /// Overrides keyed by owner login.
    var orgs: [String: ReviewPolicy] = [:]
    /// Overrides keyed by owner/repo.
    var repos: [String: ReviewPolicy] = [:]

    static let pollChoices: [Double] = [0, 1, 2, 5, 10, 15, 30, 60]
    static let watchDayChoices = [7, 14, 30, 90, 0]

    static func pollLabel(_ minutes: Double) -> String {
        switch minutes {
        case ...0: "Manually"
        case 1: "Every minute"
        case 60: "Every hour"
        default: "Every \(Int(minutes)) minutes"
        }
    }

    static var defaultRepoRoots: [String] {
        let candidates = ["~/repos", "~/src", "~/code", "~/Developer", "~/Projects", "~/git", "~/workspace"]
        let existing = candidates.filter { FileManager.default.fileExists(atPath: Tools.expand($0)) }
        return existing.isEmpty ? ["~"] : existing
    }

    /// Loads the saved settings, converting those saved before review settings could vary by organization.
    static func load() -> AppSettings {
        var settings = Store.load("settings.json", default: AppSettings())
        if let data = try? Data(contentsOf: Store.url("settings.json")),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw["reviewDefaults"] == nil,
           let legacy = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            settings.reviewDefaults = legacy.policy
        }
        settings.recordWatchStarts()
        return settings
    }
}

// MARK: - Organizations and repositories

/// Settings scopes are identified by "" for all repositories, an owner login, or owner/repo.
extension AppSettings {
    func orgKey(_ owner: String) -> String? {
        orgs.keys.first { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    func repoKey(_ slug: String) -> String? {
        repos.keys.first { $0.caseInsensitiveCompare(slug) == .orderedSame }
    }

    static func owner(of scope: String) -> String {
        String(scope.split(separator: "/").first ?? "")
    }

    /// The settings in force for a scope.
    func policy(for scope: String) -> EffectivePolicy {
        var layers = [ReviewPolicy.builtIn, reviewDefaults]
        guard !scope.isEmpty else { return EffectivePolicy(layers: layers) }
        if let key = orgKey(Self.owner(of: scope)) { layers.append(orgs[key]!) }
        if scope.contains("/"), let key = repoKey(scope) { layers.append(repos[key]!) }
        return EffectivePolicy(layers: layers)
    }

    /// The settings a scope inherits from the less specific levels.
    func inherited(by scope: String) -> EffectivePolicy {
        if scope.isEmpty { return EffectivePolicy(layers: [.builtIn]) }
        return policy(for: scope.contains("/") ? Self.owner(of: scope) : "")
    }

    /// The scope's own settings.
    func ownPolicy(_ scope: String) -> ReviewPolicy {
        if scope.isEmpty { return reviewDefaults }
        if scope.contains("/") { return repoKey(scope).flatMap { repos[$0] } ?? ReviewPolicy() }
        return orgKey(scope).flatMap { orgs[$0] } ?? ReviewPolicy()
    }

    mutating func setOwnPolicy(_ policy: ReviewPolicy, for scope: String) {
        if scope.isEmpty {
            reviewDefaults = policy
        } else if scope.contains("/") {
            repos[repoKey(scope) ?? scope] = policy
        } else {
            orgs[orgKey(scope) ?? scope] = policy
        }
        recordWatchStarts()
    }

    /// Owners and repositories whose open pull requests are all listed.
    var watchedScopes: [String] {
        let owners = orgs.filter { $0.value.watch == true }.map(\.key)
        let repos = repos.keys.filter { slug in
            policy(for: slug).watched && !owners.contains { $0.caseInsensitiveCompare(Self.owner(of: slug)) == .orderedSame }
        }
        return owners.sorted() + repos.sorted()
    }

    /// Notes when watching started, so only pull requests opened since then are reviewed automatically.
    mutating func recordWatchStarts() {
        func update(_ policy: inout ReviewPolicy) {
            if policy.watch == true, policy.watchingSince == nil { policy.watchingSince = Date() }
            if policy.watch != true, policy.watchingSince != nil { policy.watchingSince = nil }
        }
        for key in orgs.keys { update(&orgs[key]!) }
        for key in repos.keys { update(&repos[key]!) }
    }
}

/// Settings as saved before they could vary by organization and repository.
private struct LegacySettings: Decodable {
    var autoReview: String?
    var skipDraftPRs: Bool?
    var reReviewOnPush: Bool?
    var afterReview: String?
    var model: String?
    var effort: String?
    var maxBudgetUSD: Double?
    var timeoutMinutes: Double?
    var scopePresetID: String?
    var voicePresetID: String?
    var extraInstructions: String?
    var footer: String?

    var policy: ReviewPolicy {
        var policy = ReviewPolicy.builtIn
        if let autoReview {
            policy.autoReviewDirect = autoReview != "off"
            policy.autoReviewTeam = autoReview == "all"
        }
        policy.skipDraftPRs = skipDraftPRs ?? policy.skipDraftPRs
        policy.reReviewOnPush = reReviewOnPush ?? policy.reReviewOnPush
        switch afterReview {
        case "pending": policy.afterAuto = .pending
        case "post":
            policy.afterAuto = .submit
            policy.requestChanges = .never
            policy.approve = .never
        default: break
        }
        policy.model = model ?? policy.model
        policy.effort = effort ?? policy.effort
        if let maxBudgetUSD { policy.budget = Limit(on: maxBudgetUSD > 0, value: maxBudgetUSD > 0 ? maxBudgetUSD : 5) }
        if let timeoutMinutes { policy.timeLimit = Limit(on: timeoutMinutes > 0, value: timeoutMinutes > 0 ? timeoutMinutes : 30) }
        policy.scopePresetID = scopePresetID ?? policy.scopePresetID
        policy.voicePresetID = voicePresetID ?? policy.voicePresetID
        policy.instructions = extraInstructions ?? policy.instructions
        policy.footer = footer ?? policy.footer
        return policy
    }
}

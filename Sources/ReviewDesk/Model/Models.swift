import Foundation

struct PRKey: Hashable, Codable, Sendable {
    var owner: String
    var repo: String
    var number: Int

    var slug: String { "\(owner)/\(repo)" }
    var id: String { "\(owner)/\(repo)#\(number)" }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")! }

    init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    /// Accepts `owner/repo#123` or a github.com pull request URL.
    init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        let parts = s.split(whereSeparator: { $0 == "/" || $0 == "#" }).map(String.init)
        guard parts.count >= 3 else { return nil }
        let numberPart = parts[2] == "pull" && parts.count >= 4 ? parts[3] : parts[2]
        guard let number = Int(numberPart) else { return nil }
        self.init(owner: parts[0], repo: parts[1], number: number)
    }
}

struct PullRequest: Codable, Hashable, Sendable, Identifiable {
    var key: PRKey
    var title: String
    var author: String
    var url: String
    var isDraft: Bool
    var updatedAt: Date
    var headSha: String
    var headRef: String
    var baseRef: String
    var baseSha: String
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var body: String
    /// Whether the viewer was requested by name, rather than only through a team.
    var requestedDirectly: Bool
    var requestedTeams: [String]
    /// The description as GitHub renders it.
    var bodyHTML: String? = nil
    var createdAt: Date? = nil
    /// "open" or "closed".
    var state: String? = nil

    var id: String { key.id }
    var isOpen: Bool { state != "closed" }
}

enum ReviewStatus: String, Codable, Sendable {
    case queued, preparing, running, drafted, posting, posted, failed, dismissed

    var isActive: Bool { [.queued, .preparing, .running, .posting].contains(self) }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .running: "Reviewing"
        case .drafted: "Draft ready"
        case .posting: "Posting"
        case .posted: "Posted"
        case .failed: "Failed"
        case .dismissed: "Discarded"
        }
    }
}

enum Severity: String, Codable, CaseIterable, Sendable {
    case blocking, important, question, suggestion, nit

    var rank: Int { Severity.allCases.firstIndex(of: self) ?? 0 }
    var label: String { rawValue.capitalized }
}

enum ReviewEvent: String, Codable, CaseIterable, Identifiable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    init(agentValue: String) {
        switch agentValue {
        case "approve": self = .approve
        case "request_changes": self = .requestChanges
        default: self = .comment
        }
    }

    var agentValue: String {
        switch self {
        case .comment: "comment"
        case .approve: "approve"
        case .requestChanges: "request_changes"
        }
    }
}

struct DraftComment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String
    var line: Int
    var startLine: Int?
    var severity: Severity
    var body: String
    var include = true
    /// False when the line isn't part of the diff; such comments are posted in the review body.
    var inDiff = true

    var location: String {
        if let startLine { return "\(path):\(startLine)-\(line)" }
        return "\(path):\(line)"
    }

    func blobURL(_ pr: PullRequest) -> URL {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let anchor = startLine.map { "#L\($0)-L\(line)" } ?? "#L\(line)"
        return URL(string: "https://github.com/\(pr.key.slug)/blob/\(pr.headSha)/\(encodedPath)\(anchor)")
            ?? pr.key.webURL
    }
}

struct LogEntry: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case info, tool, text, error }

    var id = UUID()
    var at = Date()
    var kind: Kind
    var text: String

    static func info(_ text: String) -> LogEntry { LogEntry(kind: .info, text: text) }
    static func tool(_ text: String) -> LogEntry { LogEntry(kind: .tool, text: text) }
    static func text(_ text: String) -> LogEntry { LogEntry(kind: .text, text: text) }
    static func error(_ text: String) -> LogEntry { LogEntry(kind: .error, text: text) }
}

/// A temporary checkout of a pull request, plus the context files given to the agent.
struct Workspace: Codable, Hashable, Sendable {
    var repoPath: String
    var runDir: String
    var mergeBase = ""

    var worktree: String { runDir + "/src" }
    var contextDir: String { runDir + "/context" }
    /// The unannotated diff, kept outside the directory the agent can read.
    var rawDiffPath: String { runDir + "/raw.diff" }
    /// The draft as JSON. Edits made to it outside the app are picked up.
    var draftPath: String { runDir + "/draft.json" }
}

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, note, error }

    var id = UUID()
    var at = Date()
    var role: Role
    var text: String
}

/// Decodes a missing key as an empty collection, so files saved by older versions still load.
@propertyWrapper
struct DefaultEmpty<T: Codable & RangeReplaceableCollection>: Codable {
    var wrappedValue: T

    init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try T(from: decoder) }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

extension DefaultEmpty: Sendable where T: Sendable {}

extension KeyedDecodingContainer {
    func decode<T>(_ type: DefaultEmpty<T>.Type, forKey key: Key) throws -> DefaultEmpty<T> {
        try decodeIfPresent(type, forKey: key) ?? DefaultEmpty(wrappedValue: T())
    }
}

struct Review: Codable, Identifiable, Sendable {
    var id = UUID()
    var pr: PullRequest
    var status: ReviewStatus = .queued
    var createdAt = Date()
    var startedAt: Date?
    var finishedAt: Date?
    var automatic = false
    var scopePresetID: String
    var voicePresetID: String
    var extraInstructions = ""
    var model: String
    var effort: String
    var summary = ""
    var event: ReviewEvent = .comment
    var comments: [DraftComment] = []
    var costUSD: Double?
    var sessionID: String?
    var workspace: Workspace?
    var log: [LogEntry] = []
    var error: String?
    var postedURL: String?
    var postedEvent: ReviewEvent?
    var postedNote: String?
    @DefaultEmpty var conversation: [ChatMessage] = []
    /// The draft before the last change Claude or draft.json made, for undo.
    var previousDraft: DraftFile?
    var budget: Limit?
    var timeLimit: Limit?
    var completion: Completion?
    var verdict: VerdictRules?

    init(pr: PullRequest, options: ReviewOptions, extra: String = "", automatic: Bool = false) {
        self.pr = pr
        self.automatic = automatic
        scopePresetID = options.scopePresetID
        voicePresetID = options.voicePresetID
        extraInstructions = [options.instructions, extra]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        model = options.model
        effort = options.effort
        budget = options.budget
        timeLimit = options.timeLimit
        completion = options.completion
        verdict = options.verdict
    }

    mutating func apply(_ result: PipelineResult) {
        pr = result.pr
        workspace = result.workspace
        summary = result.output.summary
        event = result.output.event
        comments = result.output.comments
        costUSD = result.output.costUSD
        sessionID = result.output.sessionID
    }
}

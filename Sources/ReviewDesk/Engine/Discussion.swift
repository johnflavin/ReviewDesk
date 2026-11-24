import Foundation

/// The editable parts of a draft, as shown to Claude and written to draft.json.
struct DraftFile: Codable, Equatable, Sendable {
    struct Comment: Codable, Equatable, Sendable {
        var id: String?
        var path: String
        var line: Int
        var startLine: Int?
        var severity: String
        var body: String
        var include: Bool?

        enum CodingKeys: String, CodingKey {
            case id, path, line, startLine = "start_line", severity, body, include
        }

        func sameContent(as other: Comment) -> Bool {
            path == other.path && line == other.line && startLine == other.startLine
                && severity == other.severity && body == other.body
        }
    }

    var pr: String?
    var event: String
    var summary: String
    var comments: [Comment]

    init(review: Review) {
        pr = review.pr.key.id
        event = review.event.agentValue
        summary = review.summary
        comments = review.comments.map {
            Comment(id: $0.id.uuidString, path: $0.path, line: $0.line, startLine: $0.startLine,
                    severity: $0.severity.rawValue, body: $0.body, include: $0.include)
        }
    }

    init(json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        self = try JSONDecoder().decode(DraftFile.self, from: data)
    }

    var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Replaces the review's draft with this one. Comments are matched by id, so their include state carries over.
    func apply(to review: inout Review, index: DiffIndex) {
        let existing = Dictionary(review.comments.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        review.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        review.event = ReviewEvent(agentValue: event)
        review.comments = comments.map { source in
            var comment = source.id.flatMap { existing[$0] }
                ?? DraftComment(path: source.path, line: source.line, severity: .suggestion, body: "")
            comment.path = source.path
            comment.line = source.line
            comment.startLine = source.startLine
            comment.severity = Severity(rawValue: source.severity) ?? comment.severity
            comment.body = source.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let include = source.include { comment.include = include }
            index.place(&comment)
            return comment
        }
    }

    /// A short description of how this draft differs from `old`, or nil if it doesn't.
    func changes(from old: DraftFile) -> String? {
        var parts: [String] = []
        if summary != old.summary { parts.append("rewrote the summary") }
        if event != old.event { parts.append("changed the suggested action to \(ReviewEvent(agentValue: event).label.lowercased())") }
        let oldByID = Dictionary(old.comments.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(comments.compactMap(\.id))
        let added = comments.filter { $0.id.flatMap { oldByID[$0] } == nil }.count
        let removed = old.comments.filter { $0.id.map { !newIDs.contains($0) } ?? true }.count
        let edited = comments.filter { c in c.id.flatMap { oldByID[$0] }.map { !c.sameContent(as: $0) } ?? false }.count
        let toggled = comments.filter { c in
            guard let include = c.include, let old = c.id.flatMap({ oldByID[$0] }) else { return false }
            return old.include != include
        }.count
        for (count, verb) in [(edited, "edited"), (added, "added"), (removed, "removed"), (toggled, "included or excluded")] where count > 0 {
            parts.append("\(verb) \(count) comment\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Follow-up conversation about a draft, continuing the review's Claude session.
enum Discussion {
    struct Reply: Sendable {
        var text: String
        var revised: DraftFile?
        var sessionID: String?
        var costUSD: Double?
    }

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["reply"],"properties":{\
        "reply":{"type":"string"},\
        "revised":{"type":"object","additionalProperties":false,"required":["summary","event","comments"],"properties":{\
        "summary":{"type":"string"},\
        "event":{"type":"string","enum":["comment","approve","request_changes"]},\
        "comments":{"type":"array","items":{"type":"object","additionalProperties":false,\
        "required":["path","line","severity","body"],"properties":{\
        "id":{"type":"string"},"path":{"type":"string"},"line":{"type":"integer","minimum":1},\
        "start_line":{"type":"integer","minimum":1},\
        "severity":{"type":"string","enum":["blocking","important","question","suggestion","nit"]},\
        "body":{"type":"string"}}}}}}}}
        """

    static func prompt(message: String, draft: DraftFile) -> String {
        """
        \(message)

        ---
        From Review Desk: the current draft of the review is below, including any edits I've made. Comments with "include": false are ones I've unchecked.

        Answer my message above in `reply`. If it means the review should change (I asked for a change, I made a convincing case, or you changed your mind), also return `revised` with the complete updated draft. Keep the `id` of each comment you keep, and leave `id` out for new ones. Otherwise leave `revised` out. If you still think a point stands, say so and explain why rather than dropping it.

        ```json
        \(String(decoding: draft.encoded, as: UTF8.self))
        ```
        """
    }

    static func send(message: String, draft: DraftFile, session: String, workspace: Workspace,
                     claude: ClaudeOptions, log: @escaping @Sendable (LogEntry) -> Void) async throws -> Reply {
        let result = try await ReviewRunner.invoke(prompt: prompt(message: message, draft: draft), schema: schema,
                                                   resume: session, name: nil, workspace: workspace, claude: claude, log: log)
        let revised = (result.output["revised"] as? [String: Any]).flatMap { try? DraftFile(json: $0) }
        return Reply(text: (result.output["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                     revised: revised, sessionID: result.sessionID, costUSD: result.costUSD)
    }

    /// A shell command that continues the review's session in a terminal, pointed at draft.json.
    static func terminalCommand(workspace: Workspace, session: String) -> String {
        let prompt = "I want to talk through this review. The current draft, including my edits, is in \(workspace.draftPath). Review Desk shows that file and picks up changes to it, so edit it to change the draft, and keep each comment's id. Read it, then wait for my questions."
        // --setting-sources user: use my settings but not any .claude settings or hooks the pull request adds.
        return "cd \(shellQuote(workspace.worktree)) && claude --resume \(session) --setting-sources user \(shellQuote(prompt))"
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import Foundation

struct PostOutcome: Sendable {
    var url: String?
    var reviewID: String?
    /// The review body as sent.
    var body: String
    var note: String?
}

enum Poster {
    /// The body for GitHub's create-review endpoint. A nil `event` creates a pending review.
    /// Comments on lines outside the diff, or all comments when `inline` is false, go in the review body.
    static func payload(for review: Review, event: ReviewEvent?, footer: String, inline: Bool = true) -> [String: Any] {
        let included = review.comments.filter(\.include)
        let inlineComments = inline ? included.filter(\.inDiff) : []
        let bodyComments = inline ? included.filter { !$0.inDiff } : included

        var parts = [review.summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !bodyComments.isEmpty {
            parts.append(bodyComments.map { "**[`\($0.location)`](\($0.blobURL(review.pr)))**\n\($0.body)" }
                .joined(separator: "\n\n"))
        }
        parts.append(footer.trimmingCharacters(in: .whitespacesAndNewlines))

        var payload: [String: Any] = [
            "commit_id": review.pr.headSha,
            "body": parts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
            "comments": inlineComments.map { comment -> [String: Any] in
                var dict: [String: Any] = ["path": comment.path, "line": comment.line, "side": "RIGHT", "body": comment.body]
                if let start = comment.startLine {
                    dict["start_line"] = start
                    dict["start_side"] = "RIGHT"
                }
                return dict
            },
        ]
        if let event { payload["event"] = event.rawValue }
        return payload
    }

    static func post(_ review: Review, event: ReviewEvent?, footer: String, github: GitHub) async throws -> PostOutcome {
        let first = payload(for: review, event: event, footer: footer)
        do {
            let posted = try await github.submitReview(review.pr.key, payload: JSONSerialization.data(withJSONObject: first))
            return PostOutcome(url: posted.url, reviewID: posted.nodeID, body: first["body"] as? String ?? "")
        } catch let error as GitHubError where error.unprocessable && !((first["comments"] as? [Any])?.isEmpty ?? true) {
            let fallback = payload(for: review, event: event, footer: footer, inline: false)
            let posted = try await github.submitReview(review.pr.key, payload: JSONSerialization.data(withJSONObject: fallback))
            return PostOutcome(url: posted.url, reviewID: posted.nodeID, body: fallback["body"] as? String ?? "",
                               note: "GitHub rejected the inline comments (\(error.message)), so they were posted in the review body instead.")
        }
    }
}

import SwiftUI

struct PRDetailView: View {
    let item: PRItem
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PRHeader(item: item)
            if item.section == .ignored {
                Banner(icon: "eye.slash",
                       text: item.requested ? "You're ignoring this request. It comes back if you're asked to review again."
                                            : "You're ignoring this pull request. It comes back if your review is requested.",
                       tint: .secondary) {
                    Button("Stop Ignoring") { model.stopIgnoring(item.id) }
                }
            }
            if item.outdated, let latest = item.latest, !latest.status.isActive {
                Banner(icon: "arrow.triangle.2.circlepath",
                       text: "New commits were pushed after this review (reviewed \(latest.pr.headSha.prefix(7)), now \(item.pr.headSha.prefix(7))).",
                       tint: .blue) {
                    ReviewAgainButton(pr: item.pr)
                }
            }
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let review = item.latest {
            switch review.status {
            case .queued, .preparing, .running:
                RunningView(review: review)
            case .drafted, .posting:
                if let binding = model.binding(for: review.id) {
                    DraftEditor(review: binding)
                }
            case .pending, .posted, .dismissed:
                FinishedView(review: review, pr: item.pr)
            case .failed:
                FailedView(review: review, pr: item.pr)
            }
        } else {
            StartReviewView(pr: item.pr, ignorable: item.canIgnore && !item.ignored, removable: item.source == .added)
        }
    }
}

struct PRHeader: View {
    let item: PRItem

    var body: some View {
        let pr = item.pr
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            FlowLayout(spacing: 12, lineSpacing: 6) {
                Link(destination: pr.key.webURL) {
                    Text(pr.key.id).font(.callout.monospaced())
                }
                Text("@\(pr.author)")
                Text("\(pr.baseRef) ← \(pr.headRef)")
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("+\(pr.additions)").foregroundStyle(.green)
                    Text("−\(pr.deletions)").foregroundStyle(.red)
                    Text("in \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
                }
                if pr.isDraft { Pill(text: "Draft PR") }
                switch item.source {
                case .requested?:
                    Pill(text: pr.requestedDirectly ? "Requested from you" : "Requested from \(pr.requestedTeams.first ?? "your team")",
                         tint: pr.requestedDirectly ? .blue : .secondary)
                case .watched?:
                    Pill(text: "Watching")
                case .added?:
                    Pill(text: "Added by you")
                case nil:
                    EmptyView()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The settings for a review, starting from those in Settings, and the button that starts it.
struct ReviewLauncher: View {
    let pr: PullRequest
    var buttonLabel = "Start Review"
    var ignorable = false
    var removable = false
    var onStart: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var chosen: ReviewOptions?
    @State private var extra = ""

    var body: some View {
        let defaults = model.reviewOptions(for: pr)
        let options = Binding(get: { chosen ?? defaults }, set: { chosen = $0 })
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Scope").gridColumnAlignment(.trailing)
                    presetPicker(.scope, selection: options.scopePresetID)
                }
                GridRow {
                    Text("Voice")
                    presetPicker(.voice, selection: options.voicePresetID)
                }
                GridRow {
                    Text("Model")
                    HStack(spacing: 8) {
                        ModelField(text: options.model)
                        Picker("Effort", selection: options.effort) {
                            ForEach(ModelField.efforts, id: \.self) { Text("\($0) effort").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Limits")
                    HStack(spacing: 16) {
                        LimitControl(limit: options.budget, unit: .dollars, title: "Cost")
                        LimitControl(limit: options.timeLimit, unit: .minutes, title: "Time")
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Also")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Extra instructions for this review (optional)", text: $extra, axis: .vertical)
                            .lineLimit(2...6)
                        if !options.wrappedValue.instructions.isEmpty {
                            Text("Added to the additional instructions in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 520)
                }
                GridRow {
                    Text("Then")
                    Picker("Then", selection: options.completion) {
                        ForEach(Completion.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if options.wrappedValue.completion == .submit {
                    GridRow {
                        Text("Verdict")
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Request changes", selection: options.verdict.requestChanges) {
                                ForEach(RequestChangesRule.allCases) { Text($0.label).tag($0) }
                            }
                            Picker("Approve", selection: options.verdict.approve) {
                                ForEach(ApproveRule.allCases) { Text($0.label).tag($0) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            HStack(spacing: 12) {
                Button(buttonLabel) {
                    model.startReview(pr, options: options.wrappedValue, extra: extra)
                    onStart?()
                }
                .buttonStyle(.borderedProminent)
                if ignorable {
                    Button("Ignore") { model.ignore(pr) }
                        .help("Hide this pull request until you're asked to review it again")
                }
                if removable {
                    Button("Remove from List") { model.removeAdded(pr.id) }
                }
                if chosen != nil && chosen != defaults {
                    Button("Use Settings") { chosen = nil }
                        .help("Go back to the settings for \(pr.key.slug)")
                }
            }
        }
    }

    private func presetPicker(_ kind: PresetKind, selection: Binding<String>) -> some View {
        Picker(kind.title, selection: selection) {
            ForEach(model.presets(kind)) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(maxWidth: 260)
    }
}

struct ReviewAgainButton: View {
    let pr: PullRequest
    var label = "Review Again…"
    @State private var showing = false

    var body: some View {
        Button(label) { showing = true }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ReviewLauncher(pr: pr, onStart: { showing = false })
                    .padding(16)
                    .frame(width: 520)
            }
    }
}

struct StartReviewView: View {
    let pr: PullRequest
    var ignorable = false
    var removable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ReviewLauncher(pr: pr, ignorable: ignorable, removable: removable)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description").font(.subheadline).foregroundStyle(.secondary)
                    if pr.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description.").foregroundStyle(.secondary)
                    } else {
                        MarkdownPreview(text: pr.body, repo: pr.key.slug, html: pr.bodyHTML)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RunningView: View {
    let review: Review
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(review.status.label + "…").font(.headline).fixedSize()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(since: review.startedAt ?? review.createdAt, now: context.date))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text("\(review.model) · \(review.effort) effort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button("Cancel") { model.cancel(review.id) }
                    .fixedSize()
            }
            LogView(entries: review.log, follow: true)
        }
        .padding(20)
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct FinishedView: View {
    let review: Review
    let pr: PullRequest
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    statusIcon
                        .font(.title3)
                    Text(statusText)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ReviewAgainButton(pr: pr)
                        .fixedSize()
                }
                if let url = gitHubURL {
                    HStack(spacing: 16) {
                        Link("Open on GitHub", destination: url)
                        if pending {
                            Button(copied ? "Copied" : "Copy Summary") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(review.onGitHub?.body ?? review.postedBody ?? review.summary, forType: .string)
                                copied = true
                            }
                        }
                    }
                }
                if pending {
                    Text("GitHub doesn't show the summary of a pending review, and drops it when you submit from the web. Paste it into the Submit review box.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = review.postedNote {
                    Text(note).foregroundStyle(.secondary)
                }
                ReviewReadOnly(review: review)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: review.id) { copied = false }
    }

    private var pending: Bool { review.status == .pending }

    /// A pending review has no page of its own, so its link is the pull request's changes, where it can be submitted.
    private var gitHubURL: URL? {
        if pending { return URL(string: pr.url + "/files") }
        guard review.status == .posted else { return nil }
        return review.postedURL.flatMap { URL(string: $0) }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch review.status {
        case .pending: Image(systemName: "paperplane.fill").foregroundStyle(.blue)
        case .posted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        default: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch review.status {
        case .pending: return "Pending on GitHub"
        case .posted: return review.postedEvent.map { "Posted (\($0.label.lowercased()))" } ?? "Posted"
        default: return "Discarded"
        }
    }
}

struct FailedView: View {
    let review: Review
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Banner(icon: "exclamationmark.triangle.fill", text: review.error ?? "The review failed.", tint: .red) {
                ReviewAgainButton(pr: pr, label: "Try Again…")
            }
            LogView(entries: review.log)
                .padding(20)
        }
    }
}

/// The review as it is on GitHub once synced from there, or else as drafted.
struct ReviewReadOnly: View {
    let review: Review

    var body: some View {
        let repo = review.pr.key.slug
        VStack(alignment: .leading, spacing: 14) {
            if let posted = review.onGitHub {
                if posted.body.isEmpty {
                    Text("No summary").foregroundStyle(.secondary)
                } else {
                    MarkdownPreview(text: posted.body, repo: repo)
                }
                ForEach(posted.comments, id: \.url) { comment in
                    PostedCommentCard(location: comment.location, url: URL(string: comment.url) ?? review.pr.key.webURL,
                                text: comment.body, repo: repo)
                }
            } else {
                MarkdownPreview(text: review.summary, repo: repo)
                ForEach(review.comments.filter(\.include)) { comment in
                    PostedCommentCard(severity: comment.severity, location: comment.location, url: comment.blobURL(review.pr),
                                text: comment.body, repo: repo)
                }
            }
        }
    }
}

private struct PostedCommentCard: View {
    var severity: Severity?
    let location: String
    let url: URL
    let text: String
    let repo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let severity { SeverityBadge(severity: severity) }
                Link(location, destination: url)
                    .font(.callout.monospaced())
            }
            MarkdownPreview(text: text, repo: repo)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

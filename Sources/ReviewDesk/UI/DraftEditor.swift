import SwiftUI

struct DraftEditor: View {
    @Binding var review: Review
    @Environment(AppModel.self) private var model
    @AppStorage("showDiscussion") private var showDiscussion = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = review.error {
                Banner(icon: "exclamationmark.triangle.fill", text: error, tint: .red)
            }
            GeometryReader { proxy in
                // Side by side when there's room; otherwise the discussion takes the draft's place.
                let sideBySide = proxy.size.width >= 760
                HStack(spacing: 0) {
                    if !showDiscussion || sideBySide {
                        draft
                    }
                    if showDiscussion {
                        if sideBySide { Divider() }
                        DiscussionPanel(reviewID: review.id)
                            .frame(width: sideBySide ? min(440, max(300, proxy.size.width * 0.4)) : proxy.size.width)
                    }
                }
            }
            Divider()
            actionBar
        }
    }

    private var draft: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MarkdownEditor(text: $review.summary, repo: review.pr.key.slug, minHeight: 90) {
                    Text("Summary").font(.headline)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Comments").font(.headline)
                    Text("\(review.comments.filter(\.include).count) of \(review.comments.count) included")
                        .foregroundStyle(.secondary)
                }
                if review.comments.isEmpty {
                    Text("No inline comments.").foregroundStyle(.secondary)
                }
                ForEach($review.comments) { $comment in
                    CommentCard(comment: $comment, pr: review.pr)
                }

                DisclosureGroup("Review log (\(review.log.count))") {
                    LogView(entries: review.log)
                        .frame(height: 260)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Drops the run details first, then shortens the buttons, so nothing gets truncated.
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                runInfo
                Spacer(minLength: 12)
                discardButton
                discussToggle(iconOnly: false)
                postButton
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                discardButton
                discussToggle(iconOnly: false)
                postButton
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                discussToggle(iconOnly: true)
                postButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .disabled(review.status == .posting)
    }

    private var runInfo: some View {
        Text([review.model, review.effort + " effort", formattedCost(review.costUSD)].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .help("The model and effort used. The cost is what the review would have cost at API prices; with a subscription it counts against your usage limits instead.")
    }

    private var discardButton: some View {
        Button("Discard", role: .destructive) { model.dismiss(review.id) }
            .fixedSize()
    }

    private func discussToggle(iconOnly: Bool) -> some View {
        Toggle(isOn: $showDiscussion) {
            Label("Discuss", systemImage: "bubble.left.and.bubble.right")
                .labelStyle(DiscussLabelStyle(iconOnly: iconOnly))
        }
        .toggleStyle(.button)
        .fixedSize()
        .help("Ask Claude about its findings, push back, or have it revise the draft")
    }

    /// Posts with the current event; the arrow offers the other events, a pending review, and discarding.
    private var postButton: some View {
        HStack(spacing: 4) {
            Button("Post as \(review.event.label)") { model.post(review.id, event: review.event) }
                .buttonStyle(.borderedProminent)
                .help("Post the review to GitHub")
            Menu {
                ForEach(ReviewEvent.allCases) { event in
                    Button("Post as \(event.label)") { model.post(review.id, event: event) }
                }
                Divider()
                Button("Send as Pending Review") { model.post(review.id, event: nil) }
                Divider()
                Button("Discard Draft", role: .destructive) { model.dismiss(review.id) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Other ways to post, including a pending review only you can see")
        }
        .fixedSize()
    }
}

private struct DiscussLabelStyle: LabelStyle {
    var iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

struct CommentCard: View {
    @Binding var comment: DraftComment
    let pr: PullRequest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Include", isOn: $comment.include)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            MarkdownEditor(text: $comment.body, repo: pr.key.slug, minHeight: 40) {
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    SeverityBadge(severity: comment.severity)
                    Link(comment.location, destination: comment.blobURL(pr))
                        .font(.callout.monospaced())
                    if !comment.inDiff {
                        Label("Not on a changed line, so it goes in the summary", systemImage: "arrow.turn.left.up")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(comment.include ? 1 : 0.55)
    }
}

/// A text editor that grows to fit its text, for use inside a scroll view.
struct GrowingTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor: same font and wrapping, plus a line of room to type into.
            Text(text + "\n ")
                .font(.body)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .hidden()
            TextEditor(text: $text)
                .font(.body)
                .scrollDisabled(true)
        }
        .editorChrome()
    }
}

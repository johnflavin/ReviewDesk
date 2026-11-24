import SwiftUI

/// A conversation with the review's Claude session about the draft.
struct DiscussionPanel: View {
    let reviewID: UUID
    @Environment(AppModel.self) private var model
    @State private var message = ""
    @State private var copied = false

    var body: some View {
        if let review = model.review(reviewID) {
            let busy = model.discussing.contains(reviewID)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if review.conversation.isEmpty {
                                Text("Ask about a finding, push back, or ask for changes. Claude can revise the draft, and you can undo its changes.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(review.conversation) { message in
                                ChatRow(message: message).id(message.id)
                            }
                            if busy {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Claude is replying…").foregroundStyle(.secondary)
                                }
                                .id("pending")
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: review.conversation.count) {
                        withAnimation { proxy.scrollTo(busy ? AnyHashable("pending") : AnyHashable(review.conversation.last?.id), anchor: .bottom) }
                    }
                    .onChange(of: busy) {
                        if busy { withAnimation { proxy.scrollTo("pending", anchor: .bottom) } }
                    }
                }
                Divider()
                composer(review: review, busy: busy)
            }
        }
    }

    private func composer(review: Review, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message Claude", text: $message, axis: .vertical)
                .lineLimit(2...8)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            HStack {
                if review.previousDraft != nil {
                    Button("Undo Change") { model.undoDraftChange(reviewID) }
                        .help("Restore the draft as it was before the last change")
                }
                Spacer()
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider().padding(.vertical, 2)
            HStack(alignment: .firstTextBaseline) {
                Text("Or continue in your terminal. Edits Claude makes to draft.json there show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy Command") {
                    guard let command = model.terminalCommand(for: reviewID) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                .help("Copies a command that resumes this review's Claude session in a terminal")
            }
        }
        .padding(12)
    }

    private func send() {
        guard !model.discussing.contains(reviewID) else { return }
        let text = message
        message = ""
        model.discuss(reviewID, message: text)
    }
}

private struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)))
            }
        case .assistant:
            MarkdownText(message.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        case .note:
            Label(message.text, systemImage: "pencil.line")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

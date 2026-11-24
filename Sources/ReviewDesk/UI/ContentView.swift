import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            if let id = model.selection, let item = model.item(id) {
                PRDetailView(item: item)
                    .id(item.id)
            } else {
                ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showingAddPR = true
                } label: {
                    Label("Add Pull Request", systemImage: "plus")
                }
                .help("Add a pull request to review")

                Button {
                    Task { await model.poll() }
                } label: {
                    Label("Check Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isPolling)
                .help("Check GitHub for review requests")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $model.showingAddPR) {
            AddPullRequestSheet()
        }
    }
}

/// Adds a pull request that doesn't request my review.
struct AddPullRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Pull Request").font(.headline)
            Text("Review any open pull request, whether or not your review was requested.")
                .foregroundStyle(.secondary)
            TextField("Pull request", text: $text, prompt: Text("Pull request URL or owner/repo#123"))
                .labelsHidden()
                .onSubmit(add)
                .onChange(of: text) { problem = nil }
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(PRKey(text) == nil || adding)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let copied = NSPasteboard.general.string(forType: .string), copied.contains("github.com/"),
               copied.contains("/pull/"), PRKey(copied) != nil {
                text = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func add() {
        guard PRKey(text) != nil, !adding else { return }
        adding = true
        Task {
            do {
                try await model.addPullRequest(text)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            adding = false
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showIgnored") private var showIgnored = false

    var body: some View {
        @Bindable var model = model
        let items = model.items
        List(selection: $model.selection) {
            ForEach(PRSection.allCases) { section in
                let rows = items.filter { $0.section == section }
                if !rows.isEmpty && section == .ignored {
                    Section(isExpanded: $showIgnored) {
                        rowList(rows)
                    } header: {
                        Text("Ignored (\(rows.count))")
                    }
                } else if !rows.isEmpty {
                    Section {
                        rowList(rows)
                    } header: {
                        HStack(spacing: 6) {
                            Text(section.title)
                            if section == .toReview && model.isPolling {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    if model.lastPoll == nil {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Checking GitHub…")
                        }
                    } else {
                        Label("No pull requests", systemImage: "tray")
                    }
                } description: {
                    Text("Pull requests that request your review show up here, along with any you add and those in organizations you watch.")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PollStatusBar()
        }
    }

    private func rowList(_ rows: [PRItem]) -> some View {
        ForEach(rows) { item in
            PRRow(item: item)
                .tag(item.id)
                .contextMenu {
                    if item.source != nil && !item.ignored {
                        Button(item.unread ? "Mark as Read" : "Mark as Unread") { model.markUnread(item.id, !item.unread) }
                    }
                    if item.ignored {
                        Button("Stop Ignoring") { model.stopIgnoring(item.id) }
                    } else if item.canIgnore {
                        Button("Ignore") { model.ignore(item.pr) }
                    }
                    if item.source == .added {
                        Button("Remove from List") { model.removeAdded(item.id) }
                    }
                    Divider()
                    Button("Open on GitHub") { NSWorkspace.shared.open(item.pr.key.webURL) }
                }
        }
    }
}

struct PRRow: View {
    let item: PRItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusIcon(item: item)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.pr.title)
                    .fontWeight(item.unread ? .semibold : .regular)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(item.pr.key.repo) #\(String(item.pr.key.number))")
                    Text("@\(item.pr.author)")
                    if item.requested && !item.pr.requestedDirectly {
                        Text("· team")
                    }
                    if item.outdated && item.section != .inProgress {
                        Text("· new commits")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .opacity(item.section == .ignored ? 0.6 : 1)
    }
}

struct StatusIcon: View {
    let item: PRItem

    var body: some View {
        switch item.latest?.status {
        case nil:
            if item.unread {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
                    .help("New")
            }
        case .queued?:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .preparing?, .running?, .posting?:
            ProgressView().controlSize(.mini)
        case .drafted?:
            Image(systemName: "doc.text.fill").foregroundStyle(.orange)
        case .posted?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .dismissed?:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .failed?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

struct PollStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.isPolling {
                ProgressView().controlSize(.mini)
            }
            if let error = model.pollError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).lineLimit(2).help(error)
            } else if let last = model.lastPoll {
                TimelineView(.periodic(from: last, by: 60)) { context in
                    Text("Checked \(Self.elapsed(since: last, now: context.date))")
                        .lineLimit(1)
                }
            } else {
                Text("Not checked yet")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    static func elapsed(since date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "< 1 minute ago"
        case 1: return "1 minute ago"
        case ..<60: return "\(minutes) minutes ago"
        case ..<120: return "1 hour ago"
        default: return "\(minutes / 60) hours ago"
        }
    }
}

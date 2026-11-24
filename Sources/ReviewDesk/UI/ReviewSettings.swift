import SwiftUI

/// Review settings for all repositories, with overrides for organizations and repositories.
struct ReviewSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("reviewSettingsScope") private var storedScope = ""
    @State private var adding = false
    @State private var confirmingRemoval = false

    /// The selected scope as settings name it, or "" for all repositories.
    private var scope: String {
        if storedScope.contains("/") { return model.settings.repoKey(storedScope) ?? "" }
        return storedScope.isEmpty ? "" : model.settings.orgKey(storedScope) ?? ""
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                scopeList
                Divider()
                HStack(spacing: 2) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").frame(width: 22, height: 18)
                    }
                    .help("Add an organization or repository")
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        AddScopeView { name in
                            storedScope = name
                            adding = false
                        }
                    }
                    Button { requestRemoval() } label: {
                        Image(systemName: "minus").frame(width: 22, height: 18)
                    }
                    .disabled(scope.isEmpty)
                    .help("Remove the selected organization's or repository's settings")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(width: 220)
            Divider()
            PolicyForm(scope: scope).id(scope)
        }
        .confirmationDialog("Remove the settings for \(scope) and its repositories?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { remove() }
        }
    }

    private var scopeList: some View {
        List(selection: Binding<String?>(get: { scope }, set: { storedScope = $0 ?? "" })) {
            Label("All Repositories", systemImage: "square.stack.3d.up").tag("")
            let groups = model.settings.scopeGroups
            if !groups.isEmpty {
                Section("Organizations and repositories") {
                    ForEach(groups) { group in
                        row(group.owner, title: group.owner, icon: "building.2")
                        ForEach(group.repos, id: \.self) { slug in
                            row(slug, title: String(slug.split(separator: "/").last ?? ""), icon: "book.closed")
                                .padding(.leading, 18)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ scope: String, title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if model.settings.ownPolicy(scope).watch == true {
                Image(systemName: "eye").foregroundStyle(.secondary).help("Watching")
            }
        }
        .tag(scope)
    }

    private func requestRemoval() {
        let hasRepos = model.settings.scopeGroups.first { $0.owner == scope }.map { !$0.repos.isEmpty } ?? false
        if hasRepos { confirmingRemoval = true } else { remove() }
    }

    private func remove() {
        model.removeScope(scope)
        storedScope = scope.contains("/") ? AppSettings.owner(of: scope) : ""
    }
}

struct ScopeGroup: Identifiable {
    var owner: String
    var repos: [String]
    var id: String { owner.lowercased() }
}

extension AppSettings {
    /// Owners with settings, each with its repositories that have settings.
    var scopeGroups: [ScopeGroup] {
        var groups = orgs.keys.map { ScopeGroup(owner: $0, repos: []) }
        for slug in repos.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            let owner = Self.owner(of: slug)
            if let i = groups.firstIndex(where: { $0.owner.caseInsensitiveCompare(owner) == .orderedSame }) {
                groups[i].repos.append(slug)
            } else {
                groups.append(ScopeGroup(owner: owner, repos: [slug]))
            }
        }
        return groups.sorted { $0.owner.lowercased() < $1.owner.lowercased() }
    }
}

/// The settings for one scope. Outside all repositories, each setting either follows the less specific level
/// or is checked and set here.
private struct PolicyForm: View {
    let scope: String
    @Environment(AppModel.self) private var model

    private var policy: Binding<ReviewPolicy> {
        Binding(get: { model.settings.ownPolicy(scope) }, set: { model.settings.setOwnPolicy($0, for: scope) })
    }

    private var parent: EffectivePolicy { model.settings.inherited(by: scope) }

    private var parentName: String? {
        if scope.isEmpty { return nil }
        return scope.contains("/") ? AppSettings.owner(of: scope) : "All Repositories"
    }

    var body: some View {
        @Bindable var model = model
        let effective = model.settings.policy(for: scope)
        Form {
            if let parentName {
                Section {
                    Text("Changes here apply only to \(scope). Checked settings are set here; unchecked ones follow \(parentName).")
                        .foregroundStyle(.secondary)
                }
            }

            if scope.isEmpty {
                Section {
                    Picker("List those updated within", selection: $model.settings.watchDays) {
                        ForEach(AppSettings.watchDayChoices, id: \.self) { days in
                            Text(days == 0 ? "Any time" : "\(days) days").tag(days)
                        }
                    }
                } header: {
                    Text("Watched pull requests")
                } footer: {
                    note("To list every open pull request in an organization or repository, not only those requesting your review, add it with + and turn on Watch.")
                }
            } else {
                Section {
                    // An organization has no less specific setting to follow.
                    row("Watch", \.watch, inherited: parent.watched, inheritable: scope.contains("/")) {
                        Toggle("Watch", isOn: $0).toggleStyle(.switch)
                    }
                } footer: {
                    if effective.watched, let since = effective.watchingSince {
                        note("Listing every open pull request, not only those requesting your review, except your own. Watching since \(since.formatted(date: .abbreviated, time: .shortened)).")
                    } else {
                        note("List every open pull request, not only those requesting your review, except your own.")
                    }
                }
            }

            Section {
                ForEach(PRKind.allCases) { kind in
                    row(kind.label, kind.autoReviewKey) { Toggle(kind.label, isOn: $0).toggleStyle(.switch) }
                }
                row("Skip draft pull requests", \.skipDraftPRs) { Toggle("Skip", isOn: $0).toggleStyle(.switch) }
                row("Review again when new commits are pushed", \.reReviewOnPush) { Toggle("Again", isOn: $0).toggleStyle(.switch) }
            } header: {
                Text("Review automatically")
            } footer: {
                note("Other pull requests are those listed because you watch their organization or repository. Only those opened after you started watching are reviewed automatically.")
            }

            Section("When a pull request first appears") {
                ForEach(PRKind.allCases) { kind in
                    row(kind.label, kind.arrivalKey) { value in
                        Picker(kind.label, selection: value) {
                            ForEach(Arrival.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
            }

            Section {
                row("Model", \.model) { ModelField(text: $0) }
                row("Effort", \.effort) { value in
                    Picker("Effort", selection: value) {
                        ForEach(ModelField.efforts, id: \.self) { Text($0).tag($0) }
                    }
                }
                row("Cost limit", \.budget) { LimitControl(limit: $0, unit: .dollars) }
                row("Time limit", \.timeLimit) { LimitControl(limit: $0, unit: .minutes) }
                if scope.isEmpty {
                    Stepper("Run up to \(model.settings.maxConcurrent) reviews at once",
                            value: $model.settings.maxConcurrent, in: 1...6)
                }
            } header: {
                Text("Reviewer")
            } footer: {
                note("The cost limit is measured at API prices and stops runaway reviews. With a subscription, reviews count against your usage limits instead.")
            }

            Section("Instructions") {
                row("Scope", \.scopePresetID) { value in
                    Picker("Scope", selection: value) {
                        ForEach(model.presets(.scope)) { Text($0.name).tag($0.id) }
                    }
                }
                row("Voice", \.voicePresetID) { value in
                    Picker("Voice", selection: value) {
                        ForEach(model.presets(.voice)) { Text($0.name).tag($0.id) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Additional instructions")
                    TextEditor(text: Binding(
                        get: { policy.wrappedValue.instructions ?? "" },
                        set: { policy.wrappedValue.instructions = $0.isEmpty && !scope.isEmpty ? nil : $0 }))
                        .font(.body)
                        .frame(height: 80)
                        .editorChrome()
                    note(instructionsNote)
                }
            }

            Section {
                row("Reviews I start", \.afterManual) { value in
                    Picker("Reviews I start", selection: value) {
                        ForEach(Completion.allCases) { Text($0.label).tag($0) }
                    }
                }
                row("Automatic reviews", \.afterAuto) { value in
                    Picker("Automatic reviews", selection: value) {
                        ForEach(AutoCompletion.allCases) { Text($0.label).tag($0) }
                    }
                }
                if effective.completion(automatic: false) == .submit || effective.completion(automatic: true) == .submit {
                    row("Request changes", \.requestChanges) { value in
                        Picker("Request changes", selection: value) {
                            ForEach(RequestChangesRule.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    row("Approve", \.approve) { value in
                        Picker("Approve", selection: value) {
                            ForEach(ApproveRule.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                row("Footer", \.footer) { value in
                    TextField("Footer", text: value, prompt: Text("None"), axis: .vertical)
                        .lineLimit(1...4)
                }
            } header: {
                Text("When a review finishes")
            } footer: {
                note("A pending review is visible only to you until you submit it on GitHub. A submitted review approves or requests changes by the rules above, and otherwise comments. The footer is added to every review posted.")
            }
        }
        .formStyle(.grouped)
    }

    private var instructionsNote: String {
        switch parentName {
        case nil: "Added to every review."
        case "All Repositories"?: "Added to reviews in \(scope), after the instructions for All Repositories."
        case let owner?: "Added to reviews in \(scope), after the instructions for All Repositories and \(owner)."
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Value: Equatable, Control: View>(
        _ title: String, _ key: WritableKeyPath<ReviewPolicy, Value?>, inherited: Value? = nil, inheritable: Bool = true,
        @ViewBuilder control: @escaping (Binding<Value>) -> Control
    ) -> some View {
        PolicyRow(title: title, key: key, policy: policy, inherited: inherited ?? parent[key],
                  parentName: inheritable ? parentName : nil, control: control)
    }
}

/// One setting. With a parent, a checkbox chooses between following the parent's value and setting one here.
private struct PolicyRow<Value: Equatable, Control: View>: View {
    let title: String
    let key: WritableKeyPath<ReviewPolicy, Value?>
    @Binding var policy: ReviewPolicy
    let inherited: Value
    let parentName: String?
    @ViewBuilder let control: (Binding<Value>) -> Control

    var body: some View {
        let overridden = policy[keyPath: key] != nil
        LabeledContent {
            // Changing an inherited setting sets it here.
            control(Binding(get: { policy[keyPath: key] ?? inherited }, set: { policy[keyPath: key] = $0 }))
                .labelsHidden()
                .opacity(parentName != nil && !overridden ? 0.55 : 1)
        } label: {
            if let parentName {
                HStack(spacing: 6) {
                    Toggle(title, isOn: Binding(get: { overridden }, set: { policy[keyPath: key] = $0 ? inherited : nil }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    Text(title)
                }
                .help(overridden ? "Set here. Uncheck to follow \(parentName)." : "Follows \(parentName).")
            } else {
                Text(title)
            }
        }
    }
}

/// Finds an organization or repository and adds settings for it.
private struct AddScopeView: View {
    var onAdd: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an organization or repository").font(.headline)
            TextField("Name", text: $text, prompt: Text("owner or owner/repo"))
                .labelsHidden()
                .onSubmit { add(name) }
                .onChange(of: text) { problem = nil }
            let matches = suggestions
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(matches, id: \.self) { suggestion in
                        Button {
                            text = suggestion
                            add(suggestion)
                        } label: {
                            Label(suggestion, systemImage: suggestion.contains("/") ? "book.closed" : "building.2")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                if problem != nil, let name {
                    Button("Add Anyway") { finish(name) }
                }
                Button("Add") { add(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name == nil || checking)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    /// The text as owner or owner/repo, accepting GitHub URLs too.
    private var name: String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "github.com/"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true).prefix(2)
        value = parts.joined(separator: "/")
        return value.range(of: #"^[A-Za-z0-9-]+(/[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil ? value : nil
    }

    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(model.scopeSuggestions.filter { query.isEmpty || $0.lowercased().contains(query) }.prefix(8))
    }

    private func add(_ name: String?) {
        guard let name, !checking else { return }
        checking = true
        problem = nil
        Task {
            do {
                finish(try await model.lookUpScope(name))
            } catch {
                problem = "Couldn't find \(name). \(error.localizedDescription)"
            }
            checking = false
        }
    }

    private func finish(_ name: String) {
        model.addScope(name)
        onAdd(name)
    }
}

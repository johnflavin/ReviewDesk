import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            GitHubSettings()
                .tabItem { Label("GitHub", systemImage: "person.badge.key") }
            ReviewSettings()
                .tabItem { Label("Reviews", systemImage: "checklist") }
            PresetSettings()
                .tabItem { Label("Presets", systemImage: "text.alignleft") }
            LocalSettings()
                .tabItem { Label("Local Setup", systemImage: "desktopcomputer") }
        }
        .frame(width: 780, height: 600)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Appearance", selection: $model.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Check GitHub", selection: $model.settings.pollMinutes) {
                    ForEach(AppSettings.pollChoices, id: \.self) { Text(AppSettings.pollLabel($0)).tag($0) }
                }
                Toggle("Show notifications", isOn: $model.settings.notify)
            } footer: {
                Text("What to review automatically, and what happens to finished reviews, is in Reviews.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PresetSettings: View {
    @State private var kind = PresetKind.scope

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                ForEach(PresetKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(12)
            Divider()
            PresetEditor(kind: kind).id(kind)
        }
    }
}

private struct PresetEditor: View {
    let kind: PresetKind
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Built in") {
                    ForEach(model.presets(kind).filter(\.builtIn)) { row($0) }
                }
                let mine = model.presets(kind).filter { !$0.builtIn }
                if !mine.isEmpty {
                    Section("Yours") {
                        ForEach(mine) { row($0) }
                    }
                }
            }
            .frame(width: 210)
            Divider()
            detail
        }
        .onAppear { if selection == nil { selection = model.defaultPresetID(kind) } }
    }

    private func row(_ preset: Preset) -> some View {
        HStack {
            Text(preset.name)
            Spacer()
            if model.defaultPresetID(kind) == preset.id {
                Text("Default").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(preset.id)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let preset = model.allPresets.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                if let binding = model.presetBinding(id) {
                    TextField("Name", text: binding.name)
                        .font(.headline)
                    TextEditor(text: binding.text)
                        .editorChrome()
                } else {
                    Text(preset.name).font(.headline)
                    ScrollView {
                        Text(preset.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    Text("Built-in presets can't be edited. Duplicate one to make your own version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Duplicate") { selection = model.duplicatePreset(preset) }
                    if !preset.builtIn {
                        Button("Delete", role: .destructive) {
                            model.deletePreset(id)
                            selection = model.defaultPresetID(kind)
                        }
                    }
                    Spacer()
                    Button("Use by Default") { model.setDefaultPreset(id, kind) }
                        .disabled(model.defaultPresetID(kind) == id)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView("Select a preset", systemImage: "text.alignleft")
        }
    }
}

private struct LocalSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("claude", text: $model.settings.claudePath,
                          prompt: Text(Tools.locate("claude") ?? "Not found"))
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Reviews run `claude -p` with your normal Claude login, so they use your subscription rather than API billing. The agent can read only the pull request's checkout and the context files Review Desk writes for it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Folders searched for existing clones") {
                ForEach(model.settings.repoRoots, id: \.self) { root in
                    HStack {
                        Text(root)
                        Spacer()
                        Button {
                            model.settings.repoRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { addFolder() }
            }
            Section("Repositories without a local clone") {
                TextField("Clone them into", text: $model.settings.cloneDir)
            }
            Section {
                ForEach(model.repos) { repo in
                    LabeledContent(repo.slug, value: Tools.abbreviate(repo.path))
                }
            } header: {
                HStack {
                    Text("Found \(model.repos.count) GitHub repositories")
                    Spacer()
                    Button("Rescan") { Task { await model.rescanRepos() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.rescanRepos() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = Tools.abbreviate(url.path)
        if !model.settings.repoRoots.contains(path) { model.settings.repoRoots.append(path) }
    }
}

private struct GitHubSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingGH = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Sign in with", selection: Binding(
                    get: { model.settings.githubAuth },
                    set: { mode in
                        if mode == .ghCLI { confirmingGH = true } else { model.settings.githubAuth = mode }
                    })) {
                    ForEach(GitHubAuthMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            switch model.settings.githubAuth {
            case .ghCLI:
                Section {
                    Label("Review Desk is using the same token as `gh`, which can usually do anything your account can, in every organization you belong to. Personal access tokens can be limited to what Review Desk needs.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    TextField("gh", text: $model.settings.ghPath, prompt: Text(Tools.locate("gh") ?? "Not found"))
                }
            case .tokens:
                Section {
                    ForEach($model.settings.githubTokens) { $entry in
                        TokenRow(entry: $entry) {
                            Keychain.delete(entry.id)
                            model.settings.githubTokens.removeAll { $0.id == entry.id }
                        }
                    }
                    Button("Add Token") { model.settings.githubTokens.append(TokenEntry()) }
                } header: {
                    Text("Tokens")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A fine-grained token covers one organization or account. Add one for each organization whose pull requests you review or watch, with that organization as its owner. A token with no owner is used for everything else.")
                        Text("Each token needs **Pull requests: Read and write**, to read pull requests and post reviews, and **Contents: Read**, to fetch the code, on the repositories you review. The Create link fills these in. Some organizations must approve a token before it works.")
                        Text("Review Desk only finds review requests in repositories a token can see. Test shows how many it finds.")
                        Text("A [classic token](https://github.com/settings/tokens/new?scopes=repo&description=Review%20Desk) with the `repo` scope covers every organization at once, but grants much broader access.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Setting up tokens")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.setEditingAuth(true) }
        .onDisappear { model.setEditingAuth(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            model.setEditingAuth(false)
        }
        .alert("Use your gh login?", isPresented: $confirmingGH) {
            Button("Use gh Login") { model.settings.githubAuth = .ghCLI }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The gh token can usually do anything your GitHub account can, in every organization you belong to. Personal access tokens can be limited to reading pull requests and posting reviews.")
        }
    }
}

private struct TokenRow: View {
    @Binding var entry: TokenEntry
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var status: (ok: Bool, text: String)?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Owner", text: $entry.owner, prompt: Text("Any owner"))
                    .labelsHidden()
                    .frame(width: 150)
                SecureField("Token", text: $token, prompt: Text("Paste token"))
                    .labelsHidden()
                    .onChange(of: token) {
                        guard token != (Keychain.read(entry.id) ?? "") else { return }
                        Keychain.write(token, account: entry.id)
                        status = nil
                        model.githubAuthChanged()
                    }
                Button(testing ? "Testing…" : "Test") { test() }
                    .disabled(token.isEmpty || testing)
                Button(action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this token")
            }
            HStack(alignment: .firstTextBaseline) {
                if let status {
                    Text(status.text)
                        .foregroundStyle(status.ok ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                }
                Spacer()
                Link(entry.owner.isEmpty ? "Create a token" : "Create a token for \(entry.owner)", destination: createURL)
            }
            .font(.caption)
        }
        .onAppear { token = Keychain.read(entry.id) ?? "" }
    }

    private var createURL: URL {
        let owner = entry.owner.trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://github.com/settings/personal-access-tokens/new")!
        components.queryItems = [
            URLQueryItem(name: "name", value: owner.isEmpty ? "Review Desk" : "Review Desk (\(owner))"),
            URLQueryItem(name: "description", value: "Lets Review Desk read pull requests and post reviews."),
            URLQueryItem(name: "expires_in", value: "90"),
            URLQueryItem(name: "pull_requests", value: "write"),
            URLQueryItem(name: "contents", value: "read"),
        ] + (owner.isEmpty ? [] : [URLQueryItem(name: "target_name", value: owner)])
        return components.url!
    }

    private func test() {
        testing = true
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await GitHub.describe(token: token)
            status = result
            testing = false
            if result.ok { model.authTestSucceeded() }
        }
    }
}

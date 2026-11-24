import AppKit

/// Lets scripts drive the UI for testing. Only active when launched with REVIEWDESK_DEBUG=1.
/// Post the distributed notification "app.reviewdesk.debug" with userInfo keys:
/// "select" (a PR id), "settings" ("open"), and "snapshot" (a PNG path; optional "window" title).
@MainActor
enum DebugHooks {
    static func install(model: AppModel) {
        guard ProcessInfo.processInfo.environment["REVIEWDESK_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("app.reviewdesk.debug"), object: nil, queue: .main) { note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated {
                if let id = info["select"] { model.selection = id }
                if let size = info["resize"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
                   let window = NSApp.windows.first(where: { $0.title == "Review Desk" }) {
                    window.setContentSize(NSSize(width: size[0], height: size[1]))
                }
                if let show = info["showDiscussion"] { UserDefaults.standard.set(show == "1", forKey: "showDiscussion") }
                if let mode = info["appearance"] {
                    NSApp.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
                }
                if let on = info["previewAll"] { UserDefaults.standard.set(on == "1", forKey: "debugPreviewAll") }
                if let show = info["showIgnored"] { UserDefaults.standard.set(show == "1", forKey: "showIgnored") }
                if let id = info["ignore"], let pr = model.item(id)?.pr { model.ignore(pr) }
                if let id = info["unignore"] { model.stopIgnoring(id) }
                if info["poll"] == "1" { Task { await model.poll() } }
                if let id = info["start"], let pr = model.item(id)?.pr { model.startReview(pr, options: model.reviewOptions(for: pr)) }
                if let text = info["addPR"] { Task { try? await model.addPullRequest(text) } }
                if info["showAddPR"] == "1" { model.showingAddPR = true }
                if let scope = info["addScope"] { model.addScope(scope) }
                if let scope = info["removeScope"] { model.removeScope(scope) }
                if let scope = info["watch"] {
                    var policy = model.settings.ownPolicy(scope)
                    policy.watch = true
                    model.settings.setOwnPolicy(policy, for: scope)
                }
                if let scope = info["scope"] { UserDefaults.standard.set(scope, forKey: "reviewSettingsScope") }
                if let editing = info["editingAuth"] { model.setEditingAuth(editing == "1") }
                if info["authChanged"] == "1" { model.githubAuthChanged() }
                if let path = info["dumpState"] {
                    let items = model.items.map { "\($0.section.title)\t\($0.unread ? "unread" : "read")\t\($0.id)" }
                    let lines = ["lastPoll=\(model.lastPoll.map { "\($0)" } ?? "nil") polling=\(model.isPolling) error=\(model.pollError ?? "nil")",
                                 "requested=\(model.requested.count) watched=\(model.watched.count) added=\(model.added.count) unread=\(model.unread.count)"] + items
                    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
                if let text = info["discuss"], let id = model.selection, let review = model.item(id)?.latest {
                    UserDefaults.standard.set(true, forKey: "showDiscussion")
                    model.discuss(review.id, message: text)
                }
                if let path = info["keychainTest"] {
                    Task {
                        let account = "debug-test"
                        let wrote = Keychain.write("not-a-real-token", account: account)
                        let read = Keychain.read(account)
                        let check = await GitHub.describe(token: read ?? "")
                        Keychain.delete(account)
                        let gone = Keychain.read(account) == nil
                        let report = "wrote=\(wrote) readBack=\(read == "not-a-real-token") deleted=\(gone)\ncheck: \(check)\n"
                        try? report.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
                if info["settings"] == "open" {
                    NSApp.activate()
                    if let menu = NSApp.mainMenu?.items.first?.submenu,
                       let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                        menu.performActionForItem(at: index)
                    }
                }
                if let tab = info["tab"] {
                    clickToolbarItem(labelled: tab)
                }
                if let y = info["scroll"].flatMap(Double.init) {
                    scroll(windowTitle: info["window"], to: y)
                }
                if let path = info["snapshot"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        snapshot(windowTitle: info["window"], to: path)
                    }
                }
            }
        }
    }

    /// Switches Settings tabs, which are toolbar items.
    private static func clickToolbarItem(labelled label: String) {
        for window in NSApp.windows where window.isVisible {
            if let item = window.toolbar?.items.first(where: { $0.label == label }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
    }

    /// Scrolls the window's tallest scroll view.
    private static func scroll(windowTitle: String?, to y: Double) {
        let window = NSApp.windows.first { window in
            window.isVisible && (windowTitle.map { window.title.contains($0) } ?? (window.title == "Review Desk"))
        }
        var views: [NSScrollView] = []
        func collect(_ v: NSView) {
            if let scroll = v as? NSScrollView { views.append(scroll) }
            v.subviews.forEach(collect)
        }
        if let content = window?.contentView { collect(content) }
        guard let target = views.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
        target.contentView.scroll(to: NSPoint(x: 0, y: y))
        target.reflectScrolledClipView(target.contentView)
    }

    private static func snapshot(windowTitle: String?, to path: String) {
        let window = windowTitle == "sheet" ? NSApp.windows.first { $0.isSheet && $0.isVisible } : NSApp.windows.first { window in
            window.isVisible && (windowTitle.map { window.title.contains($0) } ?? (window.title == "Review Desk"))
        }
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            let titles = NSApp.windows.map { "\($0.title) visible=\($0.isVisible)" }.joined(separator: "\n")
            try? titles.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        if let window {
            var lines = ["window \(window.frame)", "layout \(window.contentLayoutRect)",
                         "content \(window.contentView?.frame ?? .zero)", "screen \(window.screen?.visibleFrame ?? .zero)"]
            func dump(_ v: NSView, _ depth: Int) {
                guard depth < 16 else { return }
                if v is NSScrollView || depth < 3 || v.frame.height > 600 {
                    let scroll = (v as? NSScrollView).map { " scrolledTo=\($0.contentView.bounds.origin)" } ?? ""
                    lines.append(String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame)\(scroll)")
                }
                v.subviews.forEach { dump($0, depth + 1) }
            }
            dump(view, 0)
            try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
    }
}

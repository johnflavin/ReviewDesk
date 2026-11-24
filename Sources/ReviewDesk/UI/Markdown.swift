import SwiftUI
import WebKit

// MARK: - Markdown as GitHub renders it

/// Shows Markdown the way GitHub renders it. Uses `html` when it's already rendered; otherwise asks GitHub,
/// and falls back to rendering it here if that fails.
struct MarkdownPreview: View {
    let text: String
    let repo: String
    var html: String?

    @Environment(AppModel.self) private var model
    @State private var rendered: String?
    @State private var failed = false

    var body: some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing to preview").foregroundStyle(.secondary)
            } else if let html = html ?? rendered {
                GitHubHTML(html: html)
            } else if failed {
                MarkdownText(text)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: text) {
            guard html == nil else { return }
            do {
                rendered = try await model.renderMarkdown(text, repo: repo)
                failed = false
            } catch {
                failed = rendered == nil
            }
        }
    }
}

/// Markdown text with GitHub-style Write and Preview tabs.
struct MarkdownEditor<Header: View>: View {
    @Binding var text: String
    let repo: String
    var minHeight: CGFloat
    @ViewBuilder var header: Header

    @State private var previewing = UserDefaults.standard.bool(forKey: "debugPreviewAll")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                header
                Spacer(minLength: 8)
                Picker("Mode", selection: $previewing) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if previewing {
                MarkdownPreview(text: text, repo: repo)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            } else {
                GrowingTextEditor(text: $text, minHeight: minHeight)
            }
        }
    }
}

/// Rendered HTML at its natural height, styled to match the app.
struct GitHubHTML: View {
    let html: String
    @State private var height: CGFloat = 18

    var body: some View {
        HTMLView(html: html, height: $height)
            .frame(height: height)
    }
}

/// A web view that never scrolls itself, so the scroll view around it keeps working.
private final class EmbeddedWebView: WKWebView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - lastWidth) > 0.5 {
            lastWidth = newSize.width
            onWidthChange?()
        }
    }
}

private struct HTMLView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> EmbeddedWebView {
        let configuration = WKWebViewConfiguration()
        // The HTML comes from GitHub and has no scripts of its own; measuring the height runs from the app.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = EmbeddedWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        let coordinator = context.coordinator
        view.onWidthChange = { [weak view] in
            if let view { coordinator.measure(view) }
        }
        return view
    }

    func updateNSView(_ view: EmbeddedWebView, context: Context) {
        context.coordinator.height = $height
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        view.loadHTMLString(MarkdownStyle.document(html), baseURL: URL(string: "https://github.com/"))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loadedHTML: String?

        init(height: Binding<CGFloat>) { self.height = height }

        func measure(_ view: WKWebView) {
            view.evaluateJavaScript("document.getElementById('content').getBoundingClientRect().height") { [weak self] result, _ in
                guard let self, let value = result as? Double else { return }
                let measured = CGFloat(value.rounded(.up))
                if abs(self.height.wrappedValue - measured) > 0.5 { self.height.wrappedValue = measured }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Images can change the height once they load.
            for delay in [0.3, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    if let self, let webView { self.measure(webView) }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

private enum MarkdownStyle {
    static func document(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>\(css)</style></head><body><div id="content">\(body)</div></body></html>
        """
    }

    static let css = """
        :root { --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --code: rgba(129,139,152,0.15); --link: #0969da; }
        @media (prefers-color-scheme: dark) {
          :root { --fg: #e6edf3; --muted: #9198a1; --border: #3d444d; --code: rgba(110,118,129,0.3); --link: #4493f8; }
        }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body { font: 13px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--fg); -webkit-font-smoothing: antialiased; }
        #content { display: flow-root; word-wrap: break-word; }
        #content > :first-child, #content > :first-child > :first-child { margin-top: 0 !important; }
        #content > :last-child { margin-bottom: 0 !important; }
        p, ul, ol, blockquote, pre, table, details, dl { margin: 0 0 10px; }
        h1, h2, h3, h4, h5, h6 { margin: 18px 0 8px; font-weight: 600; line-height: 1.25; }
        h1 { font-size: 1.6em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h2 { font-size: 1.35em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
        h3 { font-size: 1.15em; } h4 { font-size: 1em; } h5, h6 { font-size: .9em; color: var(--muted); }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd, tt { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; }
        code { background: var(--code); padding: .15em .35em; border-radius: 5px; }
        pre { background: var(--code); padding: 10px 12px; border-radius: 6px; line-height: 1.4; white-space: pre-wrap; }
        pre code { background: none; padding: 0; font-size: 1em; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .2em; } li > ul, li > ol { margin: .2em 0 0; }
        ul.contains-task-list { list-style: none; padding-left: 1.4em; }
        .task-list-item input { margin: 0 .35em 0 -1.4em; vertical-align: middle; }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
        table { border-collapse: collapse; } th, td { border: 1px solid var(--border); padding: 4px 10px; } th { font-weight: 600; }
        hr { border: 0; border-top: 1px solid var(--border); margin: 16px 0; }
        img { max-width: 100%; }
        details summary { cursor: pointer; }
        .anchor, .octicon { display: none; }
        .highlight { margin-bottom: 10px; } .highlight pre { margin: 0; }
        .pl-k { color: #cf222e; } .pl-s, .pl-pds, .pl-sr { color: #0a3069; } .pl-c { color: #59636e; }
        .pl-c1, .pl-v, .pl-ent { color: #0550ae; } .pl-en { color: #6639ba; } .pl-smi, .pl-s1 { color: inherit; }
        @media (prefers-color-scheme: dark) {
          .pl-k { color: #ff7b72; } .pl-s, .pl-pds, .pl-sr { color: #a5d6ff; } .pl-c { color: #9198a1; }
          .pl-c1, .pl-v, .pl-ent { color: #79c0ff; } .pl-en { color: #d2a8ff; }
        }
        """
}

// MARK: - Markdown rendered locally

/// Renders Markdown in native text: headings, lists, quotes, code blocks and inline styles.
/// Used where GitHub's rendering isn't available, and for Claude's replies.
struct MarkdownText: View {
    let source: String

    init(_ source: String) { self.source = source }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlock {
    enum Kind {
        case paragraph, code, rule
        case heading(Int)
        case listItem(marker: String, depth: Int)
    }

    var kind: Kind
    var content: AttributedString
    var quoted: Bool

    static func parse(_ source: String) -> [MarkdownBlock] {
        let cleaned = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: cleaned, options: options) else {
            return [MarkdownBlock(kind: .paragraph, content: AttributedString(source), quoted: false)]
        }
        var blocks: [MarkdownBlock] = []
        var previous: PresentationIntent?
        var previousRow: Int?
        for run in attributed.runs {
            let intent = run.presentationIntent
            let text = AttributedString(attributed[run.range])
            if !blocks.isEmpty && intent == previous {
                blocks[blocks.count - 1].content.append(text)
                continue
            }
            // Table cells in the same row share a line.
            let row = intent?.components.compactMap { component -> Int? in
                if case .tableRow(rowIndex: let index) = component.kind { return index }
                if case .tableHeaderRow = component.kind { return -1 }
                return nil
            }.first
            if let row, row == previousRow, !blocks.isEmpty {
                blocks[blocks.count - 1].content.append(AttributedString("  │  ") + text)
                previous = intent
                continue
            }
            previous = intent
            previousRow = row
            blocks.append(block(for: intent, content: text))
        }
        return blocks.map { block in
            var block = block
            while block.content.characters.last?.isNewline == true { block.content.characters.removeLast() }
            return block
        }
    }

    private static func block(for intent: PresentationIntent?, content: AttributedString) -> MarkdownBlock {
        var kind = Kind.paragraph
        var quoted = false
        var ordinal: Int?
        var marker: String?
        var depth = 0
        // Components run from the innermost block outwards.
        for component in intent?.components ?? [] {
            switch component.kind {
            case .header(level: let level): kind = .heading(level)
            case .codeBlock: kind = .code
            case .thematicBreak: kind = .rule
            case .blockQuote: quoted = true
            case .listItem(ordinal: let value): if ordinal == nil { ordinal = value }
            case .orderedList:
                depth += 1
                if marker == nil { marker = "\(ordinal ?? 1)." }
            case .unorderedList:
                depth += 1
                if marker == nil { marker = "•" }
            default: break
            }
        }
        if let marker, case .paragraph = kind { kind = .listItem(marker: marker, depth: depth) }
        return MarkdownBlock(kind: kind, content: content, quoted: quoted)
    }

    @ViewBuilder
    var view: some View {
        Group {
            switch kind {
            case .paragraph:
                Text(content)
            case .heading(let level):
                Text(content).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                    .padding(.top, 4)
            case .code:
                Text(content)
                    .font(.callout.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            case .listItem(let marker, let depth):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker).monospacedDigit()
                    Text(content)
                }
                .padding(.leading, CGFloat(max(0, depth - 1)) * 16 + 4)
            case .rule:
                Divider()
            }
        }
        .padding(.leading, quoted ? 10 : 0)
        .overlay(alignment: .leading) {
            if quoted { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        }
        .foregroundStyle(quoted ? .secondary : .primary)
    }
}

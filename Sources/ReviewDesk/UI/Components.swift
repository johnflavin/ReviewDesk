import SwiftUI

struct Banner<Accessory: View>: View {
    let icon: String
    let text: String
    let tint: Color
    let accessory: Accessory

    init(icon: String, text: String, tint: Color = .orange, @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.text = text
        self.tint = tint
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            // A line limit, not fixedSize: text that may grow without bound inflates the window's minimum height.
            Text(text)
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }
}

extension Banner where Accessory == EmptyView {
    init(icon: String, text: String, tint: Color = .orange) {
        self.init(icon: icon, text: text, tint: tint) { EmptyView() }
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        Pill(text: severity.label, tint: color)
    }

    private var color: Color {
        switch severity {
        case .blocking: .red
        case .important: .orange
        case .question: .purple
        case .suggestion: .blue
        case .nit: .gray
        }
    }
}

struct LogView: View {
    let entries: [LogEntry]
    var follow = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(entries) { entry in
                        LogRow(entry: entry).id(entry.id)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            .onChange(of: entries.count) {
                if follow, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if follow, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(entry.text)
                .font(entry.kind == .tool ? .callout.monospaced() : .callout)
                .foregroundStyle(entry.kind == .info ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private var icon: String {
        switch entry.kind {
        case .info: "info.circle"
        case .tool: "doc.text.magnifyingglass"
        case .text: "text.bubble"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .info: .secondary
        case .tool: .blue
        case .text: .purple
        case .error: .red
        }
    }
}

extension View {
    /// Gives a TextEditor a text-field look.
    func editorChrome() -> some View {
        self
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}

func formattedCost(_ cost: Double?) -> String? {
    cost.map { String(format: "$%.2f", $0) }
}

/// Lays out views left to right, wrapping onto more lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // A zero width is a probe for the minimum size; answer with a single line rather than one line per item.
        let width = proposal.width.flatMap { $0 > 0 ? $0 : nil } ?? .infinity
        let lines = arrange(width: width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var line = lines.removeLast()
            if !line.indices.isEmpty && line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            lines.append(line)
        }
        return lines
    }
}

/// A model name, typed or chosen from the usual ones.
struct ModelField: View {
    @Binding var text: String

    static let choices = ["opus", "sonnet", "fable", "haiku"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    var body: some View {
        HStack(spacing: 2) {
            TextField("Model", text: $text)
                .frame(minWidth: 70, maxWidth: 120)
            Menu {
                ForEach(Self.choices, id: \.self) { name in
                    Button(name) { text = name }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a model")
        }
    }
}

/// A cost or time limit that can be turned off.
struct LimitControl: View {
    enum Unit { case dollars, minutes }

    @Binding var limit: Limit
    var unit: Unit
    /// Shown beside a checkbox. Without one, the limit is turned on and off with a switch.
    var title: String?

    var body: some View {
        HStack(spacing: 4) {
            if let title {
                Toggle(title, isOn: $limit.on).toggleStyle(.checkbox)
            } else {
                Toggle("Limit", isOn: $limit.on).toggleStyle(.switch).controlSize(.small)
            }
            if limit.on {
                if unit == .dollars { Text("$") }
                TextField("Limit", value: $limit.value, format: .number)
                    .frame(width: 52)
                if unit == .minutes { Text("min") }
            }
        }
        .fixedSize()
    }
}

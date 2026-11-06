import AppKit
import Charts
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - What a reply can show

/// Something a reply shows instead of saying: a chart, an image or a link
/// preview. Each sits on lines of its own in the text.
enum MediaPart {
    case chart(ChartSpec)
    case image(URL, alt: String)
    case link(URL)

    /// The part when `text` is nothing but one chart, image or link.
    static func parse(_ text: String) -> MediaPart? {
        let blocks = RichBlock.parse(text)
        guard blocks.count == 1 else { return nil }
        switch blocks[0] {
        case .chart(let spec): return .chart(spec)
        case .image(let url, let alt): return .image(url, alt: alt)
        case .link(let url): return .link(url)
        default: return nil
        }
    }

    /// `![alt](src)` alone on a line: a local path or a web address.
    static func image(in line: String) -> (URL, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("!["), t.hasSuffix(")"), let mid = t.range(of: "](") else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<mid.lowerBound])
        let src = String(t[mid.upperBound..<t.index(before: t.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard let url = url(src) else { return nil }
        return (url, alt)
    }

    /// A web address alone on a line (bare, or `[text](address)`).
    static func link(in line: String) -> URL? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), t.hasSuffix(")"), let mid = t.range(of: "](") {
            t = String(t[mid.upperBound..<t.index(before: t.endIndex)])
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !t.contains(" "), t.hasPrefix("http://") || t.hasPrefix("https://"),
              let url = URL(string: t), url.host != nil
        else { return nil }
        return url
    }

    static func url(_ src: String) -> URL? {
        if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("file://") { return URL(string: src) }
        let path = (src as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }
}

/// The text of a reply without what it shows, for the caption by the cursor.
func captionText(_ text: String) -> String {
    var out: [String] = []
    var inFence = false
    for line in text.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            inFence.toggle()
            continue
        }
        if inFence || MediaPart.image(in: line) != nil || MediaPart.link(in: line) != nil { continue }
        out.append(line)
    }
    return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Charts

/// A chart as Claude writes it, in a ```chart block.
struct ChartSpec: Decodable, Equatable {
    enum Kind: String, Decodable { case bar, line, area, pie, point }
    struct Point: Decodable, Equatable, Identifiable {
        var label: String
        var value: Double
        var series: String?
        var id: String { (series ?? "") + "\u{1}" + label }

        enum CodingKeys: String, CodingKey { case label, value, series, x, y }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Labels may come as numbers (years), values as text.
            func text(_ k: CodingKeys) -> String? {
                (try? c.decode(String.self, forKey: k)) ?? (try? c.decode(Double.self, forKey: k)).map {
                    $0.rounded() == $0 ? String(Int($0)) : String($0)
                }
            }
            func number(_ k: CodingKeys) -> Double? {
                (try? c.decode(Double.self, forKey: k)) ?? (try? c.decode(String.self, forKey: k)).flatMap {
                    Double($0.filter { "0123456789.-".contains($0) })
                }
            }
            label = text(.label) ?? text(.x) ?? ""
            value = number(.value) ?? number(.y) ?? 0
            series = try? c.decode(String.self, forKey: .series)
        }
    }

    var type: Kind = .bar
    var title: String?
    var unit: String?
    var data: [Point]

    enum CodingKeys: String, CodingKey { case type, title, unit, data }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .bar
        title = try? c.decode(String.self, forKey: .title)
        unit = try? c.decode(String.self, forKey: .unit)
        data = Array(try c.decode([Point].self, forKey: .data).prefix(60))
    }

    static func parse(_ json: String) -> ChartSpec? {
        guard let spec = try? JSONDecoder().decode(ChartSpec.self, from: Data(json.utf8)), !spec.data.isEmpty
        else { return nil }
        return spec
    }

    var hasSeries: Bool { Set(data.compactMap(\.series)).count > 1 }
}

/// A chart card, drawn with Swift Charts: it grows in when it appears, and
/// hovering shows a value.
struct ChartCard: View {
    var spec: ChartSpec
    var compact = false
    var fill: Color = bubbleGray

    @State private var grown: Double
    @State private var selected: String?

    /// `animated` false draws it fully grown at once (previews).
    init(spec: ChartSpec, compact: Bool = false, fill: Color = bubbleGray, animated: Bool = true) {
        self.spec = spec
        self.compact = compact
        self.fill = fill
        _grown = State(initialValue: animated ? 0 : 1)
    }

    private static let palette = [pilotAccent] + Array(pilotRainbow.dropLast()) + [.teal, .green, .yellow, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if let title = spec.title, !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: compact ? 11.5 : 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if let selected, let p = spec.data.first(where: { $0.label == selected }) {
                        Text(format(p.value))
                            .font(.system(size: compact ? 11 : 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    } else if let unit = spec.unit, !unit.isEmpty {
                        Text(unit).font(.system(size: compact ? 10.5 : 11.5)).foregroundStyle(.secondary)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: selected)
            }
            chart
                .frame(height: compact ? 120 : spec.type == .pie ? 210 : 190)
        }
        .padding(compact ? 10 : 14)
        .frame(width: compact ? 300 : 380)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(fill))
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { grown = 1 }
        }
    }

    @ViewBuilder private var chart: some View {
        let base = Chart(spec.data) { p in
            let v = p.value * grown
            switch spec.type {
            case .bar:
                if spec.hasSeries {
                    BarMark(x: .value("Label", p.label), y: .value("Value", v))
                        .foregroundStyle(by: .value("Series", p.series ?? ""))
                        .position(by: .value("Series", p.series ?? ""))
                        .cornerRadius(4)
                } else {
                    BarMark(x: .value("Label", p.label), y: .value("Value", v))
                        .foregroundStyle(LinearGradient(colors: [pilotAccent, pilotRainbow[0]], startPoint: .bottom, endPoint: .top))
                        .cornerRadius(5)
                        .opacity(selected == nil || selected == p.label ? 1 : 0.45)
                }
            case .line, .point:
                LineMark(x: .value("Label", p.label), y: .value("Value", v))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: spec.type == .point ? 0 : 2.4, lineCap: .round))
                PointMark(x: .value("Label", p.label), y: .value("Value", v))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .symbolSize(spec.type == .point ? 60 : selected == p.label ? 60 : 22)
            case .area:
                AreaMark(x: .value("Label", p.label), y: .value("Value", v))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .interpolationMethod(.catmullRom)
                    .opacity(0.35)
                LineMark(x: .value("Label", p.label), y: .value("Value", v))
                    .foregroundStyle(by: .value("Series", p.series ?? ""))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            case .pie:
                SectorMark(angle: .value("Value", max(v, 0.0001)), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .foregroundStyle(by: .value("Label", p.label))
                    .cornerRadius(4)
            }
            if spec.type != .pie, let selected, selected == p.label, p.series == nil || !spec.hasSeries {
                RuleMark(x: .value("Label", p.label))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(range: Self.palette)
        .chartLegend(spec.type == .pie || spec.hasSeries ? .visible : .hidden)
        .chartYAxis(spec.type == .pie ? .hidden : .automatic)

        if spec.type == .pie {
            base
        } else {
            base.chartXSelection(value: $selected)
        }
    }

    private func format(_ v: Double) -> String {
        let n = v.formatted(.number.precision(.fractionLength(0...2)))
        guard let unit = spec.unit, !unit.isEmpty else { return n }
        return unit == "%" ? n + "%" : n + " " + unit
    }
}

// MARK: - Images

/// An image in the chat, like a photo in Messages: rounded, no bubble,
/// click to open it.
struct ImageCard: View {
    var url: URL
    var alt: String
    var compact = false

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        let side: CGFloat = compact ? 240 : 320
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(bubbleGray)
                    .frame(width: side * 0.75, height: side * 0.5)
                    .overlay {
                        if failed {
                            Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
                                .font(.system(size: 12)).foregroundStyle(.secondary).padding()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(maxWidth: side, maxHeight: side)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .help(alt)
        .onTapGesture { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            if url.isFileURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
            if let image {
                Button("Copy Image") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = self.url
        let data: Data? = url.isFileURL
            ? await Task.detached { try? Data(contentsOf: url) }.value
            : try? await URLSession.shared.data(from: url).0
        if let data, let img = NSImage(data: data) {
            image = img
        } else {
            failed = true
        }
    }
}

// MARK: - Link previews

/// A link as a card, like Messages: the page's picture, title and site.
struct LinkCard: View {
    var url: URL
    var compact = false
    var fill: Color = bubbleGray
    @ObservedObject private var previews = LinkPreviews.shared

    var body: some View {
        let preview = previews.cache[url]
        let width: CGFloat = compact ? 260 : 300
        VStack(alignment: .leading, spacing: 0) {
            if let image = preview?.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: compact ? 120 : 150)
                    .clipped()
                    .transition(.opacity)
            }
            HStack(spacing: 9) {
                Group {
                    if let icon = preview?.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "safari").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? url.host ?? url.absoluteString)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .lineLimit(2)
                        .redacted(reason: preview == nil ? .placeholder : [])
                    Text((url.host ?? "").replacingOccurrences(of: "www.", with: ""))
                        .font(.system(size: compact ? 10.5 : 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .frame(width: width, alignment: .leading)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: preview?.image != nil)
        .onTapGesture { NSWorkspace.shared.open(url) }
        .help(url.absoluteString)
        .contextMenu {
            Button("Open Link") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .task(id: url) { await previews.load(url) }
    }
}

/// Link previews, fetched once per address with LinkPresentation.
@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    struct Preview {
        var title: String?
        var image: NSImage?
        var icon: NSImage?
    }

    @Published private(set) var cache: [URL: Preview] = [:]
    private var loading: Set<URL> = []

    func load(_ url: URL) async {
        guard cache[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        defer { loading.remove(url) }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        guard let meta = try? await provider.startFetchingMetadata(for: url) else {
            cache[url] = Preview(title: url.host)
            return
        }
        let title = meta.title
        cache[url] = Preview(title: title)
        async let image = Self.image(from: meta.imageProvider)
        async let icon = Self.image(from: meta.iconProvider)
        let (i, c) = await (image, icon)
        cache[url] = Preview(title: title, image: i, icon: c)
    }

    private static func image(from provider: NSItemProvider?) async -> NSImage? {
        guard let provider else { return nil }
        return await withCheckedContinuation { done in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done.resume(returning: data.flatMap(NSImage.init(data:)))
            }
        }
    }
}

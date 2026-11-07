import AppKit
import SwiftUI

/// A reply with its formatting: paragraphs, bullet and numbered lists,
/// headings, quotes and code blocks, plus inline bold, italics, code and
/// links (bare URLs too), and charts, images and link cards. Used in Home's
/// bubbles and the notch.
struct RichText: View {
    var text: String
    var size: CGFloat = 13.5
    /// Colour for code backgrounds and quote bars, tuned to the background.
    var subtle: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.45) {
            ForEach(Array(RichBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: RichBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(Self.inline(s))
        case .heading(let s):
            Text(Self.inline(s)).font(.system(size: size + 1.5, weight: .bold))
        case .bullets(let items):
            VStack(alignment: .leading, spacing: size * 0.25) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").fontWeight(.bold)
                        Text(Self.inline(item))
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: size * 0.25) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().fontWeight(.semibold)
                        Text(Self.inline(item))
                    }
                }
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(subtle.opacity(0.35)).frame(width: 3)
                Text(Self.inline(s)).italic().opacity(0.85)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .chart(let spec):
            ChartCard(spec: spec, compact: size < 13, fill: subtle.opacity(0.07))
        case .scene(let spec):
            SceneCard(spec: spec)
        case .image(let url, let alt):
            ImageCard(url: url, alt: alt, compact: size < 13)
        case .link(let url):
            LinkCard(url: url, compact: size < 13, fill: subtle.opacity(0.08))
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: size - 1.5, design: .monospaced))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .background(subtle.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    /// Inline markdown, with bare web addresses made into links.
    static func inline(_ s: String) -> AttributedString {
        var out = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let plain = String(out.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url, let r = Range(match.range, in: plain),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out),
                  out[lower..<upper].link == nil
            else { continue }
            out[lower..<upper].link = url
        }
        return out
    }
}

enum RichBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case code(String)
    /// A ```chart block that holds a valid chart.
    case chart(ChartSpec)
    /// A ```scene block that holds a valid 3D model.
    case scene(SceneSpec)
    /// `![alt](src)` on a line of its own.
    case image(URL, String)
    /// A web address on a line of its own: shown as a preview card.
    case link(URL)

    static func parse(_ text: String) -> [RichBlock] {
        var blocks: [RichBlock] = []
        var para: [String] = []
        var code: [String]?
        var codeTag = ""
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))) }
            para = []
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    let body = c.joined(separator: "\n")
                    if codeTag == "chart", let spec = ChartSpec.parse(body) {
                        blocks.append(.chart(spec))
                    } else if codeTag == "scene", let spec = SceneSpec.parse(body) {
                        blocks.append(.scene(spec))
                    } else {
                        blocks.append(.code(body))
                    }
                    code = nil
                } else {
                    flush()
                    code = []
                    codeTag = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                flush()
            } else if let (url, alt) = MediaPart.image(in: line) {
                flush()
                blocks.append(.image(url, alt))
            } else if let url = MediaPart.link(in: line) {
                flush()
                blocks.append(.link(url))
            } else if let item = bullet(line) {
                flush()
                if case .bullets(let items) = blocks.last {
                    blocks[blocks.count - 1] = .bullets(items + [item])
                } else {
                    blocks.append(.bullets([item]))
                }
            } else if let item = numbered(line) {
                flush()
                if case .numbered(let items) = blocks.last {
                    blocks[blocks.count - 1] = .numbered(items + [item])
                } else {
                    blocks.append(.numbered([item]))
                }
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix(">") {
                flush()
                let s = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote(let q) = blocks.last {
                    blocks[blocks.count - 1] = .quote(q + "\n" + s)
                } else {
                    blocks.append(.quote(s))
                }
            } else {
                para.append(line)
            }
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func bullet(_ line: String) -> String? {
        for p in ["- ", "* ", "• "] where line.hasPrefix(p) {
            return String(line.dropFirst(p.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

/// Splits a reply into the separate texts Cursor Pilot sends, at blank
/// lines, keeping lists in one piece; code blocks, charts, images and links
/// each come as their own message, like a photo or a link in Messages.
func messageParts(_ text: String) -> [String] {
    var parts: [String] = []
    var current: [String] = []
    var inCode = false
    func flush() {
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        current = []
    }
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inCode {
                current.append(line)
                inCode = false
                flush()
            } else {
                flush()
                inCode = true
                current.append(line)
            }
            continue
        }
        if inCode {
            current.append(line)
        } else if MediaPart.image(in: line) != nil || MediaPart.link(in: line) != nil {
            flush()
            current.append(line)
            flush()
        } else if trimmed.isEmpty {
            // A list continues across a blank line.
            if let last = current.last?.trimmingCharacters(in: .whitespaces),
               last.hasPrefix("- ") || last.hasPrefix("* ") || last.first?.isNumber == true {
                continue
            }
            flush()
        } else {
            current.append(line)
        }
    }
    flush()
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

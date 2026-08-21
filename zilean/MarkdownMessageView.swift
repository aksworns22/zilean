import SwiftUI

struct MarkdownMessageView: View {
    let source: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .tint(.accentColor)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inlineText(text)
                .font(headingFont(for: level))

        case let .paragraph(text):
            inlineText(text)
                .font(.body)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", text: item)
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", text: item)
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)

                inlineText(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

        case let .code(language, content):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal) {
                    Text(content)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08))
            }
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(MarkdownInlineParser.attributed(source))
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body.monospacedDigit())
                .frame(minWidth: 18, alignment: .trailing)

            inlineText(text)
                .font(.body)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            .title3.weight(.bold)
        case 2:
            .headline
        default:
            .subheadline.weight(.semibold)
        }
    }
}

enum MarkdownInlineParser {
    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        for run in attributed.runs {
            let range = run.range

            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[range].font = .system(.body, design: .monospaced)
                attributed[range].backgroundColor = Color.primary.opacity(0.08)
            }

            if run.link != nil {
                attributed[range].foregroundColor = .accentColor
                attributed[range].underlineStyle = .single
            }
        }

        return attributed
    }
}

nonisolated enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, content: String)
}

nonisolated enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]

            if let fence = fenceStart(in: line) {
                flushParagraph()
                index += 1
                var codeLines: [String] = []

                while index < lines.count, !isFenceEnd(lines[index], marker: fence.marker) {
                    codeLines.append(lines[index])
                    index += 1
                }

                if index < lines.count {
                    index += 1
                }

                blocks.append(
                    .code(language: fence.language, content: codeLines.joined(separator: "\n"))
                )
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if unorderedListItem(in: line) != nil {
                flushParagraph()
                var items: [String] = []

                while index < lines.count, let item = unorderedListItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }

                blocks.append(.unorderedList(items))
                continue
            }

            if orderedListItem(in: line) != nil {
                flushParagraph()
                var items: [String] = []

                while index < lines.count, let item = orderedListItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }

                blocks.append(.orderedList(items))
                continue
            }

            if quoteLine(in: line) != nil {
                flushParagraph()
                var quotedLines: [String] = []

                while index < lines.count, let quotedLine = quoteLine(in: lines[index]) {
                    quotedLines.append(quotedLine)
                    index += 1
                }

                blocks.append(.quote(quotedLines.joined(separator: "\n")))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }

        let contentStart = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard contentStart < trimmed.endIndex, trimmed[contentStart].isWhitespace else { return nil }

        let text = trimmed[contentStart...].drop(while: \.isWhitespace)
        return (level, String(text))
    }

    private static func unorderedListItem(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, "-*+".contains(marker) else { return nil }
        let contentStart = trimmed.index(after: trimmed.startIndex)
        guard contentStart < trimmed.endIndex, trimmed[contentStart].isWhitespace else { return nil }
        return String(trimmed[contentStart...].drop(while: \.isWhitespace))
    }

    private static func orderedListItem(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }

        var contentStart = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard contentStart < trimmed.endIndex, trimmed[contentStart] == "." else { return nil }
        contentStart = trimmed.index(after: contentStart)
        guard contentStart < trimmed.endIndex, trimmed[contentStart].isWhitespace else { return nil }
        return String(trimmed[contentStart...].drop(while: \.isWhitespace))
    }

    private static func quoteLine(in line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func fenceStart(in line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker: String

        if trimmed.hasPrefix("```") {
            marker = "```"
        } else if trimmed.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }

        let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : language)
    }

    private static func isFenceEnd(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }
}

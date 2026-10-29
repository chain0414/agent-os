import Foundation

/// A presentation-only interpretation of complete, known automation envelopes.
/// Raw timeline values remain available for exports and the conversation menu.
nonisolated enum TimelineAutomationPresentation: Equatable {
    case instruction(String, String, Date?)
    case silent(String, String)
    case notification(String, String)

    var automationID: String {
        switch self { case let .instruction(id, _, _), let .silent(id, _), let .notification(id, _): id }
    }

    /// Automation decisions govern delivery notifications, not transcript visibility.
    /// Preserve the user's instruction and the assistant's response; only strip
    /// the complete control envelope from the presentation.
    var bodyText: String {
        switch self {
        case let .instruction(_, text, _), let .silent(_, text), let .notification(_, text): text
        }
    }

    static func classify(_ item: V2TimelineItem) -> Self? {
        guard item.type == .message, item.status == .done,
              case let .message(content) = item.content, content.attachments.isEmpty else { return nil }
        if item.role == .user, item.raw["content"]?["automation"]?["kind"] == .string("schedule") {
            let marker = item.raw["content"]?["automation"]
            var timestamp: Date?
            if case let .number(milliseconds) = marker?["timestampMs"], milliseconds.isFinite, milliseconds >= 0 {
                timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
            }
            guard !item.displayText.isEmpty else { return nil }
            return .instruction(item.id, item.displayText, timestamp)
        }
        let text = item.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("<heartbeat>"), text.hasSuffix("</heartbeat>") else { return nil }
        let body = text.dropFirst("<heartbeat>".count).dropLast("</heartbeat>".count)
        guard let fields = fields(body), let id = fields["automation_id"],
              !id.isEmpty, !id.contains(where: { $0 == "<" || $0 == ">" || $0.isNewline }) else { return nil }
        switch item.role {
        case .user:
            guard Set(fields.keys).isSubset(of: ["automation_id", "current_time_iso", "instructions"]),
                  let instructions = fields["instructions"], !instructions.isEmpty else { return nil }
            return .instruction(id, instructions, V2Timestamp.date(fields["current_time_iso"]))
        case .assistant:
            guard Set(fields.keys) == ["automation_id", "decision", "message"],
                  let message = fields["message"], !message.isEmpty else { return nil }
            switch fields["decision"] {
            case "DONT_NOTIFY": return .silent(id, message)
            case "NOTIFY": return .notification(id, message)
            default: return nil
            }
        default: return nil
        }
    }

    /// These control envelopes carry literal Markdown, so they are not general
    /// XML documents (instructions can contain unescaped '&' or code). Accept
    /// only flat, known fields; no attributes, duplicate keys or trailing text.
    private static func fields(_ body: Substring) -> [String: String]? {
        var rest = body
        var result: [String: String] = [:]
        let known: Set<String> = ["automation_id", "current_time_iso", "instructions", "decision", "message"]
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.isEmpty { return result }
            guard rest.first == "<", let end = rest.firstIndex(of: ">") else { return nil }
            let key = String(rest[rest.index(after: rest.startIndex)..<end])
            guard known.contains(key), result[key] == nil else { return nil }
            rest = rest[rest.index(after: end)...]
            guard let close = rest.range(of: "</\(key)>") else { return nil }
            result[key] = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[close.upperBound...]
        }
    }
}

nonisolated struct TimelineAutomationInstruction: Equatable {
    let text: String
    let timestamp: Date?
}

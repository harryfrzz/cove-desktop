import Foundation
import SwiftData

/// Which side of the conversation a turn came from. Stored as a raw string for
/// the same reason `ShelfItemKind` is: the column outlives a renamed case.
enum ChatRole: String, Codable, CaseIterable {
    case user
    case assistant
}

/// One conversation with Cove, kept on disk so asking something is not a thing
/// you lose by dismissing the island. Threads are the unit of history: "New
/// conversation" starts another rather than erasing this one.
@Model
final class ChatThread {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// Bumped on every turn, so "the conversation you were last in" is a sort
    /// over stored data rather than a flag two surfaces could disagree about.
    var updatedAt: Date
    /// The first question asked, truncated. History lists what was asked; a
    /// date alone makes every row look the same.
    var title: String
    @Relationship(deleteRule: .cascade, inverse: \ChatTurn.thread)
    var turns: [ChatTurn]

    init(id: UUID = UUID(), createdAt: Date = .now, title: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.title = title
        self.turns = []
    }

    /// SwiftData makes no promise about relationship order, so every reader
    /// sorts rather than trusting the array.
    var orderedTurns: [ChatTurn] {
        turns.sorted { $0.createdAt < $1.createdAt }
    }

    /// Appends a turn and moves the thread to the top of history. Only the
    /// `turns` side is set — the inverse fills `thread` in, and doing both
    /// would register the same object twice.
    @discardableResult
    func append(
        role: ChatRole,
        text: String,
        links: [UUID] = [],
        at date: Date = .now
    ) -> ChatTurn {
        let turn = ChatTurn(role: role, text: text, links: links, createdAt: date)
        turns.append(turn)
        updatedAt = date
        if title.isEmpty, role == .user {
            title = Self.titleText(from: text)
        }
        return turn
    }

    static func titleText(from question: String) -> String {
        let cleaned = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 44 else { return cleaned }
        return cleaned.prefix(44).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@Model
final class ChatTurn {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var roleRawValue: String
    var text: String
    /// The captures Cove held out with this turn, by shelf id.
    ///
    /// Stored rather than re-derived, because there is nothing left to derive
    /// them from: an answer no longer types out addresses, so "the two YouTube
    /// links" is only a sentence unless the ids came with it. Kept as strings
    /// for the same reason the role is — the column outlives what is written in
    /// it, and a row whose capture has since been deleted simply resolves to
    /// nothing rather than to a broken reference.
    /// Defaulted, and that is what makes this a lightweight migration rather
    /// than a schema version: every turn already in the store gets an empty
    /// list, which is the truth about them — they were answered before Cove
    /// offered anything.
    var linkedItemIDRawValues: [String] = []
    var thread: ChatThread?

    var role: ChatRole {
        get { ChatRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    var linkedItemIDs: [UUID] {
        get { linkedItemIDRawValues.compactMap(UUID.init(uuidString:)) }
        set { linkedItemIDRawValues = newValue.map(\.uuidString) }
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        links: [UUID] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.createdAt = createdAt
        self.roleRawValue = role.rawValue
        self.text = text
        self.linkedItemIDRawValues = links.map(\.uuidString)
    }
}

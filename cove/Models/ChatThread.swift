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
    func append(role: ChatRole, text: String, at date: Date = .now) -> ChatTurn {
        let turn = ChatTurn(role: role, text: text, createdAt: date)
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
    var thread: ChatThread?

    var role: ChatRole {
        get { ChatRole(rawValue: roleRawValue) ?? .assistant }
        set { roleRawValue = newValue.rawValue }
    }

    init(id: UUID = UUID(), role: ChatRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        self.roleRawValue = role.rawValue
        self.text = text
    }
}

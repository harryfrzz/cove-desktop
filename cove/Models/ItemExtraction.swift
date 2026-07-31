import Foundation

/// What the enrichment step of the pipeline produces. Persisted on `ShelfItem`
/// (extraction as JSON) so the UI can surface typed fields.
struct ItemEnrichment: Sendable {
    var summary: String?
    var tags: [String]
    var extraction: ItemExtraction?
}

/// Flat, storage-facing extraction record (Codable for `extractionJSON`).
///
/// Nothing fills the receipt/ticket/event fields yet — the language model that
/// reads them is deliberately out of this phase. The shape is settled now so
/// Wallet and Upcoming can be built against it, and so turning the model on
/// later is a pipeline change rather than a schema migration.
struct ItemExtraction: Codable, Sendable, Equatable {
    var category: String

    // Receipt
    var merchant: String?
    var total: String?
    var currency: String?
    var date: String?
    var expenseCategory: String?

    // Event
    var eventTitle: String?
    var eventStart: String?
    var eventEnd: String?
    var eventLocation: String?

    // Link / note
    var shortTitle: String?

    // Ticket
    var ticketType: String?
    var ticketTitle: String?
    var venueOrOperator: String?
    var ticketDateTime: String?
    var seatDetails: String?
    var referenceNumber: String?
    var price: String?
}

extension ItemExtraction {
    /// Whether the extracted fields actually back up the category.
    ///
    /// A classifier picks from a fixed list, so anything that is *none* of them
    /// still comes back wearing one of the labels — a certificate reads as an
    /// "event" because it has a name and a date. The label alone is therefore
    /// not evidence. The pass-specific fields are: a seat, a booking reference,
    /// a total.
    var describesAPass: Bool {
        switch category {
        // A receipt without an amount paid is not a receipt.
        case "receipt":
            Self.hasValue(total)
        // What makes a ticket is where you sit and what you booked under.
        case "ticket":
            Self.hasValue(seatDetails)
                || Self.hasValue(referenceNumber)
                || Self.hasValue(price)
        // A date alone is the weakest possible signal; a venue alongside it
        // separates something you attend from something you were awarded.
        case "event":
            Self.hasValue(eventStart) && Self.hasValue(eventLocation)
        default:
            false
        }
    }

    private static func hasValue(_ field: String?) -> Bool {
        guard let field else { return false }
        return !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Storage helpers

extension ShelfItem {
    var extraction: ItemExtraction? {
        get {
            guard let extractionJSON, let data = extractionJSON.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(ItemExtraction.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                extractionJSON = nil
                return
            }
            extractionJSON = String(decoding: data, as: UTF8.self)
        }
    }

    /// Extraction categories that describe an actual pass.
    private static let passCategories: Set<String> = ["receipt", "event", "ticket"]

    /// Whether this item belongs in the Wallet.
    ///
    /// Membership is earned by a structured extraction or by an explicit pin,
    /// never inferred from a loose similarity match — that is what put plain
    /// photos in the wallet dressed as tickets, with no seat, time, or total to
    /// show.
    var isWalletPass: Bool {
        guard processingState == .ready else { return false }
        if isInWallet { return true }
        guard let extraction, Self.passCategories.contains(extraction.category) else {
            return false
        }
        return extraction.describesAPass
    }
}

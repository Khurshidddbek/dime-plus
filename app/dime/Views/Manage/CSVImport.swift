//
//  CSVImport.swift
//  dime
//
//  App target only. Everything the import screen needs that is not UI: reading a file into
//  a table, guessing columns and the date format, and turning rows into drafts. Nothing
//  here writes to the store; the screen validates first and then does one bulk insert.
//

import CoreData
import Foundation

/// A file read into rows of equal width.
struct ImportTable {
    var header: [String]?
    var rows: [[String]]
    /// Line number in the file of `rows[0]` (1-based), for messages.
    var firstLine: Int
    var isLegacyDimeExport: Bool

    var columnCount: Int {
        rows.first?.count ?? 0
    }

    func column(_ index: Int) -> [String] {
        rows.map { index < $0.count ? $0[index] : "" }
    }
}

struct ImportMapping: Equatable {
    var category: Int
    var note: Int
    var date: Int
    var amount: Int
    var type: Int?
    var id: Int?
}

enum ImportSkipReason: Hashable {
    case missingColumns
    case badDate
    case badAmount
    case zeroAmount
    case tooLarge
    case noCategory
    case duplicate

    var text: String {
        switch self {
        case .missingColumns:
            return String(localized: "not enough columns")
        case .badDate:
            return String(localized: "date not recognised")
        case .badAmount:
            return String(localized: "amount not recognised")
        case .zeroAmount:
            return String(localized: "amount is zero")
        case .tooLarge:
            return String(localized: "amount is too large")
        case .noCategory:
            return String(localized: "category not linked")
        case .duplicate:
            return String(localized: "already in the app")
        }
    }
}

struct ImportIssue: Identifiable, Hashable {
    let line: Int
    let reason: ImportSkipReason

    var id: Int { line }
}

struct ImportCategoryLink {
    let id: UUID
    let name: String
    let income: Bool
}

struct ImportPlan {
    var drafts: [TransactionDraft] = []
    var issues: [ImportIssue] = []

    var readyCount: Int { drafts.count }
    var skippedCount: Int { issues.count }
    var duplicateCount: Int { issues.filter { $0.reason == .duplicate }.count }
}

/// Parses the date column with one fixed format. POSIX locale, so the 12/24 hour setting
/// of the phone cannot break "HH".
final class ImportDateParser {
    static let candidates = [
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "dd.MM.yyyy HH:mm:ss",
        "dd/MM/yyyy HH:mm:ss",
        "MM/dd/yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "dd.MM.yyyy HH:mm",
        "dd/MM/yyyy HH:mm",
        "MM/dd/yyyy HH:mm",
        "yyyy-MM-dd",
        "dd.MM.yyyy",
        "dd/MM/yyyy",
        "MM/dd/yyyy",
        "dd-MM-yyyy",
        "MM-dd-yyyy",
        "yyyy/MM/dd",
        "dd.MM.yy",
        "yyyyMMdd",
        "d MMM yyyy",
        "MMM d, yyyy"
    ]

    let format: String
    private let formatter: DateFormatter
    private let calendar = Calendar(identifier: .gregorian)

    init(format: String) {
        self.format = format
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.isLenient = false
        formatter.dateFormat = format
    }

    func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, let date = formatter.date(from: trimmed) else {
            return nil
        }

        // "13.11.26" read with a four-digit year pattern gives the year 26.
        let year = calendar.component(.year, from: date)

        guard year >= 1990, year <= 2100 else {
            return nil
        }

        return date
    }

    /// The candidate that reads the most samples; the more specific one wins a tie.
    static func deduceFormat(from samples: [String]) -> String? {
        let values = samples.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(300)

        guard !values.isEmpty else {
            return nil
        }

        var best: String?
        var bestCount = 0

        for candidate in candidates {
            let parser = ImportDateParser(format: candidate)
            let count = values.filter { parser.date(from: $0) != nil }.count

            if count > bestCount {
                best = candidate
                bestCount = count
            }
        }

        return best
    }
}

enum ImportAmount {
    /// "1234.50", "-12", "+7.5": read as written, no guessing.
    private static func plain(_ text: String) -> Double? {
        var digits = 0
        var dots = 0

        for (index, character) in text.enumerated() {
            if character.isASCII, character.isNumber {
                digits += 1
            } else if character == "." {
                dots += 1
            } else if (character == "-" || character == "+") && index == 0 {
                continue
            } else {
                return nil
            }
        }

        guard digits > 0, dots <= 1 else {
            return nil
        }

        return Double(text)
    }

    /// Signed value of one cell. Plain decimals are exact; everything else ("35 880 000",
    /// "1.250,50", "12 000 UZS", "(500)") goes through the tolerant money parser.
    static func parse(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            return nil
        }

        var negative = false

        // Accounting style negative.
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }

        let value: Double?

        if let exact = plain(text) {
            value = exact
        } else {
            value = MoneyFormat.parse(text)
        }

        guard let parsed = value, parsed.isFinite else {
            return nil
        }

        return negative ? -abs(parsed) : parsed
    }
}

enum CSVImport {
    // MARK: reading a file

    static func readTable(from data: Data) -> ImportTable? {
        guard let text = CSVCodec.decode(data) else {
            return nil
        }

        if CSVCodec.isLegacyDimeExport(text) {
            let rows = CSVCodec.padded(CSVCodec.parseLegacyDime(text), to: 5)

            guard !rows.isEmpty else {
                return nil
            }

            return ImportTable(header: CSVCodec.legacyHeader.components(separatedBy: ","), rows: rows, firstLine: 2, isLegacyDimeExport: true)
        }

        let delimiter = CSVCodec.detectDelimiter(text)
        var rows = CSVCodec.parse(text, delimiter: delimiter)

        guard !rows.isEmpty else {
            return nil
        }

        var header: [String]?
        var firstLine = 1

        // A first row without a single digit is a header.
        if !rows[0].contains(where: { $0.containsDigits }) {
            header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            firstLine = 2
        }

        guard !rows.isEmpty else {
            return nil
        }

        let width = max(rows.map { $0.count }.max() ?? 0, header?.count ?? 0)
        rows = CSVCodec.padded(rows, to: width)

        if let unwrappedHeader = header, unwrappedHeader.count < width {
            header = unwrappedHeader + Array(repeating: "", count: width - unwrappedHeader.count)
        }

        return ImportTable(header: header, rows: rows, firstLine: firstLine, isLegacyDimeExport: false)
    }

    // MARK: column guessing

    private static let dateNames: Set<String> = ["date", "datetime", "date and time", "time", "\u{434}\u{430}\u{442}\u{430}"]
    private static let noteNames: Set<String> = ["note", "notes", "description", "memo", "comment", "\u{437}\u{430}\u{43C}\u{435}\u{442}\u{43A}\u{430}", "\u{43E}\u{43F}\u{438}\u{441}\u{430}\u{43D}\u{438}\u{435}", "\u{43A}\u{43E}\u{43C}\u{43C}\u{435}\u{43D}\u{442}\u{430}\u{440}\u{438}\u{439}"]
    private static let amountNames: Set<String> = ["amount", "sum", "value", "price", "total", "\u{441}\u{443}\u{43C}\u{43C}\u{430}"]
    private static let categoryNames: Set<String> = ["category", "\u{43A}\u{430}\u{442}\u{435}\u{433}\u{43E}\u{440}\u{438}\u{44F}"]
    private static let typeNames: Set<String> = ["type", "\u{442}\u{438}\u{43F}"]
    private static let idNames: Set<String> = ["id", "uuid"]

    /// Columns found by header name (Dime's own export and look-alikes). nil when one of
    /// the four required columns is missing.
    static func mapping(forHeader header: [String]?) -> ImportMapping? {
        guard let header = header else {
            return nil
        }

        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        func index(in set: Set<String>) -> Int? {
            names.firstIndex { set.contains($0) }
        }

        guard let date = index(in: dateNames), let note = index(in: noteNames),
              let amount = index(in: amountNames), let category = index(in: categoryNames)
        else {
            return nil
        }

        guard Set([date, note, amount, category]).count == 4 else {
            return nil
        }

        return ImportMapping(category: category, note: note, date: date, amount: amount, type: index(in: typeNames), id: index(in: idNames))
    }

    /// The optional "Type" and "ID" columns, found by header name.
    static func optionalColumns(forHeader header: [String]?) -> (type: Int?, id: Int?) {
        guard let header = header else {
            return (nil, nil)
        }

        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        return (names.firstIndex { typeNames.contains($0) }, names.firstIndex { idNames.contains($0) })
    }

    /// Income / expense from a "Type" cell. nil when the cell says neither.
    static func incomeFlag(_ text: String) -> Bool? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if ["income", "+", "credit", "\u{434}\u{43E}\u{445}\u{43E}\u{434}"].contains(value) {
            return true
        }

        if ["expense", "-", "debit", "\u{440}\u{430}\u{441}\u{445}\u{43E}\u{434}"].contains(value) {
            return false
        }

        return nil
    }

    /// Key that ties a row to its entry in the category linking step. With a type column
    /// "Other" as income and "Other" as expense are two different entries.
    static func categoryKey(for row: [String], mapping: ImportMapping) -> String {
        let value = mapping.category < row.count ? row[mapping.category].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        return categoryKey(value: value, income: typeHint(for: row, mapping: mapping))
    }

    static func categoryKey(value: String, income: Bool?) -> String {
        guard let income = income else {
            return "?|" + value
        }

        return (income ? "1|" : "0|") + value
    }

    static func typeHint(for row: [String], mapping: ImportMapping) -> Bool? {
        guard let typeIndex = mapping.type, typeIndex < row.count else {
            return nil
        }

        return incomeFlag(row[typeIndex])
    }

    // MARK: duplicates

    /// Identity of a row for the duplicate check: second, amount in cents, direction, category, note.
    static func signature(date: Date, amount: Double, income: Bool, categoryID: UUID?, note: String) -> String {
        // Whole seconds, rounded down: that is what the text form of a date in an export keeps.
        let seconds = Int(date.timeIntervalSince1970.rounded(.down))
        let cents = Int((amount * 100).rounded())

        return "\(seconds)|\(cents)|\(income ? 1 : 0)|\(categoryID?.uuidString ?? "")|\(note)"
    }

    /// How many rows with each signature the store already holds between the two dates,
    /// plus every id in that range. Main thread (view context).
    static func existingRows(in dataController: DataController, from start: Date, to end: Date) -> (signatures: [String: Int], ids: Set<UUID>) {
        let request: NSFetchRequest<Transaction> = Transaction.fetchRequest()
        request.predicate = NSPredicate(format: "date >= %@ AND date <= %@", start.addingTimeInterval(-1) as NSDate, end.addingTimeInterval(1) as NSDate)

        var signatures = [String: Int]()
        var ids = Set<UUID>()

        for transaction in dataController.results(for: request) {
            guard let date = transaction.date else {
                continue
            }

            if let id = transaction.id {
                ids.insert(id)
            }

            let key = signature(date: date, amount: transaction.amount, income: transaction.income, categoryID: transaction.category?.id, note: transaction.note ?? "")
            signatures[key, default: 0] += 1
        }

        return (signatures, ids)
    }

    // MARK: planning

    /// Turns every row into a draft or into a skip with a reason. Pure: no store access.
    /// `links` maps `categoryKey` to the category chosen for it. `existing` and
    /// `existingIDs` come from `existingRows`; pass empty values to keep duplicates.
    static func plan(table: ImportTable, mapping: ImportMapping, dateParser: ImportDateParser,
                     links: [String: ImportCategoryLink], existing: [String: Int] = [:],
                     existingIDs: Set<UUID> = []) -> ImportPlan
    {
        var plan = ImportPlan()
        var remaining = existing
        var usedIDs = existingIDs
        let required = max(mapping.category, mapping.note, mapping.date, mapping.amount)

        for (offset, row) in table.rows.enumerated() {
            let line = table.firstLine + offset

            guard row.count > required else {
                plan.issues.append(ImportIssue(line: line, reason: .missingColumns))
                continue
            }

            guard let date = dateParser.date(from: row[mapping.date]) else {
                plan.issues.append(ImportIssue(line: line, reason: .badDate))
                continue
            }

            guard let signed = ImportAmount.parse(row[mapping.amount]) else {
                plan.issues.append(ImportIssue(line: line, reason: .badAmount))
                continue
            }

            let amount = MoneyFormat.round(abs(signed), fractionDigits: 2)

            guard amount > 0 else {
                plan.issues.append(ImportIssue(line: line, reason: .zeroAmount))
                continue
            }

            guard MoneyFormat.isWithinLimit(amount) else {
                plan.issues.append(ImportIssue(line: line, reason: .tooLarge))
                continue
            }

            guard let link = links[categoryKey(for: row, mapping: mapping)] else {
                plan.issues.append(ImportIssue(line: line, reason: .noCategory))
                continue
            }

            let note = row[mapping.note].trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty note is stored as the category name, the same as in the entry screen.
            let storedNote = note.isEmpty ? link.name : note

            var draftID = UUID()

            if let idIndex = mapping.id, idIndex < row.count,
               let fileID = UUID(uuidString: row[idIndex].trimmingCharacters(in: .whitespacesAndNewlines))
            {
                // Our own export carries ids: a row that is still in the store is not added twice.
                if usedIDs.contains(fileID) {
                    plan.issues.append(ImportIssue(line: line, reason: .duplicate))
                    continue
                }

                draftID = fileID
            }

            let key = signature(date: date, amount: amount, income: link.income, categoryID: link.id, note: storedNote)

            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1
                plan.issues.append(ImportIssue(line: line, reason: .duplicate))
                continue
            }

            usedIDs.insert(draftID)
            plan.drafts.append(TransactionDraft(note: note, categoryID: link.id, income: link.income, amount: amount, date: date, id: draftID))
        }

        return plan
    }
}

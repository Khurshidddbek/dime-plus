//
//  DataExport.swift
//  dime
//
//  App target only. CSV export (RFC 4180, readable by the import screen and by
//  spreadsheets) and a JSON export that is a regular backup file.
//

import CoreData
import Foundation

enum DataExport {
    /// The first five names are the ones the original app wrote, so old habits and the
    /// import screen keep working. The rest is extra.
    static let csvHeader = ["Date", "Note", "Amount", "Category", "Type", "Currency", "Recurring", "ID"]

    private static func recurringText(type: Int16, coefficient: Int16) -> String {
        let unit: String

        switch type {
        case 1:
            unit = "daily"
        case 2:
            unit = "weekly"
        case 3:
            unit = "monthly"
        default:
            return ""
        }

        return "\(unit) x\(max(1, Int(coefficient)))"
    }

    /// The whole Log as CSV text. Dates are local time with the UTC offset
    /// ("2026-11-13T19:30:00+05:00"), amounts are plain decimals with a dot.
    /// Main thread (reads the view context).
    static func csvText(dataController: DataController, includeBOM: Bool = true) -> (text: String, count: Int) {
        let transactions = dataController.results(for: dataController.fetchRequestForExport())
        let currency = MoneySettings.current.code

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        dateFormatter.timeZone = TimeZone.current

        let posix = Locale(identifier: "en_US_POSIX")
        var lines = [String]()
        lines.reserveCapacity(transactions.count + 1)
        lines.append(CSVCodec.line(csvHeader))

        for transaction in transactions {
            guard let date = transaction.date else {
                continue
            }

            lines.append(CSVCodec.line([
                dateFormatter.string(from: date),
                transaction.note ?? "",
                String(format: "%.2f", locale: posix, transaction.amount),
                transaction.category?.name ?? "",
                transaction.income ? "Income" : "Expense",
                currency,
                recurringText(type: transaction.recurringType, coefficient: transaction.recurringCoefficient),
                transaction.id?.uuidString ?? ""
            ]))
        }

        // The BOM makes Excel on Windows read Cyrillic notes correctly.
        let text = (includeBOM ? CSVCodec.byteOrderMark : "") + lines.joined(separator: "\r\n") + "\r\n"

        return (text, lines.count - 1)
    }

    /// Writes the CSV into the temporary folder as "Dime-yyyy-MM-dd.csv" and returns the file.
    static func writeCSV(dataController: DataController, includeBOM: Bool = true) throws -> (url: URL, count: Int) {
        let export = csvText(dataController: dataController, includeBOM: includeBOM)

        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyy-MM-dd"

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dime-\(nameFormatter.string(from: Date())).csv")

        do {
            try export.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DiagnosticsLog.shared.log("export", "csv FAILED \(DataController.describe(error as NSError))")
            throw error
        }

        DiagnosticsLog.shared.log("export", "csv written, \(export.count) transaction(s)")

        return (url, export.count)
    }

    /// A lossless JSON file with everything (categories, budgets, templates, transactions).
    /// It is a normal backup tagged "export", so it can be restored in Settings > Backups.
    /// `completion` runs on the main queue.
    static func writeJSON(completion: @escaping (Result<URL, Error>) -> Void) {
        BackupStore.shared.backupNowAsync(tag: "export") { result in
            switch result {
            case let .success(info):
                completion(.success(BackupStore.shared.shareURL(for: info)))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }
}

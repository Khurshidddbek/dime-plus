//
//  FilteredInsightsView.swift
//  dime
//

import CoreData
import SwiftUI

// Day-sectioned transactions of one week (type 1), month (type 2) or year (any other type),
// starting at startDate. Kept with its original initialiser for the Log tab filters.
struct FilteredInsightsView: View {
    @SectionedFetchRequest<Date?, Transaction> private var transactions: SectionedFetchResults<Date?, Transaction>

    var body: some View {
        VStack(spacing: 30) {
            if transactions.count == 0 {
                NoResultsView(fullscreen: false)
            }

            ListView(transactions: _transactions)
        }
        .frame(maxHeight: .infinity)
    }

    init(startDate: Date, income: Bool? = nil, type: Int) {
        var calendar = Calendar(identifier: .gregorian)
        let weekday = UserDefaults.appGroup.integer(forKey: "firstWeekday")
        // Unset or invalid: follow the device region (Monday in ru / uz), like the system calendar.
        calendar.firstWeekday = (1 ... 7).contains(weekday) ? weekday : Calendar.current.firstWeekday
        calendar.minimumDaysInFirstWeek = 4

        let next: Date
        if type == 1 {
            next = calendar.date(byAdding: .day, value: 7, to: startDate) ?? startDate
        } else if type == 2 {
            next = calendar.date(byAdding: .month, value: 1, to: startDate) ?? startDate
        } else {
            next = calendar.date(byAdding: .year, value: 1, to: startDate) ?? startDate
        }

        // Same cutoff as every total: upcoming rows start tomorrow. It is also stable for a whole
        // day, so the request is not rebuilt with a new "now" on every parent render.
        let end = min(next, LogCutoff.startOfTomorrow())

        var predicates: [NSPredicate] = [
            NSPredicate(format: "%K >= %@", #keyPath(Transaction.date), startDate as NSDate),
            NSPredicate(format: "%K < %@", #keyPath(Transaction.date), end as NSDate)
        ]
        if let income {
            predicates.append(NSPredicate(format: "income == %@", NSNumber(value: income)))
        }

        _transactions = SectionedFetchRequest<Date?, Transaction>(sectionIdentifier: \.day, sortDescriptors: [
            SortDescriptor(\.day, order: .reverse),
            SortDescriptor(\.date, order: .reverse)
        ], predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates))
    }
}

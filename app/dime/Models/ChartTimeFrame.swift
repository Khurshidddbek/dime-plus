//
//  ChartTimeFrame.swift
//  Bonsai
//
//  Created by Rafael Soh on 3/6/22.
//

import Foundation

// Raw values double as the localisation keys "week", "month", "year".
enum ChartTimeFrame: String, CaseIterable {
    case week, month, year
}

extension ChartTimeFrame {
    static let storageKey = "chartTimeFrame"

    // The setting has always been stored as Int 1/2/3.
    var storedValue: Int {
        switch self {
        case .week: return 1
        case .month: return 2
        case .year: return 3
        }
    }

    init(storedValue: Int) {
        switch storedValue {
        case 2: self = .month
        case 3: self = .year
        default: self = .week
        }
    }
}

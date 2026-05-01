//
//  Item.swift
//  klaw
//
//  Created by zhubby on 2026/5/1.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

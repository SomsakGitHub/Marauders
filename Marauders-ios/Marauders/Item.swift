//
//  Item.swift
//  Marauders
//
//  Created by tiscomacnb2486 on 7/10/2569 BE.
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

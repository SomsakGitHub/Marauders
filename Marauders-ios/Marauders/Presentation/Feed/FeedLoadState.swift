//
//  FeedLoadState.swift
//  Marauders
//

import Foundation

enum FeedLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

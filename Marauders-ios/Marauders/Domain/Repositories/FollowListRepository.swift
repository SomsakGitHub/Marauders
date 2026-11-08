//
//  FollowListRepository.swift
//  Marauders
//

import Foundation

protocol FollowListRepository: Sendable {
    /// One page of the accounts that follow `handle` (or that it follows), newest first, as the signed-in viewer.
    /// `cursor` is the previous page's `nextCursor`, nil for the first page.
    func fetchList(handle: String, kind: FollowListKind, cursor: String?, limit: Int) async throws -> FollowListPage
}

//
//  FeedAPIClient.swift
//  Marauders
//

import Foundation

struct FeedAPIResponse: Decodable, Sendable {
    let items: [FeedVideo]
}

enum FeedAPIError: LocalizedError {
    case invalidLimit
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "จำนวนคลิปที่ขอไม่ถูกต้อง"
        case .invalidResponse:
            return "รูปแบบข้อมูลจาก API ไม่ถูกต้อง"
        case .serverError(let code):
            return "เซิร์ฟเวอร์ตอบกลับด้วยรหัส \(code)"
        }
    }
}

struct FeedAPIClient: Sendable {
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchFeed(limit: Int = 20) async throws -> [FeedVideo] {
        let requestURL = try APIConfiguration.feedRequestURL(limit: limit)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedAPIError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            throw FeedAPIError.serverError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(FeedAPIResponse.self, from: data)

        for item in decoded.items {
            guard item.streamURL.scheme?.lowercased() == "https" else {
                throw FeedAPIError.invalidResponse
            }
        }

        return decoded.items
    }
}

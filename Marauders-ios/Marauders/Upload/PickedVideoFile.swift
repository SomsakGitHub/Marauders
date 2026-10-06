//
//  PickedVideoFile.swift
//  Marauders
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PickedVideoFile: Transferable {
    let url: URL
    let contentType: UTType

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mp4" : received.file.pathExtension
            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            let type = UTType(filenameExtension: ext) ?? .mpeg4Movie
            return PickedVideoFile(url: destination, contentType: type)
        }
    }

    var mimeType: String {
        if contentType.conforms(to: .quickTimeMovie) {
            return "video/quicktime"
        }
        return "video/mp4"
    }
}

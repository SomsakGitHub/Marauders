//
//  MultipartBodyWriterMemoryTests.swift
//  MaraudersTests
//

import Darwin
import Foundation
import Testing

@testable import Marauders

/// Shows that copying a clip into an upload body never holds the clip whole in memory.
///
/// A footprint reading is not stable while other suites run in parallel, so this test runs only when asked:
/// `TEST_RUNNER_MEASURE_UPLOAD_MEMORY=1 xcodebuild test ... -only-testing:MaraudersTests/MultipartBodyWriterMemoryTests`
/// (xcodebuild hands the variable to the test process without its `TEST_RUNNER_` prefix). In a normal run it is skipped.
struct MultipartBodyWriterMemoryTests {
    private static let clipSize: UInt64 = 192 * 1024 * 1024
    private static let allowedGrowth: UInt64 = 48 * 1024 * 1024

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEASURE_UPLOAD_MEMORY"] == "1"))
    func aLargeClipIsCopiedWithoutHoldingItWhole() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A sparse file: 192 MiB long, no real bytes written until something reads them.
        let clip = folder.appendingPathComponent("clip.mp4")
        #expect(FileManager.default.createFile(atPath: clip.path, contents: nil))
        let handle = try FileHandle(forWritingTo: clip)
        try handle.truncate(atOffset: Self.clipSize)
        try handle.close()

        let baseline = Self.physicalFootprint()
        let sampler = Task.detached {
            var peak = baseline
            while !Task.isCancelled {
                peak = max(peak, Self.physicalFootprint())
                try? await Task.sleep(for: .milliseconds(2))
            }
            return max(peak, Self.physicalFootprint())
        }

        try await MultipartBodyWriter.write(
            [.fileAt(name: "file", filename: "clip.mp4", mimeType: "video/mp4", url: clip)],
            boundary: "b", to: folder.appendingPathComponent("body.multipart"))

        sampler.cancel()
        let peak = await sampler.value
        let growth = peak > baseline ? peak - baseline : 0
        print("[upload.memory] clip MiB=\(Self.clipSize / 1_048_576) peak growth MiB=\(growth / 1_048_576)")

        #expect(growth < Self.allowedGrowth, "the copy grew the footprint by \(growth / 1_048_576) MiB")
    }

    /// The process's physical footprint in bytes: what the system counts against the app.
    private nonisolated static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

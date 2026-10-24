import Foundation
import AVFoundation
import Speech

// No provider credentials or remote transcription/translation fallback.
enum ThaiDubbingError: LocalizedError {
    case unavailable, permission, unsupported, speechUnclear, failed
    var errorDescription: String? {
        switch self {
        case .unavailable: "เครื่องนี้ยังไม่พร้อมแปลบนอุปกรณ์ กรุณาติดตั้งภาษาอังกฤษและไทย แล้วลองใหม่"
        case .permission: "กรุณาอนุญาตการรู้จำเสียงในการตั้งค่า เพื่อถอดคำพูดจากคลิป"
        case .unsupported: "รุ่นทดลองรองรับคลิปคำพูดอังกฤษไม่เกิน 2 นาทีและ 12 MB"
        case .speechUnclear: "ถอดคำพูดอังกฤษจากคลิปนี้ไม่ได้ ลองคลิปที่มีเสียงพูดชัดเจน หรือฟังเสียงต้นฉบับ"
        case .failed: "แปลเสียงบนเครื่องไม่สำเร็จ กรุณาฟังเสียงต้นฉบับก่อน"
        }
    }
}

/// AVSpeech's audio callback runs off the main actor. File writes and completion
/// are serialized here, with exactly one continuation completion, including cancel.
nonisolated final class NarrationFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var continuation: CheckedContinuation<URL, Error>?
    private let url: URL
    init(url: URL, continuation: CheckedContinuation<URL, Error>) {
        self.url = url; self.continuation = continuation
    }
    func append(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { finishLocked(.failure(ThaiDubbingError.failed)); return }
        if pcm.frameLength == 0 {
            if file != nil { finishLocked(.success(url)) }
            else { finishLocked(.failure(ThaiDubbingError.failed)) }
            return
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved) }
            try file?.write(from: pcm)
        } catch { finishLocked(.failure(error)) }
        _ = continuation
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        finishLocked(.failure(CancellationError()))
    }
    private func finishLocked(_ result: Result<URL, Error>) {
        file = nil
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}

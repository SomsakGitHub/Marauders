import Foundation
import Observation
import AVFoundation
import Speech
@preconcurrency import Translation

@MainActor @Observable
final class ThaiDubbingViewModel {
    private(set) var message: String?
    private(set) var isProcessing = false
    private var generation = 0
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var synthesizer: AVSpeechSynthesizer?
    private var writer: NarrationFileWriter?
    private var directory: URL?
    private var recognitionID: UUID?
    private var recognitionTimeout: Task<Void, Never>?

    /// Called only following an explicit Thai choice. The system may request
    /// language-model downloads, but clip speech/text stays on device.
    func request(sourceURL: URL, session: TranslationSession) async -> URL? {
        useOriginal()
        generation += 1
        let current = generation
        isProcessing = true
        defer { if generation == current { isProcessing = false } }
        do {
            guard await LanguageAvailability(preferredStrategy: .lowLatency).status(from: .init(identifier: "en"), to: .init(identifier: "th")) != .unsupported else { throw ThaiDubbingError.unavailable }
            message = "กำลังเตรียมภาษาอังกฤษและไทยบนเครื่อง…"
            try await session.prepareTranslation()
            try check(current)
            guard let speech = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), speech.supportsOnDeviceRecognition else { throw ThaiDubbingError.unavailable }
            guard let voice = AVSpeechSynthesisVoice(language: "th-TH") else { throw ThaiDubbingError.unavailable }
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status == .authorized) }
            }
            try check(current)
            guard permission else { throw ThaiDubbingError.permission }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thai-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            message = "กำลังเตรียมเสียงจากคลิปบนเครื่อง…"
            let videoURL: URL
            if sourceURL.isFileURL { videoURL = sourceURL }
            else {
                let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ThaiDubbingError.failed }
                guard response.expectedContentLength <= 12 * 1024 * 1024 else { throw ThaiDubbingError.unsupported }
                var data = Data()
                for try await byte in bytes {
                    if data.count % 65536 == 0 { try check(current) }
                    guard data.count < 12 * 1024 * 1024 else { throw ThaiDubbingError.unsupported }
                    data.append(byte)
                }
                videoURL = folder.appendingPathComponent("source.mp4")
                try data.write(to: videoURL)
            }
            try check(current)
            let asset = AVURLAsset(url: videoURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 120 else { throw ThaiDubbingError.unsupported }
            let segments = try await SpeechAudioPreparation.chunks(from: videoURL, directory: folder)
            var words: [String] = []
            for (index, segment) in segments.enumerated() {
                try check(current)
                message = "กำลังถอดคำพูดอังกฤษบนเครื่อง… \(index + 1)/\(segments.count)"
                let text = try await transcribe(segment, recognizer: speech)
                words.append(text)
            }
            let text = words.joined(separator: " ")
            try check(current)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ThaiDubbingError.speechUnclear }
            message = "กำลังแปลเป็นไทยบนเครื่อง…"
            let translated = try await session.translate(text).targetText
            try check(current)
            message = "กำลังสร้างเสียงอ่านไทยบนเครื่อง…"
            let output = folder.appendingPathComponent("thai.caf")
            let synth = AVSpeechSynthesizer()
            synthesizer = synth
            let utterance = AVSpeechUtterance(string: translated)
            utterance.voice = voice
            let result: URL = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let outputWriter = NarrationFileWriter(url: output, continuation: continuation)
                    writer = outputWriter
                    synth.write(utterance) { @Sendable buffer in outputWriter.append(buffer) }
                }
            } onCancel: { Task { @MainActor [weak self] in if self?.generation == current { self?.cancelWork() } } }
            try check(current)
            message = "เสียงอ่านคำแปลไทยบนเครื่อง · จังหวะอาจต่างจากต้นฉบับ"
            return result
        } catch {
            #if DEBUG
            let failure = error as NSError
            print("LOCAL_TRANSLATION_FAILURE domain=\(failure.domain) code=\(failure.code) stage=\(message ?? "unknown")")
            #endif
            guard current == generation else { return nil }
            if !(error is CancellationError) { message = (error as? ThaiDubbingError)?.errorDescription ?? ThaiDubbingError.failed.errorDescription }
            cancelWork()
            cleanFiles()
            return nil
        }
    }
    private func check(_ current: Int) throws {
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
    }
    private func transcribe(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        let operationID = UUID()
        recognitionID = operationID
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recognitionContinuation = continuation
                recognitionTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.recognitionID == operationID else { return }
                    let pending = self.recognitionContinuation
                    self.recognitionContinuation = nil
                    pending?.resume(throwing: ThaiDubbingError.speechUnclear)
                    self.cancelWork()
                }
                recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                    let finalText = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                    let failed = error != nil
                    let speechFailure = error as NSError?
                    let noSpeech = speechFailure?.domain == "kAFAssistantErrorDomain" && speechFailure?.code == 1110
                    #if DEBUG
                    if let failure = error as NSError? { print("LOCAL_SPEECH_FAILURE domain=\(failure.domain) code=\(failure.code) description=\(failure.localizedDescription)") }
                    #endif
                    Task { @MainActor in
                        guard let self, self.recognitionID == operationID, let pending = self.recognitionContinuation else { return }
                        if let finalText { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(returning: finalText) }
                        else if noSpeech { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(returning: "") }
                        else if failed { self.recognitionTimeout?.cancel(); self.recognitionContinuation = nil; pending.resume(throwing: ThaiDubbingError.speechUnclear) }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.recognitionID == operationID { self?.cancelWork() } } }
    }
    private func cancelWork() {
        recognitionID = nil
        recognitionTimeout?.cancel(); recognitionTimeout = nil
        recognitionTask?.cancel(); recognitionTask = nil
        let pending = recognitionContinuation; recognitionContinuation = nil
        pending?.resume(throwing: CancellationError())
        recognizer = nil
        writer?.cancel(); writer = nil
        synthesizer?.stopSpeaking(at: .immediate); synthesizer = nil
    }
    private func cleanFiles() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    func useOriginal() {
        generation += 1
        cancelWork(); cleanFiles()
        isProcessing = false; message = nil
    }
    func unavailableForTesting() {
        useOriginal()
        message = ThaiDubbingError.unavailable.errorDescription
    }
    func playbackFailed() {
        useOriginal()
        message = "เปิดเสียงไทยไม่สำเร็จ กำลังใช้เสียงต้นฉบับ"
    }
}

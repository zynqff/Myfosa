import Foundation
import Speech
import AVFoundation

enum SpeechRecognitionError: LocalizedError {
    case permissionDenied
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Нет доступа к микрофону или распознаванию речи. Разрешите доступ в Настройках устройства."
        case .recognizerUnavailable:
            return "Распознавание речи недоступно для выбранного языка на этом устройстве."
        }
    }
}

/// Голосовой ввод через нативный iOS Speech framework (без сторонних SDK).
/// Слушает микрофон и стримит частичные результаты распознавания в реальном
/// времени, пока не будет вызван `stop()`.
@MainActor
final class SpeechRecognizerService: ObservableObject {
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Запрашивает разрешения на микрофон и распознавание речи, если ещё не даны.
    /// Возвращает true, только если оба разрешения получены.
    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard speechStatus == .authorized else { return false }

        let micGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
        return micGranted
    }

    /// Начинает слушать микрофон на указанном языке, стримя частичные
    /// результаты в `onPartialResult` до вызова `stop()` (или пока
    /// распознаватель сам не сочтёт результат финальным).
    func start(language: String, onPartialResult: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        stop() // на всякий случай гасим предыдущую сессию, если она была активна

        let code = speechLanguageCode(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)), recognizer.isAvailable else {
            onError(SpeechRecognitionError.recognizerUnavailable)
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError(error)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // Офлайн-распознавание, если доступно для этого языка — быстрее и без сети.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            onError(error)
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in onPartialResult(text) }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in self?.stop() }
            }
        }
    }

    /// Останавливает запись и распознавание. Безопасно вызывать даже если
    /// запись уже не идёт.
    func stop() {
        guard isListening else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

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
/// Слушает микрофон и стримит распознанный текст в реальном времени, пока не
/// будет вызван `stop()` — либо пока речь по-настоящему не пропадёт на 10 секунд.
///
/// Важный нюанс: `SFSpeechRecognitionTask` сам завершает очередной "сегмент"
/// распознавания (`isFinal = true`, а часто и сопутствующая "ошибка" вроде
/// "речь не обнаружена") при малейшей паузе в речи — это штатное поведение
/// системы, а НЕ конец диктовки. Поэтому при завершении сегмента мы не
/// останавливаем всю сессию, а тихо открываем следующий сегмент поверх уже
/// накопленного текста (`committedText`), пока пользователь не остановит
/// запись сам или пока не пройдёт `silenceTimeout` секунд полной тишины.
@MainActor
final class SpeechRecognizerService: ObservableObject {
    @Published private(set) var isListening = false

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Текст, накопленный за уже завершившиеся сегменты этой сессии диктовки.
    private var committedText = ""
    /// Последний (промежуточный) текст ТЕКУЩЕГО сегмента. Нужен, чтобы при
    /// паузе не потерять сказанное: сегмент может закончиться ошибкой «речь не
    /// обнаружена» без isFinal — тогда этот текст нигде больше не фиксировался,
    /// и новый сегмент начинал с чистого листа (весь текст «слетал»).
    private var lastSegmentText = ""
    private var onPartialResult: ((String) -> Void)?

    /// Растёт на каждый новый сегмент — колбэки от уже отменённого
    /// (устаревшего) сегмента по этому счётчику отбрасываются, чтобы не
    /// словить гонку между "старым" cancel() и уже открытым новым сегментом.
    private var segmentID = 0

    private var silenceTask: Task<Void, Never>?
    private static let silenceTimeout: Duration = .seconds(10)

    /// Защита от «горячего» цикла: если распознаватель стабильно падает сразу
    /// после старта сегмента (например, нет модели языка и нет сети), мы раньше
    /// бесконечно открывали новые сегменты без пауз и без единого сообщения
    /// пользователю. Считаем подряд идущие мгновенные сбои и после порога
    /// честно останавливаемся с ошибкой.
    private var onError: ((Error) -> Void)?
    private var segmentStartedAt = Date()
    private var fastFailures = 0
    private static let maxFastFailures = 5

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

    /// Начинает слушать микрофон на указанном языке и стримить распознанный
    /// текст в `onPartialResult`, продолжая через короткие паузы речи.
    func start(language: String, onPartialResult: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        stop() // на всякий случай гасим предыдущую сессию, если она была активна
        committedText = ""
        lastSegmentText = ""
        fastFailures = 0
        self.onPartialResult = onPartialResult
        self.onError = onError

        let code = speechLanguageCode(for: language)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)), recognizer.isAvailable else {
            onError(SpeechRecognitionError.recognizerUnavailable)
            return
        }
        self.recognizer = recognizer

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError(error)
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Читаем self.request заново на каждый буфер (а не захватываем
            // константу) — за время сессии он подменяется на каждый новый
            // сегмент, а тап с микрофона ставится один раз здесь, в start().
            self?.request?.append(buffer)
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
        beginSegment()
        resetSilenceTimer()
    }

    /// Открывает очередной сегмент распознавания поверх уже работающего
    /// `audioEngine` (сам движок и тап с микрофона не трогаем — только
    /// request/task). Вызывается и в самом начале диктовки, и каждый раз,
    /// когда предыдущий сегмент завершился сам по себе из-за паузы в речи.
    private func beginSegment() {
        guard let recognizer, isListening else { return }
        task?.cancel()
        segmentID += 1
        let mySegment = segmentID
        segmentStartedAt = Date()
        lastSegmentText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // Офлайн-распознавание, если доступно для этого языка — быстрее и без сети.
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening, self.segmentID == mySegment else { return }
                if let result {
                    self.fastFailures = 0
                    self.resetSilenceTimer()
                    let current = result.bestTranscription.formattedString
                    // Распознаватель иногда начинает транскрипцию «с нуля» прямо
                    // внутри одной задачи (после паузы): текст резко становится
                    // коротким и не продолжает прежний. Тогда прежний фрагмент
                    // фиксируем, а не затираем.
                    if self.looksLikeRestart(previous: self.lastSegmentText, current: current) {
                        self.committedText = self.joined(self.committedText, self.lastSegmentText)
                    }
                    self.lastSegmentText = current
                    let combined = self.combinedText(withCurrent: current)
                    self.onPartialResult?(combined)
                    if result.isFinal {
                        // Пауза в речи: фиксируем то, что уже распознано, и
                        // сразу открываем следующий сегмент — пользователь
                        // ничего не заметит, текст просто продолжит расти.
                        self.committedText = combined
                        self.lastSegmentText = ""
                        self.beginSegment()
                    }
                } else if let error {
                    // Обычно это системное "речь не обнаружена" на паузе,
                    // а не реальный сбой — просто продолжаем слушать дальше.
                    // Но если сегмент умирает практически мгновенно раз за
                    // разом — это настоящая поломка, а не пауза в речи.
                    if Date().timeIntervalSince(self.segmentStartedAt) < 1.0 {
                        self.fastFailures += 1
                    } else {
                        self.fastFailures = 0
                    }
                    // Главное: сегмент закончился без isFinal — всё, что в нём
                    // успели распознать, фиксируем, чтобы оно не пропало.
                    self.committedText = self.joined(self.committedText, self.lastSegmentText)
                    self.lastSegmentText = ""
                    if self.fastFailures >= Self.maxFastFailures {
                        let handler = self.onError
                        self.stop()
                        handler?(error)
                        return
                    }
                    // Небольшая пауза перед следующим сегментом, чтобы не
                    // крутить цикл на полной скорости.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard self.isListening, self.segmentID == mySegment else { return }
                    self.beginSegment()
                }
            }
        }
    }

    private func combinedText(withCurrent current: String) -> String {
        joined(committedText, current)
    }

    private func joined(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// true, если новый промежуточный результат — не уточнение прежнего, а
    /// начало новой транскрипции: заметно короче и не является его началом.
    /// Обычные правки распознавателя (пара символов) под это не попадают.
    private func looksLikeRestart(previous: String, current: String) -> Bool {
        guard previous.count >= 6, !current.isEmpty else { return false }
        guard current.count * 2 < previous.count else { return false }
        return !previous.hasPrefix(current)
    }

    /// Сбрасывает таймер тишины — вызывается на каждый новый распознанный
    /// фрагмент речи. Если новых фрагментов не появляется `silenceTimeout`
    /// секунд подряд — считаем, что пользователь закончил, и останавливаем
    /// запись целиком.
    private func resetSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.stop()
        }
    }

    /// Останавливает запись и распознавание целиком. Безопасно вызывать
    /// даже если запись уже не идёт.
    func stop() {
        silenceTask?.cancel()
        silenceTask = nil
        segmentID += 1 // инвалидируем любые ещё летящие колбэки старого сегмента
        guard isListening else { return }
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        committedText = ""
        lastSegmentText = ""
        onError = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

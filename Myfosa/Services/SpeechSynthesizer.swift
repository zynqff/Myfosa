import AVFoundation
import Combine

/// Озвучивает текст встроенным синтезом речи iOS. Разрешений не требует.
/// Помнит, какая именно карточка/поле сейчас звучит (`speakingID`), чтобы
/// кнопки воспроизведения в UI могли сами переключаться между "▶︎" и "■"
/// и автоматически возвращаться в "▶︎", когда озвучка закончилась сама по себе.
final class SpeechSynthesizer: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()

    /// Идентификатор текущей звучащей карточки/поля (например "<uuid>-src").
    /// nil, если сейчас ничего не озвучивается.
    @Published private(set) var speakingID: String?

    /// Сторожевой таймер: если озвучка не подтвердила реальный старт
    /// (didStart) за разумное время, считаем её зависшей и сбрасываем
    /// состояние — иначе кнопка так и осталась бы в виде "■" навсегда.
    private var watchdog: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Разовая озвучка без переключения состояния — используется там, где
    /// кнопки play/pause не нужны (например, компактный перевод на вкладке «Камера»).
    func speak(_ text: String, language: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prepareAudioSessionForPlayback()
        synthesizer.stopSpeaking(at: .immediate)
        let code = speechLanguageCode(for: language)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: code) ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Кнопка play/pause для карточки перевода: если сейчас звучит именно
    /// `id` — останавливает. Иначе останавливает то, что звучало раньше
    /// (если звучало), и запускает `id`.
    func toggle(_ text: String, language: String, id: String) {
        if speakingID == id {
            stop()
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Голосовой ввод мог оставить AVAudioSession в категории только для
        // записи (.record) — без явного возврата в режим воспроизведения
        // синтезатор молча "зависает": speakingID выставлен, а звука нет и
        // didFinish/didCancel никогда не приходят.
        prepareAudioSessionForPlayback()
        synthesizer.stopSpeaking(at: .immediate)
        let code = speechLanguageCode(for: language)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: code) ?? AVSpeechSynthesisVoice(language: "en-US")
        speakingID = id
        synthesizer.speak(utterance)
        armWatchdog(for: id)
    }

    func stop() {
        watchdog?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    /// Гарантирует, что сессия готова воспроизводить звук независимо от
    /// того, в каком состоянии её оставили другие подсистемы (диктовка).
    private func prepareAudioSessionForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            // Если не получилось переключить категорию — всё равно пробуем
            // говорить: на части устройств voiceover-подобные категории и
            // так допускают воспроизведение.
        }
    }

    /// Если за 4 секунды озвучка так и не подтвердила реальный старт —
    /// считаем её зависшей (например, голос для языка ещё докачивается
    /// системой) и возвращаем кнопку в исходное состояние.
    private func armWatchdog(for id: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.speakingID == id else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.speakingID = nil
        }
    }
}

extension SpeechSynthesizer: AVSpeechSynthesizerDelegate {
    // Делегат AVSpeechSynthesizer не гарантированно вызывается на главном потоке.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.watchdog?.cancel() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.watchdog?.cancel()
            self?.speakingID = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.watchdog?.cancel()
            self?.speakingID = nil
        }
    }
}

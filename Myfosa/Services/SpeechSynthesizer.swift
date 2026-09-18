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

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Разовая озвучка без переключения состояния — используется там, где
    /// кнопки play/pause не нужны (например, компактный перевод на вкладке «Камера»).
    func speak(_ text: String, language: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        synthesizer.stopSpeaking(at: .immediate)
        let code = speechLanguageCode(for: language)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: code) ?? AVSpeechSynthesisVoice(language: "en-US")
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingID = nil
    }
}

extension SpeechSynthesizer: AVSpeechSynthesizerDelegate {
    // Делегат AVSpeechSynthesizer не гарантированно вызывается на главном потоке.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakingID = nil }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speakingID = nil }
    }
}

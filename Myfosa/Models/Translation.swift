import Foundation
import NaturalLanguage

struct TranslationItem: Identifiable, Equatable {
    let id: UUID
    let source: String
    let translated: String
    let sourceLang: String
    let targetLang: String
    let date: Date

    init(id: UUID = UUID(), source: String, translated: String, sourceLang: String, targetLang: String, date: Date) {
        self.id = id
        self.source = source
        self.translated = translated
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.date = date
    }
}

let supportedLanguages = [
    "English", "Russian", "German", "French", "Spanish", "Italian", "Portuguese", "Chinese", "Japanese", "Korean",
    "Arabic", "Turkish", "Dutch", "Polish", "Ukrainian", "Vietnamese", "Thai", "Indonesian", "Malay", "Hindi",
    "Bengali", "Persian", "Hebrew", "Czech", "Greek", "Romanian", "Hungarian", "Swedish", "Danish", "Finnish",
    "Norwegian", "Slovak", "Bulgarian"
]

/// Псевдо-язык «определить автоматически». Модель переводит с любого языка
/// и сама исходный язык в промпте не использует, поэтому для перевода выбор
/// исходного языка по сути нужен только для голосового ввода и озвучки.
let autoLanguage = "Auto"

/// Список для выбора ИСХОДНОГО языка: сначала «Автоопределение».
let sourceLanguages = [autoLanguage] + supportedLanguages

/// Определяет язык текста на устройстве (NaturalLanguage, без сети) и
/// возвращает его внутреннее имя из `supportedLanguages`, либо nil, если язык
/// не распознан или не поддерживается.
func detectLanguageName(of text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let dominant = recognizer.dominantLanguage else { return nil }
    return nlLanguageNames[dominant.rawValue]
}

/// Конкретный язык для озвучки/истории: если выбран не «Auto» — он сам, иначе
/// определённый по тексту (запасной вариант — английский).
func resolvedLanguage(_ language: String, for text: String) -> String {
    guard language == autoLanguage else { return language }
    return detectLanguageName(of: text) ?? "English"
}

/// Язык, на котором по умолчанию говорит пользователь (язык устройства), если
/// он есть среди поддерживаемых. Нужен для голосового ввода при «Auto».
func deviceLanguageName() -> String {
    for identifier in Locale.preferredLanguages {
        let code = Locale(identifier: identifier).languageCode ?? String(identifier.prefix(2))
        if let name = nlLanguageNames[code] { return name }
    }
    return "English"
}

private let nlLanguageNames: [String: String] = [
    "en": "English", "ru": "Russian", "de": "German", "fr": "French", "es": "Spanish",
    "it": "Italian", "pt": "Portuguese", "zh-Hans": "Chinese", "zh-Hant": "Chinese", "zh": "Chinese",
    "ja": "Japanese", "ko": "Korean", "ar": "Arabic", "tr": "Turkish", "nl": "Dutch",
    "pl": "Polish", "uk": "Ukrainian", "vi": "Vietnamese", "th": "Thai", "id": "Indonesian",
    "ms": "Malay", "hi": "Hindi", "bn": "Bengali", "fa": "Persian", "he": "Hebrew",
    "cs": "Czech", "el": "Greek", "ro": "Romanian", "hu": "Hungarian", "sv": "Swedish",
    "da": "Danish", "fi": "Finnish", "nb": "Norwegian", "no": "Norwegian", "nn": "Norwegian",
    "sk": "Slovak", "bg": "Bulgarian"
]

/// Название языка на нём самом  (автоним), для отображения в выборе языка.
/// Внутренний идентификатор языка (переданный в `supportedLanguages` и используемый
/// сервисом перевода) при этом не меняется — меняется только то, что видит пользователь.
private let languageAutonyms: [String: String] = [
    "English": "English",
    "Russian": "Русский",
    "German": "Deutsch",
    "French": "Français",
    "Spanish": "Español",
    "Italian": "Italiano",
    "Portuguese": "Português",
    "Chinese": "中文",
    "Japanese": "日本語",
    "Korean": "한국어",
    "Arabic": "العربية",
    "Turkish": "Türkçe",
    "Dutch": "Nederlands",
    "Polish": "Polski",
    "Ukrainian": "Українська",
    "Vietnamese": "Tiếng Việt",
    "Thai": "ไทย",
    "Indonesian": "Bahasa Indonesia",
    "Malay": "Bahasa Melayu",
    "Hindi": "हिन्दी",
    "Bengali": "বাংলা",
    "Persian": "فارسی",
    "Hebrew": "עברית",
    "Czech": "Čeština",
    "Greek": "Ελληνικά",
    "Romanian": "Română",
    "Hungarian": "Magyar",
    "Swedish": "Svenska",
    "Danish": "Dansk",
    "Finnish": "Suomi",
    "Norwegian": "Norsk",
    "Slovak": "Slovenčina",
    "Bulgarian": "Български"
]

func languageAutonym(_ language: String) -> String {
    if language == autoLanguage { return "Автоопределение" }
    return languageAutonyms[language] ?? language
}

/// Плейсхолдер поля ввода ("Enter text") на каждом поддерживаемом языке —
/// показывается в пустом поле, подписанном этим языком.
private let enterTextPlaceholders: [String: String] = [
    "English": "Enter text",
    "Russian": "Введите текст",
    "German": "Text eingeben",
    "French": "Saisissez du texte",
    "Spanish": "Introduce texto",
    "Italian": "Inserisci testo",
    "Portuguese": "Digite o texto",
    "Chinese": "输入文字",
    "Japanese": "テキストを入力",
    "Korean": "텍스트 입력",
    "Arabic": "أدخل النص",
    "Turkish": "Metin girin",
    "Dutch": "Voer tekst in",
    "Polish": "Wpisz tekst",
    "Ukrainian": "Введіть текст",
    "Vietnamese": "Nhập văn bản",
    "Thai": "ป้อนข้อความ",
    "Indonesian": "Masukkan teks",
    "Malay": "Masukkan teks",
    "Hindi": "टेक्स्ट दर्ज करें",
    "Bengali": "টেক্সট লিখুন",
    "Persian": "متن را وارد کنید",
    "Hebrew": "הזן טקסט",
    "Czech": "Zadejte text",
    "Greek": "Εισαγάγετε κείμενο",
    "Romanian": "Introduceți text",
    "Hungarian": "Írjon be szöveget",
    "Swedish": "Ange text",
    "Danish": "Indtast tekst",
    "Finnish": "Kirjoita teksti",
    "Norwegian": "Skriv inn tekst",
    "Slovak": "Zadajte text",
    "Bulgarian": "Въведете текст"
]

func enterTextPlaceholder(for language: String) -> String {
    if language == autoLanguage { return "Введите текст" }
    return enterTextPlaceholders[language] ?? "Enter text"
}

/// Плейсхолдер поля ввода во время голосового распознавания ("Listening…")
/// на каждом поддерживаемом языке.
private let listeningPlaceholders: [String: String] = [
    "English": "Listening…",
    "Russian": "Слушаю…",
    "German": "Höre zu…",
    "French": "Écoute…",
    "Spanish": "Escuchando…",
    "Italian": "Ascolto…",
    "Portuguese": "Ouvindo…",
    "Chinese": "正在聆听…",
    "Japanese": "聞き取り中…",
    "Korean": "듣는 중…",
    "Arabic": "جارٍ الاستماع…",
    "Turkish": "Dinleniyor…",
    "Dutch": "Luisteren…",
    "Polish": "Słucham…",
    "Ukrainian": "Слухаю…",
    "Vietnamese": "Đang nghe…",
    "Thai": "กำลังฟัง…",
    "Indonesian": "Mendengarkan…",
    "Malay": "Mendengar…",
    "Hindi": "सुन रहा है…",
    "Bengali": "শুনছি…",
    "Persian": "در حال شنیدن…",
    "Hebrew": "מאזין…",
    "Czech": "Poslouchám…",
    "Greek": "Ακούω…",
    "Romanian": "Ascult…",
    "Hungarian": "Hallgatom…",
    "Swedish": "Lyssnar…",
    "Danish": "Lytter…",
    "Finnish": "Kuuntelen…",
    "Norwegian": "Lytter…",
    "Slovak": "Počúvam…",
    "Bulgarian": "Слушам…"
]

func listeningPlaceholder(for language: String) -> String {
    if language == autoLanguage { return "Слушаю…" }
    return listeningPlaceholders[language] ?? "Listening…"
}

/// BCP-47 коды для AVSpeechSynthesisVoice (озвучка перевода) и одновременно
/// для SFSpeechRecognizer (голосовой ввод) — те же локали подходят для обоих.
private let languageSpeechCodes: [String: String] = [
    "English": "en-US", "Russian": "ru-RU", "German": "de-DE", "French": "fr-FR", "Spanish": "es-ES",
    "Italian": "it-IT", "Portuguese": "pt-PT", "Chinese": "zh-CN", "Japanese": "ja-JP", "Korean": "ko-KR",
    "Arabic": "ar-SA", "Turkish": "tr-TR", "Dutch": "nl-NL", "Polish": "pl-PL", "Ukrainian": "uk-UA",
    "Vietnamese": "vi-VN", "Thai": "th-TH", "Indonesian": "id-ID", "Malay": "ms-MY", "Hindi": "hi-IN",
    "Bengali": "bn-IN", "Persian": "fa-IR", "Hebrew": "he-IL", "Czech": "cs-CZ", "Greek": "el-GR",
    "Romanian": "ro-RO", "Hungarian": "hu-HU", "Swedish": "sv-SE", "Danish": "da-DK", "Finnish": "fi-FI",
    "Norwegian": "nb-NO", "Slovak": "sk-SK", "Bulgarian": "bg-BG"
]

func speechLanguageCode(for language: String) -> String {
    // «Auto» сюда доходить не должен (вызывающий код сначала определяет язык),
    // но на всякий случай берём язык устройства, а не жёсткий английский.
    let name = language == autoLanguage ? deviceLanguageName() : language
    return languageSpeechCodes[name] ?? "en-US"
}

import Foundation
import SwiftUI
import Combine
import os

private let llamaDiagnosticsLogger = Logger(subsystem: "com.SiaSoft.Myfosa", category: "llama")

/// Замок «поток токенов ещё актуален». onToken приходит с фонового потока и
/// порождает отдельные Task на главном акторе; они могут выполниться уже ПОСЛЕ
/// финального присваивания результата и дописать в конец перевода повторный
/// хвост. Перед финальным присваиванием замок закрывается — опоздавшие токены
/// отбрасываются.
final class StreamGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    func close() {
        lock.lock(); open = false; lock.unlock()
    }
}

enum UpdateCheckStatus {
    case idle
    case checking
    case upToDate
    case available(RemoteAppConfig)
    case failed(String)
}

@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var preview = ""

    /// true, пока перевод ещё не готов: идёт debounce, загрузка модели или
    /// генерация. Пока флаг поднят, нельзя нажать «Далее»/Enter/галочку —
    /// иначе в историю уходил бы устаревший или обрезанный перевод.
    @Published private(set) var isPreviewStale = false
    /// Ключ (языки + текст) последнего ПОЛНОСТЬЮ готового перевода. Если ключ не
    /// изменился (например, дописали пробел в конце), перевод не перезапускается.
    private var lastTranslatedKey = ""
    @Published var sourceLanguage = autoLanguage
    @Published var targetLanguage = "Russian"
    @Published var history: [TranslationItem] = []
    @Published var modelState: ModelState = .unloaded
    @Published var errorMessage: String?
    @Published var config: RemoteAppConfig?

    /// Становится true только после того, как первая проверка наличия модели
    /// завершена (см. init) — пока false, экран «Перевод» ничего не рисует,
    /// чтобы не мелькнуть сначала неверным состоянием (например, композером
    /// вместо экрана загрузки модели), а сразу показать правильное.
    @Published var isReady = false

    /// Установлена ли на устройстве модель, соответствующая текущему конфигу.
    @Published var isModelInstalled = false

    // MARK: Загрузка / установка модели
    @Published var isModelDownloading = false

    // MARK: Проверка обновлений (Настройки)
    @Published var updateCheckStatus: UpdateCheckStatus = .idle
    @Published var updateInstalledSuccess = false

    // MARK: Удаление модели (Настройки)
    @Published var showDeleteConfirmation = false
    @Published var isDeletingModel = false
    @Published var deleteProgress = 0.0
    @Published var modelDeletedSuccess = false

    let configService = ConfigService()
    let modelStore = ModelStore()
    let translator: LlamaTranslatorService
    let downloader = ModelDownloadService()
    let speech = SpeechSynthesizer()
    let speechRecognizer = SpeechRecognizerService()

    private var idleTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var modelURL: URL?
    // Увеличивается на каждый новый запуск schedulePreview(). Токены из "устаревшего"
    // (уже перезапущенного) прогона generate() по этому счётчику отбрасываются —
    // это защищает от перемешивания текста двух параллельных потоковых генераций,
    // так как сам generate() кооперативную отмену не поддерживает.
    private var previewGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    @AppStorage("idleTimeout") private var idleTimeout = 180

    init(translator: LlamaTranslatorService = LlamaTranslatorService()) {
        self.translator = translator
        // `downloader` — отдельный ObservableObject, и его собственные @Published
        // свойства (progress и т.д.) сами по себе НЕ вызывают перерисовку экранов,
        // которые подписаны только на `TranslatorViewModel` (через @EnvironmentObject).
        // Поэтому явно прокидываем его изменения наружу — иначе прогресс-бар
        // загрузки модели не обновлялся в реальном времени, а «подтягивался»
        // только когда экран перерисовывался по другой причине (например, при
        // выходе из Настроек и повторном входе).
        downloader.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // speech/speechRecognizer — тоже отдельные ObservableObject, их
        // изменения (speakingID, isListening) сами по себе не будят экраны,
        // подписанные только на TranslatorViewModel — прокидываем и их.
        speech.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        speechRecognizer.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        Task {
            let started = DispatchTime.now()
            // Наличие модели на диске — чисто локальная проверка (файл + id/версия
            // из конфига). Если конфиг уже был закеширован раньше — используем его
            // сразу, без сети, чтобы экран открылся мгновенно. Актуальный конфиг с
            // сервера подтягиваем следом, уже в фоне, не блокируя интерфейс.
            if let cached = await configService.loadCached() {
                config = cached
                modelURL = await modelStore.installedModelURL()
                await syncState()
            } else {
                // Первый запуск, локального конфига ещё нет — тут без сети,
                // к сожалению, никак не узнать даже то, какую модель качать.
                await refreshConfig()
            }
            // Не даём интерфейсу "мигнуть" неправильным состоянием, пока идёт
            // проверка наличия модели: держим экран пустым минимум ~60мс, даже
            // если проверка завершилась быстрее. Если же сама проверка заняла
            // дольше — isReady включается сразу же, без лишнего ожидания.
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if elapsedMs < 60 { try? await Task.sleep(for: .milliseconds(60 - Int(elapsedMs))) }
            isReady = true

            if config != nil {
                // Экран уже открыт по кешу — здесь просто молча подтягиваем
                // актуальную версию конфига с сервера. Ошибку сети тут не
                // показываем: офлайн-запуск по кешу — нормальный сценарий,
                // а не повод пугать пользователя алертом.
                await refreshConfigSilently()
            }
        }
    }

    /// Как `refreshConfig()`, но не выставляет `errorMessage` при сбое сети —
    /// используется для тихого фонового обновления конфига после того, как
    /// экран уже открылся по локальному кешу.
    private func refreshConfigSilently() async {
        if let c = try? await configService.load() {
            config = c
            modelURL = await modelStore.installedModelURL()
            await syncState()
        }
    }

    func refreshConfig() async {
        do {
            let c = try await configService.load()
            config = c
            modelURL = await modelStore.installedModelURL()
        } catch {
            errorMessage = error.localizedDescription
        }
        await syncState()
    }

    /// Скачивает и устанавливает модель, только если на устройстве нет НИКАКОЙ модели.
    /// Используется при обычном использовании переводчика (первый запуск / первый ввод текста).
    ///
    /// Если модель уже стоит, а в удалённом конфиге появилась новая версия — это не повод
    /// ни блокировать переводчик, ни молча качать гигабайты: обновление пользователь
    /// запускает сам в Настройках → «Проверить обновления».
    func ensureModel() async throws {
        if let installedURL = await modelStore.installedModelURL() {
            modelURL = installedURL
            await syncState()
            return
        }

        // Первый запуск без сети: конфига ещё нет. Пробуем получить его сейчас —
        // иначе пользователь видел бы вводящее в заблуждение «неверный формат
        // конфигурации» вместо понятной сетевой ошибки.
        if config == nil {
            config = try await configService.load()
        }
        guard let config else { throw ConfigError.badResponse }

        try await downloadAndInstall(model: config.model)
        modelURL = await modelStore.installedModelURL()
        llamaDiagnosticsLogger.notice("ensureModel: id=\(config.model.id, privacy: .public) version=\(config.model.version, privacy: .public) file=\(config.model.fileName, privacy: .public) итоговый путь=\(self.modelURL?.path ?? "nil", privacy: .public)")
        await syncState()
    }

    /// Скачивает файл модели, ПРОВЕРЯЕТ его целостность и только после успешной проверки
    /// заменяет им предыдущую модель. Если что-то пошло не так — старая модель остаётся нетронутой.
    private func downloadAndInstall(model: RemoteAppConfig.ModelInfo) async throws {
        isModelDownloading = true
        defer { isModelDownloading = false }
        let previousFileName = await modelStore.installedMetadata()?.fileName
        let downloaded = try await downloader.download(url: model.url, fileName: model.fileName)
        do {
            try await modelStore.verify(url: downloaded, expectedSize: model.sizeBytes, expectedSHA256: model.sha256)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        // Новый файл скачан и прошёл проверку целостности — теперь можно безопасно
        // заменить старую модель (её удаление происходит внутри commit).
        _ = try await modelStore.commit(downloadedFile: downloaded, model: model, previousFileName: previousFileName)
    }

    func beginTyping() {
        guard !sourceText.isEmpty else {
            // Текст стёрли до конца клавиатурой — без этого в нижнем поле
            // оставался перевод уже несуществующего текста.
            schedulePreview()
            return
        }
        Task {
            do {
                if await translator.currentState() == .unloaded {
                    try await ensureModel()
                    if let modelURL { try await translator.loadModel(path: modelURL) }
                }
                await syncState()
            } catch { errorMessage = error.localizedDescription }
        }
        schedulePreview()
    }

    func schedulePreview() {
        previewTask?.cancel()

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            previewGeneration += 1 // инвалидируем ещё не завершившийся прогон
            preview = ""
            lastTranslatedKey = ""
            isPreviewStale = false
            return
        }

        let sourceLang = sourceLanguage
        let targetLang = targetLanguage
        let key = "\(sourceLang)|\(targetLang)|\(trimmed)"

        // Реально ничего не изменилось (пробел/перевод строки по краям или
        // возврат к уже переведённому тексту) — не стираем и не перегенерируем.
        if key == lastTranslatedKey, !preview.isEmpty {
            previewGeneration += 1
            isPreviewStale = false
            return
        }

        previewGeneration += 1
        let myGeneration = previewGeneration
        isPreviewStale = true

        // Старый перевод НЕ стираем, пока генерируется новый: он остаётся на
        // экране и заменяется целиком, когда новый готов. Токены в реальном
        // времени показываем только если поле было пустым — иначе вперемешку
        // шёл бы старый и новый текст.
        let streamLive = preview.isEmpty
        let gate = StreamGate()

        previewTask = Task { [weak self] in
            defer { gate.close() }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do {
                if await self.translator.currentState() == .unloaded {
                    try await self.ensureModel()
                    if let modelURL = self.modelURL { try await self.translator.loadModel(path: modelURL) }
                }
                let result = try await self.translator.translate(
                    text: trimmed,
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    onToken: { [weak self] piece in
                        guard streamLive, gate.isOpen else { return }
                        Task { @MainActor in
                            guard gate.isOpen, let self, self.previewGeneration == myGeneration else { return }
                            self.preview += piece
                        }
                    }
                )
                // Замок закрываем ДО присваивания, чтобы опоздавшие токены не
                // дописали повторный хвост к уже готовому переводу.
                await MainActor.run {
                    gate.close()
                    guard self.previewGeneration == myGeneration else { return }
                    self.preview = result
                    self.lastTranslatedKey = key
                    self.isPreviewStale = false
                }
            } catch {
                await MainActor.run {
                    gate.close()
                    guard self.previewGeneration == myGeneration else { return }
                    // Отмена (сворачивание приложения) — не ошибка: флаг остаётся
                    // поднятым, перевод перезапустится при возврате в приложение.
                    if error is CancellationError || Task.isCancelled { return }
                    self.preview = ""
                    self.lastTranslatedKey = ""
                    self.isPreviewStale = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func finalize() {
        // Пока перевод не завершён (идёт генерация / ожидание), подтверждать нечего.
        guard !isPreviewStale else { return }
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translated.isEmpty else { return }
        // При автоопределении в карточку пишем реально определённый язык.
        let detectedSource = sourceLanguage == autoLanguage ? (detectLanguageName(of: source) ?? autoLanguage) : sourceLanguage
        let item = TranslationItem(source: source, translated: translated, sourceLang: detectedSource, targetLang: targetLanguage, date: .now)
        // Пишем только в текущую (видимую на экране «Текст») сессию. В постоянный
        // архив («История») она уйдёт целиком при уходе приложения в фон —
        // см. appDidEnterBackground(). Вставляем в начало: карточка появляется
        // сразу под композером (он теперь сверху), а не в конце длинной ленты.
        history.insert(item, at: 0)
        previewTask?.cancel()
        previewGeneration += 1
        sourceText = ""
        preview = ""
        lastTranslatedKey = ""
        isPreviewStale = false
        scheduleIdleUnload()
    }

    func swapLanguages() {
        if sourceLanguage == autoLanguage {
            // «Автоопределение» не может стать языком перевода: нижний язык
            // становится исходным, а целевым — язык текущего текста (если он
            // определился и отличается), иначе английский/русский.
            let detected = detectLanguageName(of: sourceText)
            let newTarget: String
            if let detected, detected != targetLanguage {
                newTarget = detected
            } else {
                newTarget = targetLanguage == "English" ? "Russian" : "English"
            }
            sourceLanguage = targetLanguage
            targetLanguage = newTarget
        } else {
            let old = sourceLanguage; sourceLanguage = targetLanguage; targetLanguage = old
        }
        schedulePreview()
    }

    // MARK: - Голосовой ввод

    /// Запускает голосовой ввод в верхнее (исходное) поле. Если поля нужно
    /// поменять местами — это делает вызывающий (View), свапая языки перед
    /// вызовом, ровно как при обычном тапе по нижнему полю.
    func startDictation() {
        Task {
            let granted = await speechRecognizer.requestPermissions()
            guard granted else {
                errorMessage = SpeechRecognitionError.permissionDenied.localizedDescription
                return
            }
            clearInput()
            // При «Автоопределении» заранее неизвестно, на каком языке заговорят:
            // распознавателю нужна конкретная локаль, берём язык устройства. Чтобы
            // диктовать на другом языке — выберите его в списке явно.
            let dictationLanguage = sourceLanguage == autoLanguage ? deviceLanguageName() : sourceLanguage
            speechRecognizer.start(
                language: dictationLanguage,
                onPartialResult: { [weak self] text in
                    guard let self else { return }
                    self.sourceText = text
                    self.beginTyping()
                },
                onError: { [weak self] error in
                    self?.errorMessage = error.localizedDescription
                }
            )
        }
    }

    func stopDictation() {
        speechRecognizer.stop()
    }

    // MARK: - Удаление одной карточки

    /// Удаляет один перевод из текущей (ещё не заархивированной) сессии —
    /// свайп по карточке на экране «Перевод».
    func deleteFromSession(_ item: TranslationItem) {
        history.removeAll { $0.id == item.id }
    }

    /// Гарантирует, что модель скачана и загружена в память. Используется
    /// сценариями, не привязанными к обычному полю ввода на экране «Текст» —
    /// перевод по фото, (в будущем) голосовой ввод.
    func ensureModelReady() async throws {
        if await translator.currentState() == .unloaded {
            try await ensureModel()
            if let modelURL { try await translator.loadModel(path: modelURL) }
        }
    }

    /// Разовый перевод произвольного текста в сторону — не трогает
    /// sourceText/preview экрана «Текст». Используется для перевода по фото.
    func translateStandalone(
        _ text: String,
        from sourceLang: String,
        to targetLang: String,
        onToken: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await ensureModelReady()
        return try await translator.translate(
            text: text,
            sourceLang: sourceLang,
            targetLang: targetLang,
            onToken: onToken
        )
    }

    /// Стирает набранный, ещё не подтверждённый текст (крестик), не трогая историю.
    func clearInput() {
        previewTask?.cancel()
        previewGeneration += 1
        sourceText = ""
        preview = ""
        lastTranslatedKey = ""
        isPreviewStale = false
    }

    func clearScreen() { history.removeAll() }

    /// Экран «Текст»: очищает только текущую, ещё не заархивированную сессию.
    /// Постоянного архива («История») не касается.
    func clearSessionConfirmed() {
        history.removeAll()
    }

    /// Экран «История»: полностью и необратимо очищает постоянный архив переводов.
    func clearArchivedHistoryConfirmed() {
        HistoryStore.shared.clearAll()
    }

    // MARK: - Проверка обновлений

    /// Явная проверка обновлений из Настроек: "Поиск обновления…" -> "последняя версия" / "найдено обновление".
    func checkForUpdates() async {
        updateCheckStatus = .checking
        do {
            let remote = try await configService.load()
            config = remote
            let installed = await modelStore.installedMetadata()
            if let installed, installed.id == remote.model.id, installed.version == remote.model.version {
                updateCheckStatus = .upToDate
            } else {
                updateCheckStatus = .available(remote)
            }
        } catch {
            updateCheckStatus = .failed(error.localizedDescription)
        }
    }

    /// Пользователь подтвердил загрузку найденного обновления.
    /// Конфиг обновления передаётся явно (а не читается из `updateCheckStatus`),
    /// потому что тап по кнопке алерта и автоматический сброс `isPresented`
    /// (который переводит `updateCheckStatus` обратно в `.idle`) происходят
    /// практически одновременно — если бы мы читали `updateCheckStatus` здесь,
    /// в момент запуска этой async-задачи он мог уже стать `.idle`, и загрузка
    /// просто не начиналась бы (guard молча возвращался).
    func installAvailableUpdate(_ remote: RemoteAppConfig) async {
        do {
            try await downloadAndInstall(model: remote.model)
            modelURL = await modelStore.installedModelURL()
            // Старая модель уже выгружена из памяти — при следующем переводе будет загружена новая.
            await translator.unloadModel()
            await syncState()
            updateInstalledSuccess = true
        } catch {
            updateCheckStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: - Удаление модели

    func requestDeleteModel() {
        showDeleteConfirmation = true
    }

    /// Пользователь подтвердил удаление в диалоге. Прогресс 0–100% отражает
    /// реально выполненные шаги (выгрузка из памяти → удаление файла →
    /// удаление метаданных → обновление состояния), а не таймер.
    func confirmDeleteModel() {
        guard !isDeletingModel else { return }
        Task {
            isDeletingModel = true
            deleteProgress = 0

            // Шаг 1: выгрузить модель из памяти.
            await translator.unloadModel()
            deleteProgress = 0.25

            // Шаг 2: удалить файл модели.
            let fileName = await modelStore.installedMetadata()?.fileName
            if let fileName {
                do {
                    try await modelStore.remove(fileName: fileName)
                } catch {
                    // Файл не удалился — метаданные не трогаем, чтобы не оставить
                    // приложение в состоянии «модель есть, но не числится».
                    await syncState()
                    isDeletingModel = false
                    errorMessage = error.localizedDescription
                    return
                }
            }
            deleteProgress = 0.6

            // Шаг 3: удалить метаданные установленной модели.
            await modelStore.removeMetadata()
            modelURL = nil
            deleteProgress = 0.85

            // Шаг 4: обновить состояние интерфейса.
            await syncState()
            deleteProgress = 1

            isDeletingModel = false
            modelDeletedSuccess = true
        }
    }

    func appDidEnterBackground() {
        idleTask?.cancel()
        // Запись с микрофона и GPU-вычисления Metal в фоне запрещены системой
        // (генерация, застигнутая сворачиванием, может завершиться крашем) —
        // гасим диктовку и прерываем идущий перевод до выгрузки модели.
        speechRecognizer.stop()
        previewTask?.cancel()
        archiveSessionAndClearScreen()
        Task { await translator.unloadModel(); await syncState() }
    }

    /// Возврат в приложение: если пользователь оставил недописанный текст, а
    /// перевод был прерван сворачиванием — пересчитываем его.
    func appDidBecomeActive() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        schedulePreview()
    }

    /// Переносит все переводы текущей (видимой) сессии в постоянный архив и
    /// очищает экран «Текст» — при следующем открытии приложения он снова пуст,
    /// а переводы находятся в «Истории».
    private func archiveSessionAndClearScreen() {
        guard !history.isEmpty else { return }
        for item in history { HistoryStore.shared.add(item) }
        history.removeAll()
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            let seconds = await MainActor.run { self?.idleTimeout ?? 180 }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.translator.unloadModel()
            await self.syncState()
        }
    }

    func syncState() async {
        modelState = await translator.currentState()
        isModelInstalled = await modelStore.hasInstalledModel()
    }
}

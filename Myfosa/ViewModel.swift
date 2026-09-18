import Foundation
import SwiftUI
import Combine
import os

private let llamaDiagnosticsLogger = Logger(subsystem: "com.SiaSoft.Myfosa", category: "llama")

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
    @Published var sourceLanguage = "English"
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
                modelURL = await modelStore.localURL(fileName: cached.model.fileName)
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
            modelURL = await modelStore.localURL(fileName: c.model.fileName)
            await syncState()
        }
    }

    func refreshConfig() async {
        do {
            let c = try await configService.load()
            config = c
            modelURL = await modelStore.localURL(fileName: c.model.fileName)
        } catch {
            errorMessage = error.localizedDescription
        }
        await syncState()
    }

    /// Скачивает и устанавливает модель, только если установленной версии ещё нет.
    /// Используется при обычном использовании переводчика (первый запуск / первый ввод текста).
    func ensureModel() async throws {
        guard let config else { throw ConfigError.invalidConfig }
        if !(await modelStore.isModelInstalled(matching: config.model)) {
            try await downloadAndInstall(model: config.model)
        }
        modelURL = await modelStore.localURL(fileName: config.model.fileName)
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
        guard !sourceText.isEmpty else { return }
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
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewGeneration += 1 // инвалидируем ещё не завершившийся прогон
            preview = ""
            return
        }
        previewGeneration += 1
        let myGeneration = previewGeneration
        preview = ""
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            do {
                if await self.translator.currentState() == .unloaded {
                    try await self.ensureModel()
                    if let modelURL = self.modelURL { try await self.translator.loadModel(path: modelURL) }
                }
                let result = try await self.translator.translate(
                    text: self.sourceText,
                    sourceLang: self.sourceLanguage,
                    targetLang: self.targetLanguage,
                    onToken: { [weak self] piece in
                        Task { @MainActor in
                            guard let self, self.previewGeneration == myGeneration else { return }
                            self.preview += piece
                        }
                    }
                )
                // Финальное присваивание — подчищает пробелы по краям и служит
                // единственным источником истины, если этот прогон всё ещё актуален.
                await MainActor.run {
                    guard self.previewGeneration == myGeneration else { return }
                    self.preview = result
                }
            } catch { }
        }
    }

    func finalize() {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translated = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translated.isEmpty else { return }
        let item = TranslationItem(source: source, translated: translated, sourceLang: sourceLanguage, targetLang: targetLanguage, date: .now)
        // Пишем только в текущую (видимую на экране «Текст») сессию. В постоянный
        // архив («История») она уйдёт целиком при уходе приложения в фон —
        // см. appDidEnterBackground(). Вставляем в начало: карточка появляется
        // сразу под композером (он теперь сверху), а не в конце длинной ленты.
        history.insert(item, at: 0)
        previewTask?.cancel()
        previewGeneration += 1
        sourceText = ""
        preview = ""
        scheduleIdleUnload()
    }

    func swapLanguages() {
        let old = sourceLanguage; sourceLanguage = targetLanguage; targetLanguage = old
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
            speechRecognizer.start(
                language: sourceLanguage,
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
    func translateStandalone(_ text: String, from sourceLang: String, to targetLang: String) async throws -> String {
        try await ensureModelReady()
        return try await translator.translate(text: text, sourceLang: sourceLang, targetLang: targetLang, onToken: { _ in })
    }

    /// Стирает набранный, ещё не подтверждённый текст (крестик), не трогая историю.
    func clearInput() {
        previewTask?.cancel()
        previewGeneration += 1
        sourceText = ""
        preview = ""
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
            modelURL = await modelStore.localURL(fileName: remote.model.fileName)
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

    /// Пользователь подтвердил удаление в диалоге. Показываем прогресс 0-100%, затем сообщение об успехе.
    func confirmDeleteModel() {
        guard !isDeletingModel else { return }
        Task {
            isDeletingModel = true
            deleteProgress = 0
            await translator.unloadModel()
            let fileName = await modelStore.installedMetadata()?.fileName
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(70))
                deleteProgress = Double(step) / 10.0
            }
            if let fileName { try? await modelStore.remove(fileName: fileName) }
            await modelStore.removeMetadata()
            await syncState()
            isDeletingModel = false
            modelDeletedSuccess = true
        }
    }

    func appDidEnterBackground() {
        idleTask?.cancel()
        archiveSessionAndClearScreen()
        Task { await translator.unloadModel(); await syncState() }
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
        if let config { isModelInstalled = await modelStore.isModelInstalled(matching: config.model) }
    }
}

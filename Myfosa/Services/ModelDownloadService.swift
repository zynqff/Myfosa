import Foundation

/// Потокобезопасное хранилище имени файла: колбэки URLSession приходят с
/// фоновой очереди, а сам сервис живёт на главном акторе.
private final class FileNameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "model.gguf"
    private var taskID: Int?

    var fileName: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }

    /// Идентификатор задачи текущей загрузки. Колбэки любых других задач
    /// (например, отменённых «осиротевших» из прошлого запуска) игнорируются.
    var currentTaskID: Int? {
        get { lock.lock(); defer { lock.unlock() }; return taskID }
        set { lock.lock(); defer { lock.unlock() }; taskID = newValue }
    }
}

@MainActor
final class ModelDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var isDownloading = false

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private let fileNameBox = FileNameBox()

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.SiaSoft.Myfosa.model-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Фоновая сессия переживает перезапуск приложения: система могла
        // продолжить (или даже завершить) загрузку, начатую в прошлом запуске.
        // Ждущего continuation у нас уже нет, поэтому результат такой задачи
        // никто бы не установил, а новая загрузка шла бы параллельно с ней.
        // Сбрасываем осиротевшие задачи — следующая загрузка начнётся чисто.
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    func download(url: URL, fileName: String) async throws -> URL {
        if isDownloading { throw DownloadError.alreadyDownloading }
        fileNameBox.fileName = fileName
        isDownloading = true
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            fileNameBox.currentTaskID = task.taskIdentifier
            task.resume()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask.taskIdentifier == fileNameBox.currentTaskID else { return }
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard downloadTask.taskIdentifier == fileNameBox.currentTaskID else { return }

        // Сервер мог ответить ошибкой (404/403/5xx) — тогда «скачанный файл»
        // это HTML-страница, а не модель. Не принимаем её за результат.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = DownloadError.badStatus(http.statusCode)
            Task { @MainActor in
                self.isDownloading = false
                self.continuation?.resume(throwing: error)
                self.continuation = nil
            }
            return
        }

        // Файл по `location` система удалит сразу после выхода из этого метода,
        // поэтому переносим его синхронно, прямо здесь.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + fileNameBox.fileName)
        do {
            try FileManager.default.moveItem(at: location, to: temp)
            Task { @MainActor in
                self.isDownloading = false
                self.continuation?.resume(returning: temp)
                self.continuation = nil
            }
        } catch {
            Task { @MainActor in
                self.isDownloading = false
                self.continuation?.resume(throwing: error)
                self.continuation = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, task.taskIdentifier == fileNameBox.currentTaskID else { return }
        Task { @MainActor in
            self.isDownloading = false
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

enum DownloadError: LocalizedError {
    case alreadyDownloading
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .alreadyDownloading:
            return "Загрузка уже выполняется."
        case .badStatus(let code):
            return "Сервер вернул ошибку \(code). Попробуйте позже."
        }
    }
}

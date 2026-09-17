import Foundation

@MainActor
final class ModelDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var progress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var isDownloading = false

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var expectedFileName = "model.gguf"

    override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.SiaSoft.Myfosa.model-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func download(url: URL, fileName: String) async throws -> URL {
        if isDownloading { throw DownloadError.alreadyDownloading }
        expectedFileName = fileName
        isDownloading = true
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpectedToWrite
            if totalBytesExpectedToWrite > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + expectedFileName)
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.isDownloading = false
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

enum DownloadError: LocalizedError {
    case alreadyDownloading
    var errorDescription: String? { "Загрузка уже выполняется." }
}

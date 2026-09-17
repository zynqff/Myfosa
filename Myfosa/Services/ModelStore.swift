import Foundation
import CryptoKit

struct InstalledModelMetadata: Codable, Sendable, Equatable {
    let id: String
    let version: String
    let fileName: String
    let sizeBytes: Int64
    let sha256: String?
}

actor ModelStore {
    private let modelsDirectory: URL
    private var metadataURL: URL { modelsDirectory.appendingPathComponent("installed.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        modelsDirectory = base.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    func localURL(fileName: String) -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    func exists(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(fileName: fileName).path)
    }

    func remove(fileName: String) throws {
        let url = localURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Метаданные текущей установленной модели (если она есть).
    func installedMetadata() -> InstalledModelMetadata? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(InstalledModelMetadata.self, from: data)
    }

    func removeMetadata() {
        try? FileManager.default.removeItem(at: metadataURL)
    }

    /// Установлена ли именно та модель (тот же id и версия), что описана в конфиге, и физически лежит ли файл на диске.
    func isModelInstalled(matching model: RemoteAppConfig.ModelInfo) -> Bool {
        guard let meta = installedMetadata(), meta.id == model.id, meta.version == model.version else { return false }
        return exists(fileName: meta.fileName)
    }

    func verify(url: URL, expectedSize: Int64, expectedSHA256: String?) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs[.size] as? NSNumber, expectedSize > 0, size.int64Value != expectedSize {
            throw ModelStoreError.integrity
        }
        if let expectedSHA256, !expectedSHA256.isEmpty {
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw ModelStoreError.integrity
            }
        }
    }

    /// Переносит уже проверенный (verify пройден) скачанный файл на постоянное место.
    /// Старый файл модели удаляется только здесь — то есть только после того, как новый
    /// файл полностью скачан и прошёл проверку целостности.
    func commit(downloadedFile: URL, model: RemoteAppConfig.ModelInfo, previousFileName: String?) throws -> URL {
        let destination = localURL(fileName: model.fileName)
        if let previousFileName, previousFileName != model.fileName {
            try? FileManager.default.removeItem(at: localURL(fileName: previousFileName))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloadedFile, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(values)
        let metadata = InstalledModelMetadata(id: model.id, version: model.version, fileName: model.fileName, sizeBytes: model.sizeBytes, sha256: model.sha256)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
        return destination
    }
}

enum ModelStoreError: LocalizedError {
    case integrity
    var errorDescription: String? { "Файл модели не прошёл проверку целостности." }
}

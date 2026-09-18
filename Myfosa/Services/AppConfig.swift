import Foundation

enum ConfigEndpoint {
    // REPLACE ONLY THIS URL. It stays constant for the lifetime of the app.
    static let url = URL(string: "https://huggingface.co/spaces/Zynqochka/offlinetr/resolve/main/config.json")!
}

struct RemoteAppConfig: Codable, Sendable {
    struct AppInfo: Codable, Sendable {
        let minimumVersion: String?
    }

    struct ModelInfo: Codable, Sendable {
        let id: String
        let version: String
        let fileName: String
        let sizeBytes: Int64
        let sha256: String?
        let url: URL
    }

    let schemaVersion: Int
    let app: AppInfo
    let model: ModelInfo
}

enum ConfigError: LocalizedError {
    case badResponse
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Не удалось получить конфигурацию."
        case .invalidConfig: return "Конфигурация имеет неверный формат."
        }
    }
}

actor ConfigService {
    private let decoder = JSONDecoder()
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("config.json")
    }

    func load() async throws -> RemoteAppConfig {
        do {
            var request = URLRequest(url: ConfigEndpoint.url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ConfigError.badResponse
            }
            let config = try decoder.decode(RemoteAppConfig.self, from: data)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return config
        } catch {
            if let cached = loadCached() {
                return cached
            }
            throw error
        }
    }

    /// Быстрое, чисто локальное чтение последнего сохранённого конфига —
    /// без обращения к сети. Наличие модели на диске зависит только от
    /// самого файла модели и id/версии в этом конфиге, поэтому на старте
    /// приложения этого достаточно, чтобы сразу открыть экран «Перевод»,
    /// не дожидаясь сетевого запроса.
    func loadCached() -> RemoteAppConfig? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decoder.decode(RemoteAppConfig.self, from: data)
    }
}

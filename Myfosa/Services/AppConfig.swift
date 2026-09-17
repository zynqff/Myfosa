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
            let (data, response) = try await URLSession.shared.data(from: ConfigEndpoint.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ConfigError.badResponse
            }
            let config = try decoder.decode(RemoteAppConfig.self, from: data)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return config
        } catch {
            if let data = try? Data(contentsOf: cacheURL), let cached = try? decoder.decode(RemoteAppConfig.self, from: data) {
                return cached
            }
            throw error
        }
    }
}

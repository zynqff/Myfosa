import Vision
import UIKit

struct RecognizedTextBlock: Identifiable {
    let id = UUID()
    /// Текст, как его распознал Vision.
    let text: String
    /// Нормализованный прямоугольник (0...1), система координат Vision:
    /// начало координат — левый нижний угол. Всегда осе-выровнен — для
    /// наклонных строк не подходит для наложения перевода, оставлен только
    /// для отладки/совместимости.
    let boundingBox: CGRect
    /// Четыре угла строки в тех же нормализованных координатах Vision, но с
    /// учётом её реального поворота — именно по ним нужно накладывать перевод,
    /// чтобы он шёл вдоль оригинального текста при любом наклоне фото.
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
    /// Уверенность распознавания (0...1).
    var confidence: Float = 1
}

extension UIImage {
    /// Возвращает копию с ориентацией `.up` (повороты «запекаются» в пиксели) и,
    /// если нужно, уменьшенную до `maxDimension` по длинной стороне. Так
    /// распознавание текста, расчёт геометрии и отображение работают с одними
    /// и теми же пикселями, а огромные снимки из галереи (48 Мп) не раздувают
    /// память и не замедляют перевод.
    func normalizedForOCR(maxDimension: CGFloat = 2400) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        if imageOrientation == .up && scale == 1 { return self }
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Отсев «мусора»: блоков, которые нечего и незачем переводить — номера строк,
/// одиночные символы, шум из-за наклона/бликов. Раньше они превращались в ряды
/// крошечных плашек с обрывками букв поверх фото.
private func isMeaningfulText(_ text: String, confidence: Float, lineHeightFraction: CGFloat) -> Bool {
    if confidence < 0.3 { return false }
    // Слишком мелкий текст всё равно не прочитать, а плашка на нём — просто шум.
    if lineHeightFraction < 0.005 { return false }
    var letters = 0
    var hasCJK = false
    for scalar in text.unicodeScalars {
        if CharacterSet.letters.contains(scalar) {
            letters += 1
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                hasCJK = true
            }
        }
    }
    if letters == 0 { return false }          // только цифры/знаки (номера строк и т.п.)
    if letters < 2 && !hasCJK { return false } // одиночная буква вне иероглифической письменности
    return true
}

enum TextRecognitionError: LocalizedError {
    case noTextFound
    case invalidImage
    var errorDescription: String? {
        switch self {
        case .noTextFound: return "На этом фото не удалось найти текст."
        case .invalidImage: return "Не удалось обработать изображение."
        }
    }
}

/// Гарантирует, что continuation будет возобновлена ровно один раз.
/// Vision может и вызвать completion с ошибкой, и бросить ту же ошибку из
/// perform(_:) — двойной resume() у CheckedContinuation приводит к крашу.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard claim() else { return }
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard claim() else { return }
        continuation.resume(throwing: error)
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Распознаёт текстовые блоки на фото. Язык распознавания определяется
/// автоматически (iOS 16+), поэтому явно указывать исходный язык не нужно.
enum TextRecognitionService {
    static func recognizeText(in image: UIImage) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { throw TextRecognitionError.invalidImage }

        return try await withCheckedThrowingContinuation { (rawContinuation: CheckedContinuation<[RecognizedTextBlock], Error>) in
            let continuation = ResumeOnce(rawContinuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let imageWidth = CGFloat(cgImage.width)
                let imageHeight = CGFloat(cgImage.height)
                let longestSide = max(imageWidth, imageHeight)
                let blocks = observations.compactMap { observation -> RecognizedTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Высота строки вдоль её собственной оси (а не по оси экрана).
                    let dx = (observation.topLeft.x - observation.bottomLeft.x) * imageWidth
                    let dy = (observation.topLeft.y - observation.bottomLeft.y) * imageHeight
                    let lineHeight = hypot(dx, dy) / max(1, longestSide)
                    guard isMeaningfulText(candidate.string, confidence: candidate.confidence, lineHeightFraction: lineHeight) else { return nil }
                    return RecognizedTextBlock(
                        text: candidate.string,
                        boundingBox: observation.boundingBox,
                        topLeft: observation.topLeft,
                        topRight: observation.topRight,
                        bottomLeft: observation.bottomLeft,
                        bottomRight: observation.bottomRight,
                        confidence: candidate.confidence
                    )
                }
                if blocks.isEmpty {
                    continuation.resume(throwing: TextRecognitionError.noTextFound)
                } else {
                    continuation.resume(returning: blocks)
                }
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation), options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

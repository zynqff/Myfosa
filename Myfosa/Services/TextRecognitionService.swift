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

/// Распознаёт текстовые блоки на фото. Язык распознавания определяется
/// автоматически (iOS 16+), поэтому явно указывать исходный язык не нужно.
enum TextRecognitionService {
    static func recognizeText(in image: UIImage) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { throw TextRecognitionError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let blocks = observations.compactMap { observation -> RecognizedTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedTextBlock(
                        text: candidate.string,
                        boundingBox: observation.boundingBox,
                        topLeft: observation.topLeft,
                        topRight: observation.topRight,
                        bottomLeft: observation.bottomLeft,
                        bottomRight: observation.bottomRight
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

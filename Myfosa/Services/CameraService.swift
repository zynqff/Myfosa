import AVFoundation
import UIKit

enum CameraError: LocalizedError {
    case captureFailed
    case busy
    var errorDescription: String? {
        switch self {
        case .captureFailed: return "Не удалось сделать снимок."
        case .busy: return "Снимок уже обрабатывается."
        }
    }
}

/// Обёртка над AVCaptureSession: живой превью камеры, съёмка фото, фонарик.
/// Работает с задней широкоугольной камерой, разрешение запрашивается лениво,
/// при первом обращении к экрану «Камера».
@MainActor
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isTorchOn = false
    @Published var permissionDenied = false

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.SiaSoft.Myfosa.camera-session")
    private var photoContinuation: CheckedContinuation<UIImage, Error>?
    private var isConfigured = false

    /// Физическая ориентация устройства (по акселерометру), а не ориентация
    /// интерфейса — экран камеры зафиксирован в портрете, но снимать можно и
    /// держа телефон боком. Без этого фото, снятое в альбомной ориентации,
    /// получает EXIF-метаданные "портрет", и распознавание текста/наложение
    /// перевода на фото затем работает неправильно.
    private var currentVideoOrientation: AVCaptureVideoOrientation = .portrait

    /// iOS 17+: RotationCoordinator сам следит за положением телефона (по
    /// датчикам движения) и подсказывает правильный угол поворота для снимка.
    /// Старое свойство videoOrientation на новых iOS объявлено устаревшим и
    /// при съёмке боком могло оставлять фото «повёрнутым на 90°». Хранится как
    /// Any, чтобы не требовать iOS 17 для всего класса.
    private var rotationCoordinatorStorage: Any?

    private func captureDevice() -> AVCaptureDevice? {
        session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
    }

    private func prepareRotationCoordinator() {
        if #available(iOS 17.0, *) {
            guard rotationCoordinatorStorage == nil, let device = captureDevice() else { return }
            rotationCoordinatorStorage = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
    }

    override init() {
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc nonisolated private func deviceOrientationDidChange() {
        let orientation = UIDevice.current.orientation
        Task { @MainActor in
            switch orientation {
            case .portrait: self.currentVideoOrientation = .portrait
            case .portraitUpsideDown: self.currentVideoOrientation = .portraitUpsideDown
            // AVCaptureVideoOrientation .landscapeLeft/.landscapeRight зеркальны
            // одноимённым UIDeviceOrientation — камера физически развёрнута
            // относительно того, куда "смотрит" верх устройства.
            case .landscapeLeft: self.currentVideoOrientation = .landscapeRight
            case .landscapeRight: self.currentVideoOrientation = .landscapeLeft
            default: break // faceUp/faceDown/unknown — оставляем последнюю известную
            }
        }
    }

    func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
            configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.permissionDenied = false
                        self.configureIfNeeded()
                    } else {
                        self.permissionDenied = true
                    }
                }
            }
        default:
            permissionDenied = true
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else {
            sessionQueue.async { [session] in if !session.isRunning { session.startRunning() } }
            return
        }
        isConfigured = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Используем виртуальную Triple Camera, чтобы iPhone сам переключался
            // между Wide/Ultra Wide/Telephoto. Это особенно важно для макро:
            // при близком объекте система может перейти на Ultra Wide, у которой
            // минимальная дистанция фокусировки значительно меньше.
            let device = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

            if let device,
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)

                do {
                    try device.lockForConfiguration()

                    // Непрерывный автофокус оставляет объектив свободным
                    // для автоматического выбора фокуса на близком объекте.
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    device.isSubjectAreaChangeMonitoringEnabled = true

                    // Для виртуальной камеры разрешаем системе автоматически
                    // выбирать физический объектив, включая переход в макро.
                    if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera {
                        if device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported {
                            device.setPrimaryConstituentDeviceSwitchingBehavior(
                                .auto,
                                restrictedSwitchingBehaviorConditions: []
                            )
                        }
                    }

                    device.unlockForConfiguration()
                } catch {
                    // Если конкретное устройство не позволяет изменить
                    // часть параметров, базовая камера всё равно продолжает работать.
                }
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            // Даём координатору время определить положение телефона до первого снимка.
            Task { @MainActor [weak self] in
                self?.prepareRotationCoordinator()
            }
        }
    }

    func stop() {
        // Выключаем фонарик вместе с сессией: иначе флаг isTorchOn оставался
        // true, а при возврате на экран иконка и реальное состояние расходились.
        if isTorchOn { toggleTorch() }
        sessionQueue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    func toggleTorch() {
        let device = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first ?? AVCaptureDevice.default(for: .video)
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = isTorchOn ? .off : .on
            isTorchOn.toggle()
            device.unlockForConfiguration()
        } catch { /* фонарик недоступен — молча игнорируем */ }
    }

    func capturePhoto() async throws -> UIImage {
        // Повторное нажатие на затвор, пока предыдущий снимок обрабатывается,
        // затирало photoContinuation — первый вызов никогда не завершался
        // (зависшая задача и утечка continuation). Игнорируем лишние нажатия.
        guard photoContinuation == nil else { throw CameraError.busy }
        return try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation
            if let connection = photoOutput.connection(with: .video) {
                prepareRotationCoordinator()
                var applied = false
                if #available(iOS 17.0, *), let coordinator = rotationCoordinatorStorage as? AVCaptureDevice.RotationCoordinator {
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                        applied = true
                    }
                }
                if !applied, connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentVideoOrientation
                }
            }
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(.on) {
                settings.flashMode = isTorchOn ? .on : .off
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        Task { @MainActor in
            if let error {
                photoContinuation?.resume(throwing: error)
                photoContinuation = nil
                return
            }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                photoContinuation?.resume(throwing: CameraError.captureFailed)
                photoContinuation = nil
                return
            }
            // Приводим снимок к ориентации .up и разумному размеру: распознавание
            // и наложение перевода дальше работают с «честными» пикселями.
            photoContinuation?.resume(returning: image.normalizedForOCR())
            photoContinuation = nil
        }
    }
}

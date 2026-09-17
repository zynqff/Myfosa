import SwiftUI
import PhotosUI

/// Вкладка «Фото»: всегда живой превью камеры + съёмка. Раньше здесь была
/// ещё одна капсула-переключатель поверх нативного таб-бара («Перевод» /
/// «Камера» / «История») — она дублировала вкладки «Текст» и «История»
/// нижнего таб-бара и визуально давала «два бара» друг над другом, поэтому
/// убрана целиком; на этом экране остаётся только камера.
struct PhotoTranslateView: View {
    @EnvironmentObject var vm: TranslatorViewModel
    @StateObject private var camera = CameraService()
    @State private var resultImage: UIImage?
    @State private var galleryItem: PhotosPickerItem?
    @State private var showGalleryPicker = false
    @State private var errorMessage: String?

    var body: some View {
        cameraContent
        .background(Color(.systemBackground))
        .onAppear { camera.requestAccessAndConfigure() }
        .onDisappear { camera.stop() }
        .photosPicker(isPresented: $showGalleryPicker, selection: $galleryItem, matching: .images)
        .onChange(of: galleryItem) { newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    resultImage = image
                }
                galleryItem = nil
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { resultImage != nil },
            set: { if !$0 { resultImage = nil } }
        )) {
            if let resultImage {
                PhotoResultView(image: resultImage).environmentObject(vm)
            }
        }
        .alert("Ошибка", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("ОК") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Камера

    private var cameraContent: some View {
        ZStack {
            if camera.permissionDenied {
                permissionDeniedView
            } else {
                CameraPreviewLayerView(session: camera.session)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                languagePairPill
                captureControls
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
        }
    }

    private var languagePairPill: some View {
        HStack(spacing: 10) {
            languageMenu(selection: $vm.sourceLanguage)
            Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.8))
            languageMenu(selection: $vm.targetLanguage)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func languageMenu(selection: Binding<String>) -> some View {
        Menu {
            ForEach(supportedLanguages, id: \.self) { lang in
                Button(languageAutonym(lang)) { selection.wrappedValue = lang }
            }
        } label: {
            HStack(spacing: 4) {
                Text(languageAutonym(selection.wrappedValue)).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .foregroundStyle(.white)
        }
    }

    private var captureControls: some View {
        HStack {
            Button { showGalleryPicker = true } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Button { capturePhoto() } label: {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
            }

            Spacer()

            Button { camera.toggleTorch() } label: {
                Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt.slash")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 32)
    }

    private func capturePhoto() {
        Task {
            do {
                resultImage = try await camera.capturePhoto()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Нет доступа к камере").font(.headline)
            Text("Разрешите доступ к камере в Настройках устройства, чтобы переводить текст с фото.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(BrandGradientButtonStyle())
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

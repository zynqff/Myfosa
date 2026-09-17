import SwiftUI

/// Экран-приглашение скачать модель перевода. Показывается на «Тексте», пока
/// модель ещё не установлена. Пока модель качается, кнопка сама превращается
/// в индикатор прогресса («Загрузка… NN%») — отдельного баннера/прогресс-бара
/// больше нет.
struct DownloadPromptView: View {
    @EnvironmentObject var vm: TranslatorViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)

            // Картинка и текст сгруппированы вместе с небольшим отступом,
            // чтобы между ними не было большого пустого расстояния — крупные
            // отступы (24) остаются только между этой группой, кнопкой и спейсерами.
            VStack(spacing: 4) {
                Image("main-download-model")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 220)

                VStack(spacing: 10) {
                    Text("Скачайте модель, чтобы начать")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("Модель переводчика работает полностью офлайн — без интернета.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
            }

            Button {
                Task {
                    do { try await vm.ensureModel() } catch { vm.errorMessage = error.localizedDescription }
                }
            } label: {
                if vm.isModelDownloading {
                    Text("Загрузка… \(Int(vm.downloader.progress * 100))%")
                } else {
                    Text("Загрузить")
                }
            }
            .buttonStyle(BrandGradientButtonStyle(isDisabled: vm.isModelDownloading))
            .disabled(vm.isModelDownloading)
            .padding(.horizontal, 32)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }
}

import SwiftUI

/// Компактный текстовый перевод с озвучкой — режим «Перевод» на вкладке «Фото».
/// Использует ту же модель (sourceText/preview), что и основной экран «Текст».
struct CompactTranslateView: View {
    @EnvironmentObject var vm: TranslatorViewModel
    @FocusState private var focused: Bool
    private let speech = SpeechSynthesizer()

    var body: some View {
        VStack {
            Spacer()

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    languagePicker(selection: $vm.sourceLanguage)
                    Spacer()
                    Button { vm.swapLanguages() } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(MyfosaTheme.brandStart)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    languagePicker(selection: $vm.targetLanguage)
                }

                TextField("Введите текст", text: $vm.sourceText, axis: .vertical)
                    .font(.system(size: 21, weight: .semibold))
                    .focused($focused)
                    .lineLimit(1...4)
                    .onChange(of: vm.sourceText) { _ in vm.beginTyping() }
                    .onSubmit { vm.finalize(); focused = true }

                if !vm.preview.isEmpty {
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Text(vm.preview)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(MyfosaTheme.brandStart)
                        Spacer()
                        Button {
                            speech.speak(vm.preview, language: vm.targetLanguage)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(MyfosaTheme.brandStart)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal)

            Spacer()
            Spacer()
        }
    }

    private func languagePicker(selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(supportedLanguages, id: \.self) { lang in
                Text(languageAutonym(lang)).tag(lang)
            }
        }
        .pickerStyle(.menu)
        .font(.subheadline.weight(.semibold))
        .labelsHidden()
    }
}

import SwiftUI

struct TranslationView: View {
    @EnvironmentObject var vm: TranslatorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @State private var showSettings = false
    @State private var showClearConfirm = false
    @State private var showClearedSuccess = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.config != nil && !vm.isModelInstalled {
                    DownloadPromptView()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                if vm.history.isEmpty {
                                    emptyState
                                }
                                ForEach(vm.history) { item in
                                    TranslationCardView(item: item)
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }.padding()
                        }
                        // Прокрутка истории вверх скрывает клавиатуру; чтобы показать
                        // её снова — нужно нажать на поле ввода.
                        .scrollDismissesKeyboard(.immediately)
                        .onChange(of: vm.history.count) { _ in
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }

                    translateCard
                }
            }
            .navigationTitle("Перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Очистить") { showClearConfirm = true }
                        .disabled(vm.history.isEmpty)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    if focused {
                        Button { finalizeOrDismiss() } label: { Image(systemName: "checkmark.circle.fill") }
                            .tint(MyfosaTheme.brandStart)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: focused)
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(vm) }
        }
        .onChange(of: scenePhase) { phase in if phase == .background { vm.appDidEnterBackground() } }
        .alert("Ошибка", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) { Button("OK") {} } message: { Text(vm.errorMessage ?? "") }
        .alert(
            "Очистить текущий перевод?",
            isPresented: $showClearConfirm
        ) {
            Button("Очистить", role: .destructive) {
                vm.clearSessionConfirmed()
                showClearedSuccess = true
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить. Переводы, уже сохранённые в «Истории», не затрагиваются.")
        }
        .alert("Готово", isPresented: $showClearedSuccess) {
            Button("ОК") {}
        } message: {
            Text("Текущий перевод очищен.")
        }
    }

    // MARK: - Карточка перевода (композер)
    // Единая карточка: исходный текст сверху, кнопка обмена языками на разделительной
    // линии, перевод снизу. Пока перевод не подтверждён (кнопка «Далее», галочка
    // сверху или Enter), текст можно редактировать и полностью стереть крестиком.
    // После подтверждения карточка очищается, фокус возвращается в неё же —
    // чтобы сразу продолжать печатать следующий перевод, а предыдущий остаётся
    // в истории выше, где доступно только копирование.

    private var translateCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("", selection: $vm.sourceLanguage) {
                        ForEach(supportedLanguages, id: \.self) { lang in
                            Text(languageAutonym(lang)).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.subheadline.weight(.semibold))
                    .labelsHidden()

                    Spacer()

                    if !vm.sourceText.isEmpty {
                        Button {
                            vm.clearInput()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextField("Введите текст", text: $vm.sourceText, axis: .vertical)
                    .font(.system(size: 24, weight: .bold))
                    .focused($focused)
                    .lineLimit(1...6)
                    .onChange(of: vm.sourceText) { _ in
                        vm.beginTyping()
                    }
                    .onSubmit { finalizeOrDismiss() }
            }
            .padding(16)

            ZStack {
                Divider()
                Button { vm.swapLanguages() } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(.regularMaterial, in: Circle())
                        .foregroundStyle(MyfosaTheme.brandStart)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 10) {
                Text(languageAutonym(vm.targetLanguage))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MyfosaTheme.brandStart)

                Text(vm.preview.isEmpty ? "Enter text" : vm.preview)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(vm.preview.isEmpty ? Color.secondary : MyfosaTheme.brandStart)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            if !vm.preview.isEmpty {
                Divider().padding(.horizontal, 16)
                HStack {
                    Button { UIPasteboard.general.string = vm.preview } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Далее") { finalizeOrDismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// Действие для галочки сверху, кнопки «Далее» и Enter в поле ввода.
    /// Если перевод ещё не готов (нечего подтверждать) — просто убирает клавиатуру.
    /// Если готов — подтверждает перевод (уходит в историю) и сразу возвращает
    /// фокус в очищенное поле для следующего перевода.
    private func finalizeOrDismiss() {
        if vm.preview.isEmpty {
            focused = false
        } else {
            vm.finalize()
            focused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(vm.isModelInstalled ? "Начните печатать, чтобы перевести текст" : "Скачайте модель выше, чтобы начать переводить офлайн")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}


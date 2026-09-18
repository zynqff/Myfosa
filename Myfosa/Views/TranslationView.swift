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
                if !vm.isReady {
                    // Проверка наличия модели ещё не завершена — ничего не
                    // рисуем, чтобы не мелькнуть сначала неверным экраном.
                    Color.clear
                } else if vm.config != nil && !vm.isModelInstalled {
                    DownloadPromptView()
                } else {
                    translateCard

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                Color.clear.frame(height: 1).id("top")
                                if vm.history.isEmpty {
                                    emptyState
                                }
                                ForEach(vm.history) { item in
                                    TranslationCardView(item: item, onDelete: {
                                        vm.deleteFromSession(item)
                                    })
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            .padding()
                            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.history.count)
                        }
                        // Прокрутка истории вверх скрывает клавиатуру; чтобы показать
                        // её снова — нужно нажать на поле ввода. Тот же жест сворачивает
                        // открытую свайпом мусорку у карточек.
                        .scrollDismissesKeyboard(.immediately)
                        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                            NotificationCenter.default.post(name: .collapseCardSwipe, object: nil)
                        })
                        .onChange(of: vm.history.count) { _ in
                            // Новые переводы вставляются в начало списка (сразу под
                            // композером) — подскролливаем наверх, если пользователь
                            // до этого успел уйти вглубь старой истории.
                            withAnimation { proxy.scrollTo("top", anchor: .top) }
                        }
                    }
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
        .overlay(alignment: .bottom) {
            if vm.speechRecognizer.isListening {
                stopListeningButton
                    .padding(.bottom, 90)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: vm.speechRecognizer.isListening)
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
    // Тап по нижнему полю (или по его микрофону) мгновенно меняет языки местами и
    // переводит фокус в него — печатать/говорить можно уже на этом языке.
    // После подтверждения карточка очищается, фокус остаётся в ней же (клавиатура
    // не прячется) — чтобы сразу продолжать печатать следующий перевод, а предыдущий
    // остаётся в истории выше, где доступны только озвучка и копирование.

    private var translateCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $vm.sourceLanguage) {
                    ForEach(supportedLanguages, id: \.self) { lang in
                        Text(languageAutonym(lang)).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline.weight(.semibold))
                .labelsHidden()
                .onChange(of: vm.sourceLanguage) { _ in vm.schedulePreview() }

                HStack(alignment: .top, spacing: 8) {
                    TextField(
                        vm.speechRecognizer.isListening ? listeningPlaceholder(for: vm.sourceLanguage) : enterTextPlaceholder(for: vm.sourceLanguage),
                        text: $vm.sourceText, axis: .vertical
                    )
                    .font(.system(size: 24, weight: .bold))
                    .focused($focused)
                    .lineLimit(1...6)
                    .onChange(of: vm.sourceText) { _ in
                        vm.beginTyping()
                    }
                    .onSubmit { finalizeOrDismiss() }

                    // Пока поле пустое — микрофон для голосового ввода. Как
                    // только пользователь начал печатать — на его месте
                    // крестик для быстрой очистки (только у верхнего поля;
                    // у нижнего такого переключения нет).
                    if vm.sourceText.isEmpty {
                        micButton(highlighted: vm.speechRecognizer.isListening) {
                            micTapped(bottom: false)
                        }
                    } else {
                        Button {
                            vm.clearInput()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                // Язык нижнего поля теперь тоже выбирается напрямую (а не
                // только через обмен местами с верхним) — тап по самому
                // пикеру меняет только его, не трогая остальную карточку.
                Picker("", selection: $vm.targetLanguage) {
                    ForEach(supportedLanguages, id: \.self) { lang in
                        Text(languageAutonym(lang)).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .font(.subheadline.weight(.semibold))
                .labelsHidden()
                .tint(MyfosaTheme.brandStart)
                .onChange(of: vm.targetLanguage) { _ in vm.schedulePreview() }

                HStack(alignment: .top, spacing: 8) {
                    Text(vm.preview.isEmpty ? enterTextPlaceholder(for: vm.targetLanguage) : vm.preview)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(vm.preview.isEmpty ? Color.secondary : MyfosaTheme.brandStart)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { selectBottomField() }

                    // Как только начали печатать сверху — микрофону снизу
                    // тоже нечего делать: место просто остаётся пустым.
                    if vm.sourceText.isEmpty {
                        micButton(highlighted: false) {
                            micTapped(bottom: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            if !vm.preview.isEmpty {
                Divider().padding(.horizontal, 16)
                HStack {
                    Button { UIPasteboard.general.string = vm.preview } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(MyfosaTheme.brandStart)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Далее") { finalizeOrDismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(MyfosaTheme.brandStart)
                }
                .padding(16)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func micButton(highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: highlighted ? "mic.fill" : "mic")
                .foregroundStyle(highlighted ? MyfosaTheme.brandStart : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var stopListeningButton: some View {
        Button { vm.stopDictation() } label: {
            Image(systemName: "square.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(MyfosaTheme.brandGradient, in: Circle())
                .shadow(color: MyfosaTheme.brandStart.opacity(0.45), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Тап по нижнему полю — как и нажатие на его микрофон — мгновенно
    /// меняет языки местами (нижний становится верхним/вводимым) и переводит
    /// туда фокус, чтобы можно было сразу печатать на этом языке.
    private func selectBottomField() {
        vm.swapLanguages()
        focused = true
    }

    private func micTapped(bottom: Bool) {
        if vm.speechRecognizer.isListening {
            vm.stopDictation()
            return
        }
        if bottom { vm.swapLanguages() }
        // При старте диктовки прячем клавиатуру — во время разговора она
        // только загораживает экран, а поле и так обновляется вживую.
        focused = false
        vm.startDictation()
    }

    /// Действие для галочки сверху, кнопки «Далее» и Enter в поле ввода.
    /// Если перевод ещё не готов (нечего подтверждать) — просто убирает клавиатуру.
    /// Если готов — подтверждает перевод (уходит в историю) и сразу возвращает
    /// фокус в очищенное поле для следующего перевода, не пряча клавиатуру.
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

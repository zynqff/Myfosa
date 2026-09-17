import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: TranslatorViewModel
    @AppStorage("theme") private var theme = "system"
    @AppStorage("idleTimeout") private var idleTimeout = 180

    var body: some View {
        NavigationStack {
            Form {
                Section("Модель") {
                    LabeledContent("Название", value: vm.config?.model.id ?? "—")
                    LabeledContent("Версия", value: vm.config?.model.version ?? "—")
                    LabeledContent("Размер", value: ByteCountFormatter.string(fromByteCount: vm.config?.model.sizeBytes ?? 0, countStyle: .file))
                    LabeledContent("Статус") {
                        HStack(spacing: 6) {
                            Circle().fill(vm.isModelInstalled ? .green : .secondary).frame(width: 8, height: 8)
                            Text(vm.isModelInstalled ? "Загружена" : "Не загружена")
                        }
                    }

                    Button {
                        Task { await vm.checkForUpdates() }
                    } label: {
                        if isCheckingUpdates {
                            HStack { ProgressView(); Text("Поиск обновления…") }
                        } else {
                            Text("Проверить обновления")
                        }
                    }
                    .disabled(isCheckingUpdates || vm.isModelDownloading || vm.isDeletingModel)

                    Button("Удалить модель", role: .destructive) { vm.requestDeleteModel() }
                        .disabled(!vm.isModelInstalled || vm.isDeletingModel || vm.isModelDownloading)

                    if vm.isModelDownloading {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Загрузка обновления…").font(.subheadline)
                            ProgressView(value: vm.downloader.progress)
                            Text("\(Int(vm.downloader.progress * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    if vm.isDeletingModel {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Удаление модели…").font(.subheadline)
                            ProgressView(value: vm.deleteProgress)
                            Text("\(Int(vm.deleteProgress * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Автовыгрузка") {
                    Picker("Таймаут", selection: $idleTimeout) { Text("30 сек").tag(30); Text("60 сек").tag(60); Text("3 мин").tag(180); Text("5 мин").tag(300); Text("10 мин").tag(600) }
                    Text("Модель выгружается при уходе приложения в фон независимо от таймаута.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Тема") {
                    Picker("Оформление", selection: $theme) { Text("Системная").tag("system"); Text("Светлая").tag("light"); Text("Тёмная").tag("dark") }
                }
                Section { Button("Показать обучение заново") { UserDefaults.standard.set(false, forKey: "onboardingCompleted") } }
            }
            .navigationTitle("Настройки")
            .alert(
                "Удалить модель?",
                isPresented: $vm.showDeleteConfirmation
            ) {
                Button("Удалить", role: .destructive) { vm.confirmDeleteModel() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Файл модели будет удалён с устройства. Чтобы снова переводить офлайн, её нужно будет скачать заново.")
            }
            .alert("Модель удалена", isPresented: $vm.modelDeletedSuccess) {
                Button("ОК") {}
            } message: {
                Text("Удаление завершено успешно.")
            }
            .alert("Обновление установлено", isPresented: $vm.updateInstalledSuccess) {
                Button("ОК") {}
            } message: {
                Text("Модель обновлена до последней версии.")
            }
            .alert("Проверка обновлений", isPresented: isUpToDatePresented) {
                Button("ОК") { vm.updateCheckStatus = .idle }
            } message: {
                Text("У вас установлена последняя версия модели.")
            }
            .alert(
                "Найдено обновление",
                isPresented: isUpdateAvailablePresented
            ) {
                // Конфиг забираем сразу, синхронно, до того как алерт закроется
                // сам и сбросит vm.updateCheckStatus в .idle — иначе к моменту
                // старта Task'а status мог уже смениться и загрузка не запускалась.
                if case .available(let remote) = vm.updateCheckStatus {
                    Button("Загрузить") { Task { await vm.installAvailableUpdate(remote) } }
                }
                Button("Отмена", role: .cancel) { vm.updateCheckStatus = .idle }
            } message: {
                Text(availableUpdateMessage)
            }
            .alert("Не удалось проверить обновления", isPresented: isUpdateFailedPresented) {
                Button("ОК") { vm.updateCheckStatus = .idle }
            } message: {
                Text(updateFailureMessage)
            }
        }
    }

    private var isCheckingUpdates: Bool {
        if case .checking = vm.updateCheckStatus { return true }
        return false
    }

    private var isUpToDatePresented: Binding<Bool> {
        Binding(
            get: { if case .upToDate = vm.updateCheckStatus { return true }; return false },
            set: { if !$0 { vm.updateCheckStatus = .idle } }
        )
    }

    private var isUpdateAvailablePresented: Binding<Bool> {
        Binding(
            get: { if case .available = vm.updateCheckStatus { return true }; return false },
            set: { if !$0 { vm.updateCheckStatus = .idle } }
        )
    }

    private var availableUpdateMessage: String {
        if case .available(let cfg) = vm.updateCheckStatus {
            return "Доступна версия \(cfg.model.version) (\(ByteCountFormatter.string(fromByteCount: cfg.model.sizeBytes, countStyle: .file))). Скачать и установить?"
        }
        return ""
    }

    private var isUpdateFailedPresented: Binding<Bool> {
        Binding(
            get: { if case .failed = vm.updateCheckStatus { return true }; return false },
            set: { if !$0 { vm.updateCheckStatus = .idle } }
        )
    }

    private var updateFailureMessage: String {
        if case .failed(let message) = vm.updateCheckStatus { return message }
        return ""
    }
}

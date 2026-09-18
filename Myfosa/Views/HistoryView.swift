import SwiftUI

/// Постоянный архив переводов. Пополняется автоматически, когда текущая сессия
/// с экрана «Текст» уходит в архив при закрытии/сворачивании приложения —
/// см. TranslatorViewModel.appDidEnterBackground().
struct HistoryView: View {
    @EnvironmentObject var vm: TranslatorViewModel
    @State private var items: [TranslationItem] = []
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(items) { item in
                                TranslationCardView(item: item, onDelete: {
                                    HistoryStore.shared.delete(id: item.id)
                                    reload()
                                })
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Очистить") { showClearConfirm = true }
                        .disabled(items.isEmpty)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .historyArchiveDidChange)) { _ in
            reload()
        }
        .alert(
            "Очистить всю историю переводов?",
            isPresented: $showClearConfirm
        ) {
            Button("Очистить всё", role: .destructive) {
                vm.clearArchivedHistoryConfirmed()
                reload()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить — все сохранённые переводы будут удалены безвозвратно.")
        }
    }

    private func reload() {
        items = HistoryStore.shared.fetchAll()
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 8)

            Image("history-empty")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 280)

            VStack(spacing: 10) {
                Text("Здесь будет история ваших переводов")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Начните переводить, и ваши результаты появятся здесь.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

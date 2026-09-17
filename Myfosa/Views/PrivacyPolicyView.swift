import SwiftUI

/// Заглушка. Заменить `placeholderPolicyText` на финальный текст политики конфиденциальности,
/// когда он будет готов.
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(placeholderPolicyText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Политика конфиденциальности")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var placeholderPolicyText: String {
        """
        Это временный текст политики конфиденциальности. Он будет заменён на финальную версию.

        Приложение Myfosa выполняет перевод текста локально, на самом устройстве. Введённый текст, история переводов и загруженные модели не передаются на серверы приложения и не покидают ваш телефон в процессе перевода.

        Приложение может обращаться к сети для проверки актуальной версии и загрузки моделей перевода. Эти запросы не включают текст, который вы переводите.

        Здесь будет описано: какие данные и с какой целью собираются (если собираются), как они хранятся, передаются ли третьим лицам, как долго хранятся, и как вы можете запросить их удаление.

        По вопросам, связанным с обработкой данных, вы сможете связаться с разработчиком через раздел «Настройки» приложения.
        """
    }
}

#Preview {
    PrivacyPolicyView()
}

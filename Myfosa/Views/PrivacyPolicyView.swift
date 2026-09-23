import SwiftUI

/// Экран «Политика конфиденциальности». Открывается из онбординга (`OnboardingView`).
///
/// Перед релизом проверьте константы в `PolicyConfig` — они подставляются в текст.
/// Текст политики должен совпадать с версией, которую вы публикуете на сайте
/// (её URL указывается в App Store Connect).
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    summaryCard

                    ForEach(PolicyContent.sections) { section in
                        SectionView(section: section)
                    }

                    contactBlock
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .navigationTitle("Конфиденциальность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    // MARK: - Блоки экрана

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Политика конфиденциальности")
                .font(.title2.bold())
            Text("Действует с \(PolicyConfig.effectiveDate) · версия \(PolicyConfig.version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Коротко", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(MyfosaTheme.brandStart)
            Text(LocalizedStringKey(PolicyContent.summary))
                .font(.body)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MyfosaTheme.brandStart.opacity(0.10))
        )
    }

    private var contactBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("12. Контакты")
                .font(.headline)
            Text(PolicyConfig.developerName)
                .font(.body)
            if let url = PolicyConfig.mailURL {
                Link(PolicyConfig.contactEmail, destination: url)
                    .font(.body)
                    .tint(MyfosaTheme.brandStart)
            } else {
                Text(PolicyConfig.contactEmail)
                    .font(.body)
            }
        }
    }
}

// MARK: - Настройки, которые нужно проверить перед релизом

private enum PolicyConfig {
    /// Название разработчика (как в App Store Connect).
    static let developerName = "SiaSoft"
    /// Почта для вопросов о конфиденциальности.
    static let contactEmail = "[EMAIL]"
    /// Дата вступления в силу текущей версии политики.
    static let effectiveDate = "23 сентября 2026"
    static let version = "1.0"

    static var mailURL: URL? {
        guard contactEmail.contains("@") else { return nil }
        return URL(string: "mailto:\(contactEmail)")
    }
}

// MARK: - Модель контента

private enum PolicyBlock {
    case text(String)
    case bullets([String])
}

private struct PolicySection: Identifiable {
    let id: Int
    let title: String
    let blocks: [PolicyBlock]
}

private struct SectionView: View {
    let section: PolicySection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(section.id). \(section.title)")
                .font(.headline)

            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let string):
                    Text(LocalizedStringKey(string))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(MyfosaTheme.brandStart)
                                Text(LocalizedStringKey(item))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.body)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Текст политики

private enum PolicyContent {
    static let summary = """
    Myfosa переводит текст **на вашем устройстве**. Всё, что вы вводите, произносите или фотографируете, \
    обрабатывается локально и не отправляется на серверы разработчика. В приложении нет аккаунтов, рекламы \
    и аналитики, а мы не получаем ваши тексты, голос, фото или историю переводов.
    """

    // Раздел 12 («Контакты») выводится отдельно — см. `contactBlock`.
    static let sections: [PolicySection] = [
        PolicySection(id: 1, title: "Кто мы", blocks: [
            .text("Приложение Myfosa (далее — «Приложение») разрабатывает \(PolicyConfig.developerName) (далее — «мы»). Контакты для вопросов о конфиденциальности указаны в конце документа.")
        ]),

        PolicySection(id: 2, title: "Какие данные обрабатывает Приложение", blocks: [
            .text("Все данные из этого раздела обрабатываются только на вашем устройстве."),
            .bullets([
                "**Текст и перевод.** То, что вы вводите или диктуете, и результат перевода. Нужны, чтобы выполнить перевод.",
                "**История переводов.** Исходный текст, перевод, языки и время. Хранится в локальной базе Приложения, чтобы вы могли вернуться к прошлым переводам.",
                "**Изображения.** Снимки с камеры или из галереи используются, чтобы распознать на них текст. Они обрабатываются в памяти, Приложение не сохраняет ваши фотографии.",
                "**Настройки.** Тема, таймаут выгрузки модели, отметка о прохождении обучения.",
                "**Модель перевода.** Файл модели и служебная информация о ней (название, версия, размер) для работы без интернета."
            ]),
            .text("Переводы текущей сессии попадают в постоянную историю, когда вы сворачиваете Приложение. Отдельную запись или всю историю можно удалить на экране «История». Удаление необратимо.")
        ]),

        PolicySection(id: 3, title: "Чего мы не делаем", blocks: [
            .bullets([
                "Не собираем и не передаём на свои серверы ваши тексты, аудио, изображения и историю переводов.",
                "Не создаём аккаунтов и не просим email, телефон или имя.",
                "Не используем рекламу, рекламные идентификаторы и отслеживание между приложениями.",
                "Не используем сторонние SDK для аналитики или сбора статистики.",
                "Не продаём данные и не передаём их третьим лицам."
            ])
        ]),

        PolicySection(id: 4, title: "Обращения к сети", blocks: [
            .text("Интернет нужен Приложению только для двух целей:"),
            .bullets([
                "**Проверка конфигурации.** Приложение запрашивает небольшой файл с версией модели, адресом загрузки и минимальной версией Приложения. Он размещён на сервисе Hugging Face. Последняя полученная конфигурация сохраняется на устройстве.",
                "**Загрузка и обновление модели перевода.** После загрузки перевод работает без интернета."
            ]),
            .text("Эти запросы **не содержат** ваши тексты, историю и другие пользовательские данные. Как и при любом обращении к сайту, сервер, который отвечает на запрос, технически видит IP-адрес устройства и служебные данные соединения. Их обработка регулируется политикой самого сервиса. Мы не получаем к ним доступа и не связываем их с вами.")
        ]),

        PolicySection(id: 5, title: "Разрешения", blocks: [
            .text("Приложение запрашивает доступ только к тому, что нужно для конкретной функции. Любое разрешение можно отозвать в «Настройки iOS → Myfosa»."),
            .bullets([
                "**Камера.** Чтобы сфотографировать текст и перевести его. Распознавание текста на снимке выполняется на устройстве.",
                "**Микрофон и распознавание речи.** Для голосового ввода. Приложение просит iOS выполнять распознавание **на устройстве**, если это поддерживается для выбранного языка. Если для языка такой возможности нет, iOS может отправлять аудио на серверы Apple. В этом случае обработка идёт по правилам Apple, а к записи у нас нет доступа.",
                "**Фотографии.** Если вы выбираете снимок из галереи, Приложение получает только выбранное изображение, а не всю медиатеку."
            ]),
            .text("Озвучивание перевода использует встроенный синтезатор речи iOS.")
        ]),

        PolicySection(id: 6, title: "Буфер обмена", blocks: [
            .text("Когда вы нажимаете «Копировать», перевод помещается в буфер обмена iOS. Другие приложения могут прочитать его по правилам системы. Мы не читаем буфер обмена и ничего не вставляем в него без вашего действия.")
        ]),

        PolicySection(id: 7, title: "Хранение, удаление и резервные копии", blocks: [
            .bullets([
                "Данные хранятся на вашем устройстве, пока вы не удалите их сами или не удалите Приложение.",
                "**История** удаляется по одной записи или целиком на экране «История».",
                "**Модель** удаляется в «Настройки → Удалить модель». Файл модели не входит в резервные копии.",
                "**Удаление Приложения** стирает все его локальные данные.",
                "Локальная база истории может входить в резервную копию устройства, которую вы создаёте средствами Apple (iCloud или компьютер). Такие копии находятся под вашим контролем и правилами Apple, мы к ним доступа не имеем. Если не хотите, чтобы история попадала в копию, очистите её в Приложении."
            ])
        ]),

        PolicySection(id: 8, title: "Безопасность", blocks: [
            .text("Поскольку данные остаются на устройстве, их защита в первую очередь зависит от защиты самого устройства: код-пароля, Face ID или Touch ID и обновлений iOS. При загрузке файл модели проверяется на целостность (размер и контрольная сумма), если они указаны в конфигурации.")
        ]),

        PolicySection(id: 9, title: "Дети", blocks: [
            .text("Приложение не собирает персональные данные никого, включая детей. Все данные остаются на устройстве.")
        ]),

        PolicySection(id: 10, title: "Ваши права", blocks: [
            .text("Мы не получаем и не храним ваши персональные данные, поэтому у нас нечего запрашивать, исправлять или удалять. Всем содержимым Приложения вы управляете сами (см. раздел 7). Если вы всё же считаете, что мы обрабатываем ваши данные, напишите нам. Мы ответим в разумный срок и с учётом требований применимого законодательства, включая GDPR и законодательство о персональных данных вашей страны.")
        ]),

        PolicySection(id: 11, title: "Изменения политики", blocks: [
            .text("Мы можем обновлять эту политику, например при появлении новых функций. Актуальная версия всегда доступна в Приложении. Дата вверху документа показывает, когда политика менялась в последний раз. Если изменения существенны, мы сообщим о них в Приложении. Мы не начнём собирать данные без вашего согласия.")
        ])
    ]
}

#Preview {
    PrivacyPolicyView()
}

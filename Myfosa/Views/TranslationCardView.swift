import SwiftUI

/// Карточка одного перевода в списке — используется и на экране «Текст»
/// (текущая сессия), и на экране «История» (постоянный архив).
struct TranslationCardView: View {
    let item: TranslationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(languageAutonym(item.sourceLang)).font(.caption).foregroundStyle(.secondary)
            Text(item.source).font(.system(size: 19, weight: .semibold))

            Divider()

            HStack {
                Text(languageAutonym(item.targetLang)).font(.caption).foregroundStyle(MyfosaTheme.brandStart)
                Spacer()
                Button { UIPasteboard.general.string = item.translated } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            Text(item.translated).font(.system(size: 19, weight: .semibold)).foregroundStyle(MyfosaTheme.brandStart)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

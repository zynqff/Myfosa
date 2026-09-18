import SwiftUI

/// Карточка одного завершённого перевода — используется и в ленте на экране
/// «Перевод» (уже зафиксированные карточки текущей сессии), и на экране
/// «История». Только для чтения: озвучка (play/pause) по каждому языку,
/// копирование и удаление свайпом влево в два шага.
struct TranslationCardView: View {
    let item: TranslationItem
    /// nil — свайп на удаление отключён (карточка не входит в редактируемую ленту).
    var onDelete: (() -> Void)? = nil

    @EnvironmentObject var vm: TranslatorViewModel
    @State private var dragOffset: CGFloat = 0
    @State private var revealStage: RevealStage = .closed

    private enum RevealStage { case closed, compact, full }
    private let compactWidth: CGFloat = 72
    private let fullWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .trailing) {
            if onDelete != nil {
                deleteBackground
            }
            card
                .offset(x: dragOffset)
                .gesture(onDelete == nil ? nil : dragGesture)
        }
        .onReceive(NotificationCenter.default.publisher(for: .collapseCardSwipe)) { _ in collapse() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            languageRow(text: item.source, language: item.sourceLang, id: item.id.uuidString + "-src", isTarget: false)

            Divider()

            languageRow(text: item.translated, language: item.targetLang, id: item.id.uuidString + "-dst", isTarget: true)

            HStack {
                Button {
                    UIPasteboard.general.string = item.translated
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(MyfosaTheme.brandStart)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Непрозрачный фон всегда — не только когда за карточкой открыта
        // мусорка. .thinMaterial просвечивает, и когда пропущена лента
        // истории (или что-то ещё) за карточкой, это выглядит грязно.
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func languageRow(text: String, language: String, id: String, isTarget: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(languageAutonym(language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isTarget ? MyfosaTheme.brandStart : .secondary)
                Text(text)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isTarget ? MyfosaTheme.brandStart : .primary)
            }
            Spacer(minLength: 8)
            playButton(text: text, language: language, id: id, isTarget: isTarget)
        }
    }

    private func playButton(text: String, language: String, id: String, isTarget: Bool) -> some View {
        let isSpeaking = vm.speech.speakingID == id
        return Button {
            vm.speech.toggle(text, language: language, id: id)
        } label: {
            Image(systemName: isSpeaking ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(isTarget ? MyfosaTheme.brandStart : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Свайп для удаления (в два шага, как в приложении Почта)

    private var deleteBackground: some View {
        HStack {
            Spacer()
            Button {
                collapse()
                onDelete?()
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.white)
                    .frame(maxWidth: revealStage == .full ? .infinity : compactWidth, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 84)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 20))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = revealStage == .compact ? -compactWidth : 0
                // На первом свайпе (из закрытого состояния) не даём утянуть
                // карточку сразу до полного удаления — только до компактной
                // мусорки. До полного удаления нужен отдельный, второй свайп.
                let maxReach: CGFloat = revealStage == .compact ? -fullWidth : (-compactWidth - 24)
                dragOffset = max(min(0, base + value.translation.width), maxReach)
            }
            .onEnded { _ in
                switch revealStage {
                case .closed:
                    if dragOffset <= -40 {
                        revealStage = .compact
                        withAnimation(.spring(response: 0.3)) { dragOffset = -compactWidth }
                    } else {
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                    }
                case .compact:
                    if dragOffset <= -160 {
                        revealStage = .full
                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = -fullWidth }
                        onDelete?()
                    } else if dragOffset > -compactWidth / 2 {
                        // Уже открытая (зафиксированная) мусорка: свайп
                        // вправо обратно к началу — закрываем карточку
                        // полностью, а не снова "прилипаем" к компактному виду.
                        collapse()
                    } else {
                        withAnimation(.spring(response: 0.3)) { dragOffset = -compactWidth }
                    }
                case .full:
                    break
                }
            }
    }

    /// Сворачивает открытую свайпом мусорку обратно — вызывается при
    /// прокрутке ленты, смене вкладки или после удаления.
    private func collapse() {
        guard revealStage != .closed else { return }
        revealStage = .closed
        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
    }
}

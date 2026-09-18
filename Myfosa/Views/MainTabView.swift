import SwiftUI

/// Корневой экран приложения после онбординга — стандартный (нативный) нижний
/// таб-бар iOS с тремя вкладками, в фирменных цветах (см. MyfosaApp.init).
struct MainTabView: View {
    enum Tab { case translate, camera, history }

    @State private var selection: Tab = .translate

    var body: some View {
        TabView(selection: $selection) {
            TranslationView()
                .tabItem { Label("Перевод", systemImage: "text.bubble") }
                .tag(Tab.translate)

            PhotoTranslateView()
                .tabItem { Label("Камера", systemImage: "camera") }
                .tag(Tab.camera)

            HistoryView()
                .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
        }
        .onChange(of: selection) { _ in
            // Переключение вкладки — сигнал свернуть открытую свайпом мусорку
            // у карточек перевода, если она была открыта.
            NotificationCenter.default.post(name: .collapseCardSwipe, object: nil)
        }
    }
}

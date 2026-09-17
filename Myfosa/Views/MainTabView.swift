import SwiftUI

/// Корневой экран приложения после онбординга — стандартный (нативный) нижний
/// таб-бар iOS с тремя вкладками.
struct MainTabView: View {
    var body: some View {
        TabView {
            TranslationView()
                .tabItem { Label("Текст", systemImage: "text.bubble") }

            PhotoTranslateView()
                .tabItem { Label("Фото", systemImage: "camera") }

            HistoryView()
                .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }
        }
    }
}

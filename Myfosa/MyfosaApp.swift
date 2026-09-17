import SwiftUI
import UIKit

@main
struct MyfosaApp: App {
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("theme") private var theme = "system"
    @StateObject private var viewModel = TranslatorViewModel()

    init() {
        // Некоторые нативные UIKit-элементы (таб-бар, навигационная панель,
        // системные алерты) берут цвет из window.tintColor, а не напрямую из
        // SwiftUI-модификатора `.tint()`/ассета AccentColor — без этого они
        // остаются системно-синими, даже когда весь остальной интерфейс уже
        // фирменного фиолетового цвета. Задаём его явно на уровне appearance,
        // чтобы выбранная вкладка таб-бара и подобные элементы тоже были фиолетовыми.
        let brand = UIColor(MyfosaTheme.brandStart)
        UITabBar.appearance().tintColor = brand
        UINavigationBar.appearance().tintColor = brand
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted { MainTabView() } else { OnboardingView() }
            }
            .environmentObject(viewModel)
            .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
            // Фирменный фиолетовый как акцент по умолчанию для всего приложения —
            // подхватывается и системными контролами (Picker, кнопки в Form,
            // ProgressView), и распространяется на модально показанные экраны
            // (например, Настройки открываются через .sheet).
            .tint(MyfosaTheme.brandStart)
        }
    }
}

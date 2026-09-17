import SwiftUI

/// Фирменные цвета Myfosa. Тот же фиолетовый, что используется в онбординге —
/// вынесен сюда, чтобы не дублировать RGB-значения по разным экранам.
enum MyfosaTheme {
    static let brandStart = Color(red: 0.49, green: 0.42, blue: 0.93)
    static let brandEnd = Color(red: 0.4, green: 0.32, blue: 0.88)

    static let brandGradient = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// Кнопка-пилюля с фирменным градиентом — используется на экранах онбординга
/// и на экране загрузки модели.
struct BrandGradientButtonStyle: ButtonStyle {
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isDisabled ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(MyfosaTheme.brandGradient))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

import SwiftUI

struct OnboardingView: View {
    @AppStorage("onboardingCompleted") private var completed = false
    @State private var page = 0
    @State private var showPrivacyPolicy = false

    private let pages: [OnboardPageData] = [
        .init(
            image: "onboarding-type",
            title: "Печатайте текст",
            text: "Перевод запускается локально на устройстве. Ваши данные не покидают телефон.",
            isConsent: false
        ),
        .init(
            image: "onboarding-languages",
            title: "Выберите языки",
            text: "Доступно 33 языка. Выберите исходный и целевой язык.",
            isConsent: false
        ),
        .init(
            image: "onboarding-translate",
            title: "Перевод по мере ввода",
            text: "Нажмите «Далее» или Enter, чтобы зафиксировать карточку перевода.",
            isConsent: false
        ),
        .init(
            image: "onboarding-unload",
            title: "Настройте выгрузку",
            text: "Модель выгружается из памяти в фоне и по таймауту.",
            isConsent: false
        ),
        .init(
            image: "onboarding-theme",
            title: "Тема",
            text: "Выберите светлую, тёмную или системную тему по вашему вкусу.",
            isConsent: false
        ),
        .init(
            image: "onboarding-photo",
            title: "Перевод по фото",
            text: "Сфотографируйте текст или загрузите изображение из галереи. Наведите камеру на вывеску, документ или рукописный текст — приложение распознает и переведёт его автоматически.",
            isConsent: false
        ),
        .init(
            image: "onboarding-privacy",
            title: "Всё готово",
            text: "",
            isConsent: true
        )
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    OnboardPage(data: pages[index], showPrivacyPolicy: $showPrivacyPolicy)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            PageDots(count: pages.count, current: page)
                .padding(.top, 8)

            Button {
                if isLastPage {
                    completed = true
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLastPage ? "Начать" : "Далее")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.49, green: 0.42, blue: 0.93), Color(red: 0.4, green: 0.32, blue: 0.88)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}

private struct OnboardPageData {
    let image: String
    let title: String
    let text: String
    let isConsent: Bool
}

private struct OnboardPage: View {
    let data: OnboardPageData
    @Binding var showPrivacyPolicy: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.49, green: 0.42, blue: 0.93).opacity(0.16), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 170
                        )
                    )
                    .frame(width: 300, height: 300)

                Image(data.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
            }

            VStack(spacing: 12) {
                Text(data.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                if data.isConsent {
                    consentText
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                } else {
                    Text(data.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 20)
    }

    /// «Используя наше приложение, вы соглашаетесь с Политикой конфиденциальности»,
    /// где «Политика конфиденциальности» — кликабельная ссылка, открывающая PrivacyPolicyView.
    private var consentText: some View {
        let markdown = "Используя наше приложение, вы соглашаетесь с [Политикой конфиденциальности](onboarding-privacy-policy://open)."
        let attributed = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)

        return Text(attributed)
            .foregroundStyle(.secondary)
            .tint(Color(red: 0.49, green: 0.42, blue: 0.93))
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "onboarding-privacy-policy" {
                    showPrivacyPolicy = true
                    return .handled
                }
                return .systemAction
            })
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color(red: 0.49, green: 0.42, blue: 0.93) : Color(.systemGray4))
                    .frame(width: index == current ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
    }
}

#Preview {
    OnboardingView()
}

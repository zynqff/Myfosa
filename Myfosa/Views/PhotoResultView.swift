import SwiftUI
import AVFoundation

/// Показывает сделанное/выбранное фото с переводом, наложенным поверх области
/// исходного текста. Вся область перевода теперь является одним сплошным полем:
/// внутри сохраняются переносы строк и интервалы между строками исходного текста.
struct PhotoResultView: View {
    let image: UIImage
    @EnvironmentObject var vm: TranslatorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isProcessing = true
    @State private var isPreparingModel = false
    @State private var errorMessage: String?
    @State private var translatedText = ""
    @State private var textRect: CGRect?
    @State private var zoomScale: CGFloat = 1
    @State private var contentOffset: CGSize = .zero
    @State private var gestureStartScale: CGFloat = 1
    @State private var gestureStartOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let displayRect = AVMakeRect(
                    aspectRatio: image.size,
                    insideRect: CGRect(origin: .zero, size: geo.size)
                )

                ZStack {
                    Color.black.ignoresSafeArea()

                    // Фото и перевод масштабируются как единое полотно. Поэтому при
                    // увеличении пользователь видит именно «переведённое фото», а
                    // не отдельный увеличенный текстовый блок.
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        if let textRect, !translatedText.isEmpty {
                            let field = displayField(for: textRect, in: displayRect)
                            translatedField(field)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(zoomScale)
                    .offset(contentOffset)
                    .contentShape(Rectangle())
                    .gesture(zoomGesture(in: geo.size))
                    .simultaneousGesture(panGesture(in: geo.size))
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if zoomScale > 1.05 {
                                zoomScale = 1
                                contentOffset = .zero
                            } else {
                                zoomScale = 2
                            }
                        }
                    }

                    // Пока модель ещё не готова (не скачана и/или не загружена в
                    // память) — показываем это отдельно от распознавания.
                    if isPreparingModel {
                        VStack(spacing: 10) {
                            if vm.isModelDownloading {
                                ProgressView(value: vm.downloader.progress)
                                    .frame(width: 160)
                                Text("Загружаем модель… \(Int(vm.downloader.progress * 100))%")
                                    .font(.footnote)
                            } else {
                                ProgressView()
                                Text("Подготавливаем модель…")
                                    .font(.footnote)
                            }
                        }
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if isProcessing && translatedText.isEmpty {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Распознаём и переводим…")
                                .font(.footnote)
                        }
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .navigationTitle("Фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = translatedText
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(translatedText.isEmpty)
                }
            }
        }
        .task { await process() }
        .alert("Не удалось перевести фото", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Готово") { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private struct DisplayField {
        let rect: CGRect
        let angle: Double
        let lineCount: Int
    }

    /// Единое поле строится по всей области распознанного текста, а не отдельно
    /// для каждой строки. Поэтому фон перевода получается сплошным и внутри него
    /// можно нормально управлять переносами, отступами и межстрочным интервалом.
    private func displayField(for rect: CGRect, in displayRect: CGRect) -> DisplayField {
        let field = CGRect(
            x: displayRect.minX + rect.minX * displayRect.width,
            y: displayRect.minY + (1 - rect.maxY) * displayRect.height,
            width: rect.width * displayRect.width,
            height: rect.height * displayRect.height
        )

        let lines = max(1, translatedText.components(separatedBy: "\n").count)
        return DisplayField(rect: field, angle: 0, lineCount: lines)
    }

    private func translatedField(_ field: DisplayField) -> some View {
        // Поле получает размер всей области исходного текста. Если перевод длиннее
        // оригинала, шрифт автоматически уменьшается до размера, при котором весь
        // текст помещается внутрь поля — без обрезания и выхода за его границы.
        let lineHeight = max(18, field.rect.height / CGFloat(field.lineCount))
        let baseFontSize = max(13, min(22, lineHeight * 0.72))
        let horizontalInset = max(8, min(16, field.rect.width * 0.025))
        let verticalInset = max(7, min(14, lineHeight * 0.18))
        let availableWidth = max(1, field.rect.width - horizontalInset * 2)
        let availableHeight = max(1, field.rect.height - verticalInset * 2)
        let fontSize = fittingFontSize(
            for: translatedText,
            maxWidth: availableWidth,
            maxHeight: availableHeight,
            preferred: baseFontSize
        )

        return Text(translatedText)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.13))
            .multilineTextAlignment(.leading)
            .lineSpacing(max(1, lineHeight * 0.10))
            .allowsTightening(true)
            .minimumScaleFactor(0.35)
            .frame(
                width: availableWidth,
                height: availableHeight,
                alignment: .leading
            )
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            // Полупрозрачный тёплый белый: перевод остаётся читаемым,
            // а изображение под ним мягко просвечивает.
            .background(
                Color(red: 1.0, green: 0.975, blue: 0.93).opacity(0.92),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .frame(width: max(1, field.rect.width), height: max(1, field.rect.height))
            .rotationEffect(.radians(field.angle))
            .position(x: field.rect.midX, y: field.rect.midY)
    }

    private func fittingFontSize(
        for text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        preferred: CGFloat
    ) -> CGFloat {
        let minimum: CGFloat = 7
        guard maxWidth > 1, maxHeight > 1, !text.isEmpty else { return minimum }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: preferred, weight: .semibold)
        ]

        func fits(_ size: CGFloat) -> Bool {
            var attrs = attributes
            attrs[.font] = UIFont.systemFont(ofSize: size, weight: .semibold)
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            )
            return rect.height <= maxHeight + 1
        }

        if fits(preferred) { return preferred }
        if !fits(minimum) { return minimum }

        var low = minimum
        var high = preferred
        for _ in 0..<10 {
            let mid = (low + high) / 2
            if fits(mid) {
                low = mid
            } else {
                high = mid
            }
        }
        return low
    }

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposed = gestureStartScale * value
                zoomScale = min(max(proposed, 1), 5)
                if zoomScale <= 1 {
                    contentOffset = .zero
                }
            }
            .onEnded { _ in
                gestureStartScale = zoomScale
                if zoomScale <= 1.01 {
                    withAnimation(.easeOut(duration: 0.15)) {
                        zoomScale = 1
                        contentOffset = .zero
                    }
                    gestureStartScale = 1
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard zoomScale > 1 else { return }
                if abs(value.translation.width) < 1 && abs(value.translation.height) < 1 {
                    gestureStartOffset = contentOffset
                }
                let maxX = max(0, (size.width * (zoomScale - 1)) / 2)
                let maxY = max(0, (size.height * (zoomScale - 1)) / 2)
                let x = gestureStartOffset.width + value.translation.width
                let y = gestureStartOffset.height + value.translation.height
                contentOffset = CGSize(
                    width: min(max(x, -maxX), maxX),
                    height: min(max(y, -maxY), maxY)
                )
            }
            .onEnded { _ in
                gestureStartOffset = contentOffset
            }
    }

    private func process() async {
        do {
            if !vm.isModelInstalled || vm.modelState == .unloaded {
                isPreparingModel = true
                do {
                    try await vm.ensureModelReady()
                } catch {
                    isPreparingModel = false
                    errorMessage = "Модель ещё не загружена. Дождитесь окончания загрузки, чтобы переводить фото."
                    isProcessing = false
                    return
                }
                isPreparingModel = false
            }

            let recognized = try await TextRecognitionService.recognizeText(in: image)

            // Собираем весь распознанный текст в один документ. Перевод выполняется
            // одним вызовом, поэтому модель получает структуру абзаца/строк, а на
            // экране мы можем отрисовать всё одним сплошным полем.
            let sourceText = recognized
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !sourceText.isEmpty else {
                throw TextRecognitionError.noTextFound
            }

            let translated = try await vm.translateStandalone(
                sourceText,
                from: vm.sourceLanguage,
                to: vm.targetLanguage
            )

            // Объединяем bounding box всех найденных строк в одну область.
            let union = recognized
                .map(\.boundingBox)
                .dropFirst()
                .reduce(recognized[0].boundingBox) { $0.union($1) }

            withAnimation(.easeOut(duration: 0.2)) {
                textRect = union
                translatedText = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            if translatedText.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isProcessing = false
    }
}

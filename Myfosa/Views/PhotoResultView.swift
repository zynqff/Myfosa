import SwiftUI
import AVFoundation

/// Показывает сделанное/выбранное фото с переводом, наложенным поверх
/// исходного текста — на том же месте, где он был на снимке.
struct PhotoResultView: View {
    let image: UIImage
    @EnvironmentObject var vm: TranslatorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isProcessing = true
    @State private var isPreparingModel = false
    @State private var errorMessage: String?
    @State private var blocks: [TranslatedBlock] = []

    private struct TranslatedBlock: Identifiable {
        let id = UUID()
        /// Четыре угла строки текста в нормализованных координатах Vision (0...1,
        /// начало координат — левый нижний угол). Храним именно углы, а не
        /// осе-выровненный bounding box — иначе наклонную строку (снимок сделан
        /// не совсем ровно или сам текст на фото повёрнут) невозможно правильно
        /// наложить: перевод рисовался бы строго горизонтально и "съезжал" в сторону.
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomLeft: CGPoint
        let bottomRight: CGPoint
        let text: String
    }

    /// Прямоугольник перевода на экране, посчитанный по факту вдоль исходной строки:
    /// центр, размеры и угол поворота — а не по осе-выровненному bounding box.
    private struct DisplayQuad {
        let center: CGPoint
        let width: CGFloat
        let height: CGFloat
        /// Угол наклона строки относительно горизонтали, в радианах.
        let angle: Double
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let displayRect = AVMakeRect(
                    aspectRatio: image.size,
                    insideRect: CGRect(origin: .zero, size: geo.size)
                )

                ZStack {
                    Color.black.ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    ForEach(blocks) { block in
                        let quad = displayQuad(for: block, in: displayRect)
                        Text(block.text)
                            .font(.system(size: max(11, quad.height * 0.62), weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 4)
                            .frame(width: quad.width, height: quad.height)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(4)
                            .rotationEffect(.radians(quad.angle), anchor: .center)
                            .position(quad.center)
                            .transition(.opacity)
                    }

                    // Пока модель ещё не готова (не скачана и/или не загружена в
                    // память) — показываем это отдельно от «Распознаём и
                    // переводим…», с реальным прогрессом загрузки, если она идёт.
                    if isPreparingModel {
                        VStack(spacing: 10) {
                            if vm.isModelDownloading {
                                ProgressView(value: vm.downloader.progress)
                                    .frame(width: 160)
                                Text("Загружаем модель… \(Int(vm.downloader.progress * 100))%").font(.footnote)
                            } else {
                                ProgressView()
                                Text("Подготавливаем модель…").font(.footnote)
                            }
                        }
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    } else if isProcessing && blocks.isEmpty {
                        // Индикатор держим на экране только пока не появился хотя бы
                        // один переведённый блок — как только первая фраза готова,
                        // прячем «Распознаём и переводим…» и дальше блоки просто
                        // проступают по одному поверх фото, по мере перевода.
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Распознаём и переводим…").font(.footnote)
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
                        UIPasteboard.general.string = blocks.map(\.text).joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(blocks.isEmpty)
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

    /// Переводит одну точку Vision (нормализованная, левый нижний угол) в точку
    /// на экране (верхний левый угол), с учётом того, что изображение показано
    /// в режиме .scaledToFit и может иметь чёрные поля по краям.
    private func displayPoint(for visionPoint: CGPoint, in displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: displayRect.minX + visionPoint.x * displayRect.width,
            y: displayRect.minY + (1 - visionPoint.y) * displayRect.height
        )
    }

    /// Строит прямоугольник перевода строго по четырём углам исходной строки,
    /// а не по осе-выровненному bounding box — поэтому если строка на фото идёт
    /// под наклоном (снимок сделан неровно или сам текст на фото повёрнут),
    /// плашка с переводом поворачивается на тот же угол и ложится точно поверх
    /// оригинала, а не горизонтально "в сторону" от него.
    private func displayQuad(for block: TranslatedBlock, in displayRect: CGRect) -> DisplayQuad {
        let tl = displayPoint(for: block.topLeft, in: displayRect)
        let tr = displayPoint(for: block.topRight, in: displayRect)
        let bl = displayPoint(for: block.bottomLeft, in: displayRect)
        let br = displayPoint(for: block.bottomRight, in: displayRect)

        let center = CGPoint(x: (tl.x + tr.x + bl.x + br.x) / 4, y: (tl.y + tr.y + bl.y + br.y) / 4)
        let topWidth = hypot(tr.x - tl.x, tr.y - tl.y)
        let bottomWidth = hypot(br.x - bl.x, br.y - bl.y)
        let leftHeight = hypot(bl.x - tl.x, bl.y - tl.y)
        let rightHeight = hypot(br.x - tr.x, br.y - tr.y)
        let angle = atan2(tr.y - tl.y, tr.x - tl.x)

        return DisplayQuad(
            center: center,
            width: (topWidth + bottomWidth) / 2,
            height: (leftHeight + rightHeight) / 2,
            angle: Double(angle)
        )
    }

    private func process() async {
        do {
            // Модель может быть ещё не скачана (или скачана, но не загружена в
            // память) — в этом случае раньше перевод сразу падал с технической
            // ошибкой вида «Загрузка уже выполняется». Теперь явно готовим модель
            // здесь: если она уже качается (например, запущено с экрана «Текст»)
            // — просто дожидаемся той же загрузки и показываем её прогресс, если
            // нет — запускаем скачивание сами.
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
            var lastBlockError: Error?
            for item in recognized {
                do {
                    let text = try await vm.translateStandalone(item.text, from: vm.sourceLanguage, to: vm.targetLanguage)
                    // Добавляем блок сразу, как только он готов, а не все разом
                    // в конце — перевод проступает по мере распознавания и
                    // перевода каждой строки, и общий индикатор загрузки
                    // прячется, как только появился первый блок (см. body).
                    withAnimation(.easeOut(duration: 0.2)) {
                        blocks.append(TranslatedBlock(
                            topLeft: item.topLeft,
                            topRight: item.topRight,
                            bottomLeft: item.bottomLeft,
                            bottomRight: item.bottomRight,
                            text: text
                        ))
                    }
                } catch {
                    // Не удалось перевести одну строку — не обрываем из-за неё
                    // весь перевод страницы, просто пропускаем эту строку.
                    // Чем больше строк на фото, тем выше шанс споткнуться на
                    // одной из них, поэтому раньше это часто ломало весь снимок.
                    lastBlockError = error
                }
            }
            // Ошибку показываем только если НИ ОДНОЙ строки не удалось перевести.
            // Если хотя бы один блок уже на экране — не показываем алерт поверх
            // уже переведённого текста, даже если остальные строки не перевелись.
            if blocks.isEmpty, let lastBlockError {
                errorMessage = lastBlockError.localizedDescription
            }
        } catch {
            if blocks.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isProcessing = false
    }
}

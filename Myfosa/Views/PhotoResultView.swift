import SwiftUI
import AVFoundation

/// Показывает сделанное/выбранное фото с переводом, наложенным поверх области
/// исходного текста. Связные строки объединяются в одно поле, а разнесённые
/// области текста получают отдельные поля.
struct PhotoResultView: View {
    let image: UIImage
    @EnvironmentObject var vm: TranslatorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isProcessing = true
    @State private var isPreparingModel = false
    @State private var hasStartedProcessing = false
    @State private var processingTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var translatedText = ""
    @State private var displayFields: [DisplayField] = []
    @State private var progressiveTranslations: [String] = []
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

                        if !displayFields.isEmpty {
                            ForEach(layoutFields(displayFields, in: displayRect)) { layout in
                                fieldView(layout)
                                    .transition(.opacity)
                            }
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
        // .task перезапускается при повторной раскладке/пересоздании узла
        // (особенность NavigationStack внутри fullScreenCover) сильнее, чем
        // обычный onAppear — поэтому запуск управляется вручную и явно
        // отменяется при уходе с экрана, а не отдаётся на откуп .task.
        .onAppear {
            guard processingTask == nil else { return }
            processingTask = Task { await process() }
        }
        .onDisappear {
            processingTask?.cancel()
        }
        .alert("Не удалось перевести фото", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Готово") { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private struct DisplayField: Identifiable {
        let id = UUID()
        let text: String
        /// Центр строки в нормализованных координатах фото (0...1 по x и по y,
        /// y растёт вниз). Точку, в отличие от отрезков, можно нормализовать
        /// по ширине и высоте независимо — искажений это не даёт.
        let centerNormalized: CGPoint
        /// Размер поля (ширина/высота вдоль собственных осей строки, уже с
        /// учётом её наклона) в пикселях исходного фото, а не в долях 0...1.
        /// Это важно: доля от ширины и доля от высоты — разные единицы на
        /// неквадратном фото, а тут одна и та же ось может смотреть и по x, и
        /// по y в зависимости от угла поворота.
        let sizeInImagePixels: CGSize
        /// Наклон исходной строки, уже в системе координат экрана (y вниз).
        let angle: Double
    }

    private func normalizedRect(for block: RecognizedTextBlock) -> CGRect {
        let points = [block.topLeft, block.topRight, block.bottomLeft, block.bottomRight]
        let minX = points.map(\.x).min() ?? block.boundingBox.minX
        let maxX = points.map(\.x).max() ?? block.boundingBox.maxX
        let minY = points.map(\.y).min() ?? block.boundingBox.minY
        let maxY = points.map(\.y).max() ?? block.boundingBox.maxY
        return CGRect(x: minX, y: minY,
                      width: max(0.001, maxX - minX),
                      height: max(0.001, maxY - minY))
    }

    /// Переводит нормализованную точку Vision (x, y в диапазоне 0...1, y растёт
    /// вверх) в координаты самого фото в пикселях, с y, растущим вниз (как на
    /// экране). Это нужно, чтобы дальше считать углы и размеры настоящей
    /// евклидовой геометрией: photo почти никогда не квадратное, а разные
    /// масштабы по x и по y как раз и «заваливали» угол наклона у повёрнутых
    /// подписей (см. displayAngle ниже).
    private func imageSpacePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * image.size.width, y: (1 - point.y) * image.size.height)
    }

    private func textAngle(for block: RecognizedTextBlock) -> Double {
        let topLeft = imageSpacePoint(block.topLeft)
        let topRight = imageSpacePoint(block.topRight)
        return atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)
    }

    private func normalizedAngle(_ angle: Double) -> Double {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }

    private func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        return overlap / max(0.001, min(a.width, b.width))
    }

    private func verticalDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        if a.intersects(b) { return 0 }
        if a.maxY < b.minY { return b.minY - a.maxY }
        return a.minY - b.maxY
    }

    private struct TextGroup {
        let indices: [Int]
    }

    private func makeTextGroups(_ blocks: [RecognizedTextBlock]) -> [TextGroup] {
        // Vision отдаёт отдельные наблюдения для строк. Важно не сравнивать новую
        // строку с уже объединённым большим прямоугольником: это приводит к
        // "цепному" объединению нескольких независимых надписей в одно поле.
        // Сравниваем только с ближайшими строками, уже входящими в группу.
        struct WorkingGroup {
            var indices: [Int]
            var rect: CGRect
            var angle: Double
        }

        func lineCompatible(_ a: Int, _ b: Int) -> (Bool, Double) {
            let ra = normalizedRect(for: blocks[a])
            let rb = normalizedRect(for: blocks[b])
            let aa = textAngle(for: blocks[a])
            let ab = textAngle(for: blocks[b])

            let angleDelta = abs(normalizedAngle(aa - ab))
            guard angleDelta <= .pi / 18 else { return (false, -.greatestFiniteMagnitude) } // 10°

            let height = max(0.001, min(ra.height, rb.height))
            let maxHeight = max(ra.height, rb.height)
            let verticalGap: CGFloat
            if ra.intersects(rb) {
                verticalGap = 0
            } else if ra.maxY < rb.minY {
                verticalGap = rb.minY - ra.maxY
            } else {
                verticalGap = ra.minY - rb.maxY
            }

            // Строки одного абзаца обычно находятся на расстоянии порядка
            // половины высоты строки. Независимые надписи (заголовок,
            // подпись-ярлык вроде «Тема урока»/«Задание», ссылка «Читать
            // полный текст» под абзацем) в интерфейсах часто отстоят от
            // соседнего блока на такой же по величине зазор — расстояние
            // само по себе НЕ отличает «следующую строку абзаца» от
            // «следующего элемента интерфейса» (проверено измерением на
            // реальном скриншоте: оба случая дают тот же зазор в ~половину
            // высоты строки). Поэтому порог по зазору заметно строже, чем
            // раньше, а решающую роль играет соотношение размеров шрифта
            // ниже.
            guard verticalGap <= maxHeight * 0.65 else { return (false, -.greatestFiniteMagnitude) }

            let overlap = horizontalOverlap(ra, rb)
            let leftAlignment = 1 - min(1, abs(ra.minX - rb.minX) / max(ra.width, max(rb.width, 0.001)))

            // Для многострочного блока нужен либо заметный горизонтальный
            // overlap, либо практически одинаковая левая граница. Простое
            // нахождение на одной вертикали больше не является достаточным.
            guard overlap >= 0.55 || leftAlignment >= 0.72 else { return (false, -.greatestFiniteMagnitude) }

            // Не склеиваем строки разного масштаба шрифта. Раньше порог
            // (0.45) пропускал пары вроде «подпись-ярлык (мелкий шрифт) +
            // абзац (крупный шрифт)» — на реальном скриншоте у таких пар
            // соотношение высот около 0.78, и они с готовностью склеивались
            // в один смысловой ком («Тема урока» + текст темы, «Задание» +
            // текст задания + ссылка «Читать полный текст»). Порог поднят
            // так, чтобы такие подпись/ссылка-к-абзацу пары больше не
            // проходили, а настоящие перенесённые строки одного абзаца
            // (шрифт практически идентичен, соотношение близко к 1) — по
            // прежнему проходили свободно.
            let sizeRatio = min(ra.height, rb.height) / max(ra.height, rb.height)
            guard sizeRatio >= 0.82 else { return (false, -.greatestFiniteMagnitude) }

            let score = Double(overlap * 3 + leftAlignment * 1.5 - verticalGap / height) - angleDelta * 2
            return (true, score)
        }

        guard !blocks.isEmpty else { return [] }

        // Обрабатываем сверху вниз, чтобы решение зависело от ближайшей строки,
        // а не от порядка, в котором Vision вернул наблюдения.
        let ordered = blocks.indices.sorted {
            let a = normalizedRect(for: blocks[$0])
            let b = normalizedRect(for: blocks[$1])
            if abs(a.midY - b.midY) > 0.01 { return a.midY > b.midY }
            return a.minX < b.minX
        }

        var groups: [WorkingGroup] = []

        for index in ordered {
            var bestGroup: Int?
            var bestScore = -Double.greatestFiniteMagnitude

            for groupIndex in groups.indices {
                var groupBest = -Double.greatestFiniteMagnitude
                for member in groups[groupIndex].indices {
                    let result = lineCompatible(index, member)
                    if result.0 { groupBest = max(groupBest, result.1) }
                }

                if groupBest > bestScore {
                    bestScore = groupBest
                    bestGroup = groupBest > -Double.greatestFiniteMagnitude ? groupIndex : nil
                }
            }

            if let groupIndex = bestGroup {
                groups[groupIndex].indices.append(index)
                groups[groupIndex].rect = groups[groupIndex].rect.union(normalizedRect(for: blocks[index]))
                let count = Double(groups[groupIndex].indices.count)
                let angle = textAngle(for: blocks[index])
                groups[groupIndex].angle = (groups[groupIndex].angle * (count - 1) + angle) / count
            } else {
                groups.append(WorkingGroup(
                    indices: [index],
                    rect: normalizedRect(for: blocks[index]),
                    angle: textAngle(for: blocks[index])
                ))
            }
        }

        groups.sort { a, b in
            if abs(a.rect.midY - b.rect.midY) > 0.02 { return a.rect.midY > b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        return groups.map { TextGroup(indices: $0.indices) }
    }

    private func makeDisplayFields(
        from blocks: [RecognizedTextBlock],
        groups: [TextGroup],
        translations: [String]
    ) -> [DisplayField] {
        zip(groups, translations).compactMap { group, translation in
            let clean = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !group.indices.isEmpty else { return nil }

            let angle = group.indices
                .map { textAngle(for: blocks[$0]) }
                .reduce(0, +) / Double(group.indices.count)

            // Проецируем углы исходного текста на оси самого текста. Благодаря
            // этому поле остаётся прямоугольным и повторяет наклон оригинала.
            let ux = CGFloat(cos(angle))
            let uy = CGFloat(sin(angle))
            let vx = CGFloat(-sin(angle))
            let vy = CGFloat(cos(angle))

            // Считаем в пикселях самого фото (imageSpacePoint), а не в сырых
            // долях 0...1. Фото почти никогда не квадратное, поэтому доля по x
            // и доля по y — разные по «физическому размеру» единицы: прямое
            // cos/sin-проецирование по ним давало на наклонных строках (как
            // подписи вокруг круглой навигационной панели пульта) неверный
            // размер и смещённый центр — карточка «съезжала» и не помещалась
            // в одну строку, хотя реального текста там было немного.
            let points = group.indices.flatMap { index -> [CGPoint] in
                let block = blocks[index]
                return [
                    imageSpacePoint(block.topLeft),
                    imageSpacePoint(block.topRight),
                    imageSpacePoint(block.bottomLeft),
                    imageSpacePoint(block.bottomRight)
                ]
            }

            let projectedU = points.map { $0.x * ux + $0.y * uy }
            let projectedV = points.map { $0.x * vx + $0.y * vy }
            let minU = projectedU.min() ?? 0
            let maxU = projectedU.max() ?? 1
            let minV = projectedV.min() ?? 0
            let maxV = projectedV.max() ?? 1

            // minU/maxU и minV/maxV — размеры в собственной системе координат
            // текста, уже в пикселях фото.
            let localWidth = max(1, maxU - minU)
            let localHeight = max(1, maxV - minV)
            let centerU = (minU + maxU) * 0.5
            let centerV = (minV + maxV) * 0.5
            let centerX = centerU * ux + centerV * vx
            let centerY = centerU * uy + centerV * vy

            let centerNormalized = CGPoint(
                x: centerX / max(1, image.size.width),
                y: centerY / max(1, image.size.height)
            )

            return DisplayField(
                text: clean,
                centerNormalized: centerNormalized,
                sizeInImagePixels: CGSize(width: localWidth, height: localHeight),
                angle: angle
            )
        }
    }

    private struct FieldLayout: Identifiable {
        let id: UUID
        let text: String
        var frame: CGRect
        let angle: Double
        let fontSize: CGFloat
        let lineLimit: Int?
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
    }

    /// Раскладывает все поля. Подписи-«кнопки» (короткие, одна исходная
    /// строка) и абзацы (диалоги/несколько исходных строк) ведут себя
    /// по-разному, поэтому считаются отдельно — см. buttonLayout и
    /// paragraphLayouts ниже. Оба вида карточек в итоге прижимаются к
    /// границам фото (clamped), чтобы ничего не вылезало за пределы кадра.
    private func layoutFields(_ fields: [DisplayField], in displayRect: CGRect) -> [FieldLayout] {
        guard !fields.isEmpty else { return [] }

        let buttonFields = fields.filter { !$0.text.contains("\n") }
        let paragraphFields = fields.filter { $0.text.contains("\n") }

        // Карточки-кнопки не растут (buttonLayout), поэтому их можно
        // посчитать первыми и передать дальше как неподвижные препятствия:
        // растущий вверх абзац не должен наехать и закрыть собой, скажем,
        // заголовок или подпись-ярлык, которые стоят прямо над ним.
        let buttonLayoutsResult = buttonFields.map { buttonLayout(for: $0, in: displayRect) }
        let obstacles = buttonLayoutsResult.map(\.frame)

        var layouts = buttonLayoutsResult
        layouts.append(contentsOf: paragraphLayouts(for: paragraphFields, avoiding: obstacles, in: displayRect))
        return layouts
    }

    /// Подписи кнопок пульта и т.п.: карточка остаётся ровно в границах
    /// исходной строки — не растёт ни по ширине, ни по высоте. Если перевод
    /// не помещается на исходном месте, сначала переносим на 2 и более
    /// строк, и только когда переноса мало — уменьшаем шрифт (вплоть до
    /// мелкого, но читаемого). Раз карточка никогда не выходит за пределы
    /// своей исходной области, соседние подписи (стоящие на пульте вплотную
    /// друг к другу) физически не могут наехать одна на другую.
    private func buttonLayout(for field: DisplayField, in displayRect: CGRect) -> FieldLayout {
        // Экран и фото имеют одинаковые пропорции (AVMakeRect сохраняет
        // aspect ratio), поэтому масштаб «пиксели фото → пиксели экрана»
        // одинаков по x и по y — можно использовать одно число.
        let scale = image.size.width > 0 ? displayRect.width / image.size.width : 1
        let centerScreen = CGPoint(
            x: displayRect.minX + field.centerNormalized.x * displayRect.width,
            y: displayRect.minY + field.centerNormalized.y * displayRect.height
        )
        let originalSize = CGSize(
            width: field.sizeInImagePixels.width * scale,
            height: field.sizeInImagePixels.height * scale
        )

        let horizontalInset = max(3, min(8, originalSize.height * 0.16))
        let verticalInset = max(2, min(5, originalSize.height * 0.10))
        let preferredFont = max(12, min(22, originalSize.height * 0.72))

        let availableWidth = max(1, originalSize.width - horizontalInset * 2)
        let availableHeight = max(1, originalSize.height - verticalInset * 2)
        // Нижняя граница шрифта здесь ниже, чем у абзацев: карточке некуда
        // расти, поэтому в самом тесном случае лучше мелкий, но всё ещё
        // читаемый шрифт, чем вылезание за свою кнопку.
        let fontSize = fittingFontSize(
            for: field.text,
            maxWidth: availableWidth,
            maxHeight: availableHeight,
            preferred: preferredFont,
            minimum: 6.5
        )

        let frame = clamped(CGRect(
            x: centerScreen.x - originalSize.width / 2,
            y: centerScreen.y - originalSize.height / 2,
            width: originalSize.width,
            height: originalSize.height
        ), to: displayRect)

        return FieldLayout(
            id: field.id,
            text: field.text,
            frame: frame,
            angle: displayAngle(for: field.angle),
            fontSize: fontSize,
            lineLimit: nil,
            horizontalInset: horizontalInset,
            verticalInset: verticalInset
        )
    }

    /// Абзацы (исходно многострочный текст — диалоги, длинные подписи).
    /// Перевод почти всегда длиннее оригинала, но карточка растёт только по
    /// высоте и только вверх — ширина остаётся исходной, чтобы перевод не
    /// наезжал вбок на соседний текст и не вылезал за фото. Рост вверх
    /// ограничен нижним краем карточки, что лежит выше в том же столбце (или
    /// верхом фото), а когда даже этого места не хватает — включается
    /// уменьшение шрифта и перенос на 2 и более строк.
    private func paragraphLayouts(for fields: [DisplayField], avoiding obstacles: [CGRect], in displayRect: CGRect) -> [FieldLayout] {
        guard !fields.isEmpty else { return [] }

        struct Prelim {
            let field: DisplayField
            let centerX: CGFloat
            let originalTop: CGFloat
            let originalBottom: CGFloat
            let fixedWidth: CGFloat
            let horizontalInset: CGFloat
            let verticalInset: CGFloat
            let preferredFont: CGFloat
        }

        let scale = image.size.width > 0 ? displayRect.width / image.size.width : 1
        let prelim: [Prelim] = fields.map { field in
            let centerScreen = CGPoint(
                x: displayRect.minX + field.centerNormalized.x * displayRect.width,
                y: displayRect.minY + field.centerNormalized.y * displayRect.height
            )
            let originalSize = CGSize(
                width: field.sizeInImagePixels.width * scale,
                height: field.sizeInImagePixels.height * scale
            )
            return Prelim(
                field: field,
                centerX: centerScreen.x,
                originalTop: centerScreen.y - originalSize.height / 2,
                originalBottom: centerScreen.y + originalSize.height / 2,
                fixedWidth: originalSize.width,
                horizontalInset: max(4, min(10, originalSize.height * 0.20)),
                verticalInset: max(3, min(7, originalSize.height * 0.12)),
                preferredFont: max(12, min(22, originalSize.height * 0.72))
            )
        }

        // Сверху вниз: тогда для каждой карточки уже известно, куда доросла
        // (и где остановилась) карточка над ней.
        let order = prelim.indices.sorted { prelim[$0].originalBottom < prelim[$1].originalBottom }
        var finalizedFrames: [CGRect] = Array(repeating: .zero, count: prelim.count)
        var layouts: [FieldLayout] = []
        layouts.reserveCapacity(prelim.count)

        let gap: CGFloat = 3

        for position in order.indices {
            let index = order[position]
            let item = prelim[index]
            let probe = CGRect(x: item.centerX - item.fixedWidth / 2, y: 0, width: item.fixedWidth, height: 1)

            // Самое высокое допустимое положение верхнего края: верх фото,
            // низ уже размещённой карточки-абзаца над этой в том же
            // столбце, либо низ неподвижной карточки-кнопки/заголовка/
            // подписи над ней (obstacles) — растущий вверх абзац не должен
            // наехать и закрыть их собой.
            var upperLimit = displayRect.minY
            for previousPosition in 0..<position {
                let placedIndex = order[previousPosition]
                let placedFrame = finalizedFrames[placedIndex]
                guard placedFrame.maxY <= item.originalBottom else { continue }
                guard horizontalOverlap(placedFrame, probe) > 0.15 else { continue }
                upperLimit = max(upperLimit, placedFrame.maxY + gap)
            }
            for obstacleFrame in obstacles {
                guard obstacleFrame.maxY <= item.originalBottom else { continue }
                guard horizontalOverlap(obstacleFrame, probe) > 0.15 else { continue }
                upperLimit = max(upperLimit, obstacleFrame.maxY + gap)
            }

            let availableWidth = max(1, item.fixedWidth - item.horizontalInset * 2)
            let maxHeightAvailable = max(
                item.preferredFont + item.verticalInset * 2,
                item.originalBottom - upperLimit
            )
            let availableHeight = max(1, maxHeightAvailable - item.verticalInset * 2)

            let fontSize = fittingFontSize(
                for: item.field.text,
                maxWidth: availableWidth,
                maxHeight: availableHeight,
                preferred: item.preferredFont,
                minimum: 8
            )
            let measured = measuredTextSize(item.field.text, fontSize: fontSize, maxWidth: availableWidth)
            let neededHeight = min(
                maxHeightAvailable,
                max(item.originalBottom - item.originalTop, measured.height + item.verticalInset * 2)
            )

            let frame = clamped(CGRect(
                x: item.centerX - item.fixedWidth / 2,
                y: item.originalBottom - neededHeight,
                width: item.fixedWidth,
                height: neededHeight
            ), to: displayRect)
            finalizedFrames[index] = frame

            layouts.append(FieldLayout(
                id: item.field.id,
                text: item.field.text,
                frame: frame,
                angle: displayAngle(for: item.field.angle),
                fontSize: fontSize,
                lineLimit: nil,
                horizontalInset: item.horizontalInset,
                verticalInset: item.verticalInset
            ))
        }

        return layouts
    }

    /// Сдвигает (не сжимает) прямоугольник так, чтобы он не выходил за
    /// границы фото — это последняя защита от текста, вылезающего за экран.
    private func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var result = frame
        if result.width >= bounds.width {
            result.origin.x = bounds.minX
        } else {
            if result.minX < bounds.minX { result.origin.x = bounds.minX }
            if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        }
        if result.height >= bounds.height {
            result.origin.y = bounds.minY
        } else {
            if result.minY < bounds.minY { result.origin.y = bounds.minY }
            if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        }
        return result
    }

    private func fieldView(_ layout: FieldLayout) -> some View {
        let availableWidth = max(1, layout.frame.width - layout.horizontalInset * 2)
        let availableHeight = max(1, layout.frame.height - layout.verticalInset * 2)

        return Text(layout.text)
            .font(.system(size: layout.fontSize, weight: .semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.13))
            .multilineTextAlignment(.leading)
            .lineSpacing(max(1, layout.fontSize * 0.08))
            .allowsTightening(true)
            .lineLimit(layout.lineLimit)
            .minimumScaleFactor(layout.lineLimit == 1 ? 0.85 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: availableWidth, height: availableHeight, alignment: .leading)
            .padding(.horizontal, layout.horizontalInset)
            .padding(.vertical, layout.verticalInset)
            .background(
                Color(red: 1.0, green: 0.975, blue: 0.93).opacity(0.94),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                // Тонкая обводка помогает глазу разделить соседние карточки,
                // даже когда они стоят почти впритык друг к другу.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .frame(width: layout.frame.width, height: layout.frame.height)
            .rotationEffect(.radians(layout.angle))
            .position(x: layout.frame.midX, y: layout.frame.midY)
    }

    /// Показываем реальный наклон исходной строки — как это делает системный
    /// Перевод в приложении «Камера» (см. эталонный скриншот: подписи вокруг
    /// круглой навигационной панели пульта повёрнуты каждая под свой угол,
    /// вплоть до ~90°, и лежат ровно на своей кнопке). Раньше здесь заметный
    /// поворот принудительно обнулялся — считалось, что причина «раздёрганных»
    /// подписей в самом повороте. На самом деле дело было в том, что угол
    /// считался неверно на неквадратном фото (см. textAngle) — сам по себе
    /// поворот тут ни при чём и его нужно показывать. Единственное, что
    /// стоит поправить — не показывать текст «вверх ногами», если Vision
    /// вернул угол больше 90° по модулю.
    private func displayAngle(for angle: Double) -> Double {
        var normalized = normalizedAngle(angle)
        if normalized > .pi / 2 {
            normalized -= .pi
        } else if normalized < -.pi / 2 {
            normalized += .pi
        }
        return normalized
    }

    private func measuredTextSize(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGSize {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).size
    }

    private func fittingFontSize(
        for text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        preferred: CGFloat,
        minimum: CGFloat = 9
    ) -> CGFloat {
        guard maxWidth > 1, maxHeight > 1, !text.isEmpty else { return minimum }

        func fits(_ size: CGFloat) -> Bool {
            let font = UIFont.systemFont(ofSize: size, weight: .semibold)
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return rect.height <= maxHeight + 1
        }

        if fits(preferred) { return preferred }
        if !fits(minimum) { return minimum }

        var low = minimum
        var high = preferred
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
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
        // .task на NavigationStack внутри GeometryReader иногда запускается
        // повторно при повторной раскладке (особенность SwiftUI, не связана
        // с логикой перевода). Без этой защиты запоздавший второй запуск
        // мог упасть с ошибкой сети/модели уже ПОСЛЕ того, как первый успешно
        // всё перевёл и показал — пользователь видел готовый перевод и
        // алерт «Не удалось перевести фото» одновременно.
        guard !hasStartedProcessing else { return }
        hasStartedProcessing = true

        do {
            if !vm.isModelInstalled || vm.modelState == .unloaded {
                isPreparingModel = true
                do {
                    try await vm.ensureModelReady()
                } catch {
                    isPreparingModel = false
                    isProcessing = false
                    // Если к этому моменту задача уже отменена (например,
                    // экран результата пересоздался и старый прогон
                    // отменяется), ensureModelReady() может бросить обычную
                    // ошибку сети/модели вместо чистой CancellationError —
                    // это не настоящий сбой, а просто прерванный черновой
                    // запуск, поэтому алерт в этом случае не показываем.
                    if !Task.isCancelled {
                        errorMessage = "Модель ещё не загружена. Дождитесь окончания загрузки, чтобы переводить фото."
                    }
                    return
                }
                isPreparingModel = false
            }

            let recognized = try await TextRecognitionService.recognizeText(in: image)
            let sourceBlocks = recognized.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !sourceBlocks.isEmpty else { throw TextRecognitionError.noTextFound }

            let groups = makeTextGroups(sourceBlocks)
            progressiveTranslations = Array(repeating: "", count: groups.count)
            displayFields = []
            translatedText = ""

            // Каждый логический блок переводится отдельно. Токены сразу попадают
            // на экран: как только пришёл первый фрагмент первого перевода,
            // индикатор «Распознаём и переводим…» автоматически исчезает.
            for (groupIndex, group) in groups.enumerated() {
                let source = group.indices
                    .map { sourceBlocks[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                let finalTranslation = try await vm.translateStandalone(
                    source,
                    from: vm.sourceLanguage,
                    to: vm.targetLanguage,
                    onToken: { piece in
                        guard !piece.isEmpty else { return }
                        Task { @MainActor in
                            progressiveTranslations[groupIndex] += piece
                            displayFields = makeDisplayFields(
                                from: sourceBlocks,
                                groups: groups,
                                translations: progressiveTranslations
                            )
                            translatedText = progressiveTranslations
                                .joined(separator: "\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                )

                progressiveTranslations[groupIndex] = finalTranslation
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                displayFields = makeDisplayFields(
                    from: sourceBlocks,
                    groups: groups,
                    translations: progressiveTranslations
                )
                translatedText = progressiveTranslations
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !displayFields.isEmpty else { throw TextRecognitionError.noTextFound }
        } catch is CancellationError {
            // Нормальная отмена задачи не является ошибкой интерфейса.
        } catch {
            // Если задача уже отменена, что бы ни бросил перевод в этот
            // момент (не обязательно ровно CancellationError — сетевой слой
            // или llama.cpp может вернуть свою собственную ошибку при
            // прерывании) — это не настоящий сбой, а прерванный черновой
            // прогон (например, экран результата пересоздался). Показываем
            // ошибку только для НЕотменённой задачи и только если результата
            // совсем нет — чтобы не перекрывать уже готовый перевод.
            if !Task.isCancelled && translatedText.isEmpty && displayFields.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isProcessing = false
    }

}

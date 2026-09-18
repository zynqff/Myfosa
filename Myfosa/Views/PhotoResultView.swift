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
                            ForEach(displayFields) { field in
                                translatedField(field, in: displayRect)
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

    private struct DisplayField: Identifiable {
        let id = UUID()
        let text: String
        /// Прямоугольник в нормализованных координатах изображения (0...1).
        let normalizedRect: CGRect
        /// Наклон исходной строки в экранных координатах.
        let angle: Double
    }

    /// Собирает строки Vision в логические группы. Если строки находятся в одной
    /// текстовой области и образуют единый блок, перевод выводится одним полем.
    /// Разнесённые по фотографии области остаются отдельными полями.
    private func displayFields(for blocks: [RecognizedTextBlock], translated: [String]) -> [DisplayField] {
        struct Group {
            var indices: [Int]
            var rect: CGRect
            var angle: Double
        }

        guard !blocks.isEmpty else { return [] }

        var groups: [Group] = []

        for index in blocks.indices {
            let block = blocks[index]
            let rect = normalizedRect(for: block)
            let angle = textAngle(for: block)
            var bestGroup: Int?
            var bestScore = -Double.infinity

            for groupIndex in groups.indices {
                let group = groups[groupIndex]
                let angleDelta = abs(normalizedAngle(angle - group.angle))
                guard angleDelta < .pi / 12 else { continue } // до 15°

                let expanded = group.rect.insetBy(dx: -max(rect.width, group.rect.width) * 0.18,
                                                   dy: -max(rect.height, group.rect.height) * 0.75)
                let xOverlap = horizontalOverlap(rect, group.rect)
                let closeEnough = expanded.intersects(rect) || xOverlap > 0.35
                guard closeEnough else { continue }

                // Сильнее предпочитаем строки, которые реально находятся одна
                // над другой/рядом и имеют заметное горизонтальное пересечение.
                let verticalGap = verticalDistance(rect, group.rect)
                let heightScale = max(rect.height, group.rect.height, 0.001)
                let proximity = max(0, 1 - verticalGap / (heightScale * 2.5))
                let score = xOverlap * 2 + proximity - angleDelta * 0.5

                if score > bestScore {
                    bestScore = score
                    bestGroup = groupIndex
                }
            }

            if let groupIndex = bestGroup {
                groups[groupIndex].indices.append(index)
                groups[groupIndex].rect = groups[groupIndex].rect.union(rect)
                let count = Double(groups[groupIndex].indices.count)
                groups[groupIndex].angle = (groups[groupIndex].angle * (count - 1) + angle) / count
            } else {
                groups.append(Group(indices: [index], rect: rect, angle: angle))
            }
        }

        // Vision обычно возвращает строки сверху вниз. Сортируем группы по
        // положению, чтобы итоговый copied text оставался в естественном порядке.
        groups.sort { a, b in
            if abs(a.rect.midY - b.rect.midY) > 0.02 {
                return a.rect.midY > b.rect.midY
            }
            return a.rect.minX < b.rect.minX
        }

        return groups.compactMap { group in
            let text = group.indices
                .sorted { lhs, rhs in
                    let a = normalizedRect(for: blocks[lhs])
                    let b = normalizedRect(for: blocks[rhs])
                    if abs(a.midY - b.midY) > 0.01 { return a.midY > b.midY }
                    return a.minX < b.minX
                }
                .map { translated[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            guard !text.isEmpty else { return nil }
            return DisplayField(text: text, normalizedRect: group.rect, angle: group.angle)
        }
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

    private func textAngle(for block: RecognizedTextBlock) -> Double {
        atan2(-(block.topRight.y - block.topLeft.y),
              block.topRight.x - block.topLeft.x)
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
            // высоты строки. Независимые надписи на разных кнопках дальше друг
            // от друга. Существенно более строгий порог не даёт им склеиваться.
            guard verticalGap <= maxHeight * 0.85 else { return (false, -.greatestFiniteMagnitude) }

            let overlap = horizontalOverlap(ra, rb)
            let leftAlignment = 1 - min(1, abs(ra.minX - rb.minX) / max(ra.width, max(rb.width, 0.001)))

            // Для многострочного блока нужен либо заметный горизонтальный
            // overlap, либо практически одинаковая левая граница. Простое
            // нахождение на одной вертикали больше не является достаточным.
            guard overlap >= 0.55 || leftAlignment >= 0.72 else { return (false, -.greatestFiniteMagnitude) }

            // Не склеиваем сильно отличающиеся по масштабу элементы. Это важно
            // для фото пульта, где мелкие подписи находятся рядом с крупными
            // названиями кнопок.
            let sizeRatio = min(ra.height, rb.height) / max(ra.height, rb.height)
            guard sizeRatio >= 0.45 else { return (false, -.greatestFiniteMagnitude) }

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

            let points = group.indices.flatMap { index -> [CGPoint] in
                let block = blocks[index]
                return [
                    CGPoint(x: block.topLeft.x, y: 1 - block.topLeft.y),
                    CGPoint(x: block.topRight.x, y: 1 - block.topRight.y),
                    CGPoint(x: block.bottomLeft.x, y: 1 - block.bottomLeft.y),
                    CGPoint(x: block.bottomRight.x, y: 1 - block.bottomRight.y)
                ]
            }

            let projectedU = points.map { $0.x * ux + $0.y * uy }
            let projectedV = points.map { $0.x * vx + $0.y * vy }
            let minU = projectedU.min() ?? 0
            let maxU = projectedU.max() ?? 1
            let minV = projectedV.min() ?? 0
            let maxV = projectedV.max() ?? 1

            // minU/maxU и minV/maxV — размеры в собственной системе координат
            // текста. Раньше здесь они ошибочно записывались как обычный CGRect: у
            // наклонного текста width/height не совпадают с осями изображения. Из-за
            // этого поле могло смещаться в сторону и становиться большим ромбом.
            let localWidth = max(0.001, maxU - minU)
            let localHeight = max(0.001, maxV - minV)
            let centerU = (minU + maxU) * 0.5
            let centerV = (minV + maxV) * 0.5
            let centerX = centerU * ux + centerV * vx
            let centerY = centerU * uy + centerV * vy

            // normalizedRect хранит центр/размеры в координатах Vision, а угол
            // отдельно задаёт поворот. Это позволяет translatedField корректно
            // позиционировать именно центр исходной надписи.
            let visionRect = CGRect(
                x: centerX - localWidth * 0.5,
                y: 1 - centerY - localHeight * 0.5,
                width: localWidth,
                height: localHeight
            )

            return DisplayField(text: clean, normalizedRect: visionRect, angle: angle)
        }
    }

    private func translatedField(_ field: DisplayField, in displayRect: CGRect) -> some View {
        let originalRect = CGRect(
            x: displayRect.minX + field.normalizedRect.minX * displayRect.width,
            y: displayRect.minY + (1 - field.normalizedRect.maxY) * displayRect.height,
            width: field.normalizedRect.width * displayRect.width,
            height: field.normalizedRect.height * displayRect.height
        )

        // Поле остаётся привязанным к исходной области. Не раздуваем его в 2–3
        // раза: именно это раньше приводило к перекрытиям и к появлению перевода
        // рядом с оригинальной надписью. Разрешаем лишь небольшой запас для
        // длинного перевода, а недостающий объём компенсируем переносами и
        // уменьшением шрифта.
        let horizontalInset = max(4, min(10, originalRect.height * 0.20))
        let verticalInset = max(3, min(7, originalRect.height * 0.12))
        let preferredFont = max(12, min(22, originalRect.height * 0.72))

        // На втором скриншоте («родной» Перевод) короткие подписи кнопок всегда
        // остаются в одну строку — карточка просто ужимается по ширине и по
        // шрифту, а не переносится на 2–3 строки, как было раньше. Поэтому
        // сначала пытаемся ужать шрифт так, чтобы весь перевод влез в одну
        // строку, и только если это совсем невозможно даже на минимальном
        // читаемом размере — переходим к переносу строк (для редких длинных
        // предложений).
        let singleLineMinFont: CGFloat = 8
        let maxSingleLineWidth = max(originalRect.width, originalRect.width * 1.6)
        let singleLineAvailableWidth = max(1, maxSingleLineWidth - horizontalInset * 2)
        let singleLineFont = fittingSingleLineFontSize(
            for: field.text,
            maxWidth: singleLineAvailableWidth,
            preferred: preferredFont,
            minimum: singleLineMinFont
        )
        let singleLineWidth = measuredLineWidth(field.text, fontSize: singleLineFont)
        // Группы, изначально состоявшие из нескольких строк оригинала (настоящий
        // абзац), сохраняют перевод построчно — им перенос нужен по смыслу, а
        // не из-за нехватки места, поэтому в одну строку их не сжимаем.
        let fitsOneLine = !field.text.contains("\n") && singleLineWidth <= singleLineAvailableWidth + 0.5

        let content: Text
        let finalFontSize: CGFloat
        let fieldWidth: CGFloat
        let fieldHeight: CGFloat
        let availableWidth: CGFloat
        let availableHeight: CGFloat
        let lineLimit: Int?

        if fitsOneLine {
            finalFontSize = singleLineFont
            let lineHeight = measuredTextSize(field.text, fontSize: finalFontSize, maxWidth: .greatestFiniteMagnitude).height
            fieldWidth = min(maxSingleLineWidth, max(originalRect.width, singleLineWidth + horizontalInset * 2))
            fieldHeight = max(originalRect.height, lineHeight + verticalInset * 2)
            availableWidth = max(1, fieldWidth - horizontalInset * 2)
            availableHeight = max(1, fieldHeight - verticalInset * 2)
            lineLimit = 1
        } else {
            let natural = measuredTextSize(
                field.text,
                fontSize: preferredFont,
                maxWidth: max(1, originalRect.width * 1.35)
            )
            let maxFieldWidth = max(originalRect.width, originalRect.width * 1.35)
            let maxFieldHeight = max(originalRect.height, originalRect.height * 1.55)
            fieldWidth = min(maxFieldWidth, max(originalRect.width, natural.width + horizontalInset * 2))
            fieldHeight = min(maxFieldHeight, max(originalRect.height, natural.height + verticalInset * 2))
            availableWidth = max(1, fieldWidth - horizontalInset * 2)
            availableHeight = max(1, fieldHeight - verticalInset * 2)
            finalFontSize = max(10.5, fittingFontSize(
                for: field.text,
                maxWidth: availableWidth,
                maxHeight: availableHeight,
                preferred: preferredFont
            ))
            lineLimit = nil
        }
        content = Text(field.text)

        return content
            .font(.system(size: finalFontSize, weight: .semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.15, blue: 0.13))
            .multilineTextAlignment(.leading)
            .lineSpacing(max(1, finalFontSize * 0.08))
            .allowsTightening(true)
            .lineLimit(lineLimit)
            .minimumScaleFactor(lineLimit == 1 ? 0.85 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: availableWidth, height: availableHeight, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .background(
                Color(red: 1.0, green: 0.975, blue: 0.93).opacity(0.92),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .frame(width: fieldWidth, height: fieldHeight)
            .rotationEffect(.radians(displayAngle(for: field.angle)))
            .position(x: originalRect.midX, y: originalRect.midY)
    }

    private func measuredLineWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// Подбирает максимальный размер шрифта, при котором весь текст помещается
    /// в одну строку заданной ширины (без переноса).
    private func fittingSingleLineFontSize(
        for text: String,
        maxWidth: CGFloat,
        preferred: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard maxWidth > 1, !text.isEmpty else { return minimum }

        func fits(_ size: CGFloat) -> Bool {
            measuredLineWidth(text, fontSize: size) <= maxWidth + 0.5
        }

        if fits(preferred) { return preferred }
        if !fits(minimum) { return minimum }

        var low = minimum
        var high = preferred
        for _ in 0..<14 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// Системный Перевод в приложении «Камера» (см. второй скриншот) всегда
    /// рисует переведённый текст ровно по горизонтали, даже если сама подпись
    /// на кнопке напечатана под углом (например, слова вокруг круглого
    /// джойстика пульта). Раньше мы буквально поворачивали поле на угол
    /// исходной строки — из-за этого подписи вокруг «крестовины» пульта
    /// получались раздёрганными и нечитаемыми (как на первом скриншоте).
    /// Теперь ощутимый поворот (типично 20°+ у круговых кнопок) обнуляется, и
    /// остаётся лишь небольшая поправка на реальный наклон самого фото при
    /// съёмке с руки.
    private func displayAngle(for angle: Double) -> Double {
        let maxCorrection = Double.pi / 15 // ≈ 12°
        return max(-maxCorrection, min(maxCorrection, angle))
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
        preferred: CGFloat
    ) -> CGFloat {
        let minimum: CGFloat = 9
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
            if translatedText.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isProcessing = false
    }

}

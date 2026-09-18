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

            // Строим рамку в системе координат, повернутой вместе с текстом.
            // Если сначала взять обычный axis-aligned bounding box, а потом
            // повернуть его, наклонные надписи превращаются в большие ромбы.
            // Здесь ширина/высота вычисляются вдоль реального направления текста.
            let cosA = cos(angle)
            let sinA = sin(angle)
            let ux = CGFloat(cosA)
            let uy = CGFloat(sinA)
            let vx = CGFloat(-sinA)
            let vy = CGFloat(cosA)

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

            // Небольшой запас только внутри самого поля — он нужен для текста,
            // но не должен заметно раздувать поле поверх соседних надписей.
            let width = max(0.001, maxU - minU)
            let height = max(0.001, maxV - minV)
            let centerU = (minU + maxU) * 0.5
            let centerV = (minV + maxV) * 0.5
            let centerX = centerU * ux + centerV * vx
            let centerY = centerU * uy + centerV * vy

            let rect = CGRect(
                x: centerX - width * 0.5,
                y: centerY - height * 0.5,
                width: width,
                height: height
            )

            // translatedField ожидает Vision-координаты (Y снизу вверх).
            let visionRect = CGRect(
                x: rect.minX,
                y: 1 - rect.maxY,
                width: rect.width,
                height: rect.height
            )

            return DisplayField(text: clean, normalizedRect: visionRect, angle: angle)
        }
    }

    private func translatedField(_ field: DisplayField, in displayRect: CGRect) -> some View {
        let rect = CGRect(
            x: displayRect.minX + field.normalizedRect.minX * displayRect.width,
            y: displayRect.minY + (1 - field.normalizedRect.maxY) * displayRect.height,
            width: field.normalizedRect.width * displayRect.width,
            height: field.normalizedRect.height * displayRect.height
        )

        // У каждого блока свой фон. Если перевод длиннее исходной надписи,
        // шрифт уменьшается, но само поле остаётся на месте оригинального текста.
        let lineCount = max(1, field.text.components(separatedBy: "\n").count)
        let lineHeight = max(12, rect.height / CGFloat(lineCount))
        let baseFontSize = max(8, min(22, lineHeight * 0.78))
        let horizontalInset = max(4, min(12, rect.width * 0.025))
        let verticalInset = max(3, min(10, lineHeight * 0.18))
        let availableWidth = max(1, rect.width - horizontalInset * 2)
        let availableHeight = max(1, rect.height - verticalInset * 2)
        let fontSize = fittingFontSize(
            for: field.text,
            maxWidth: availableWidth,
            maxHeight: availableHeight,
            preferred: baseFontSize
        )

        return Text(field.text)
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
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .rotationEffect(.radians(field.angle))
            .position(x: rect.midX, y: rect.midY)
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

            guard recognized.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw TextRecognitionError.noTextFound
            }

            // Сначала группируем строки по расположению на фотографии. Поэтому
            // несколько строк одного сплошного блока получают одно поле, а
            // разнесённые надписи (например, кнопки пульта) остаются отдельными.
            let sourceBlocks = recognized.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !sourceBlocks.isEmpty else {
                throw TextRecognitionError.noTextFound
            }

            struct TranslationGroup {
                let indices: [Int]
                let text: String
            }

            // Используем ту же геометрическую группировку, что и для отображения,
            // но получаем индексы через временный перевод-заглушку. Это позволяет
            // не менять распознавание и оставить перевод каждого логического блока
            // одним запросом к модели.
            let groups = makeTextGroups(sourceBlocks)
            var groupTranslations: [String] = []

            for group in groups {
                let source = group.indices
                    .map { sourceBlocks[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                let translated = try await vm.translateStandalone(
                    source,
                    from: vm.sourceLanguage,
                    to: vm.targetLanguage
                )
                groupTranslations.append(translated.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let fields = makeDisplayFields(
                from: sourceBlocks,
                groups: groups,
                translations: groupTranslations
            )
            let allTranslations = groupTranslations.filter { !$0.isEmpty }

            guard !fields.isEmpty else {
                throw TextRecognitionError.noTextFound
            }

            withAnimation(.easeOut(duration: 0.2)) {
                displayFields = fields
                translatedText = allTranslations.joined(separator: "\n")
            }
        } catch {
            if translatedText.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isProcessing = false
    }
}

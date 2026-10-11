import Foundation
import llama
import os

// Через os.Logger, а не print()/NSLog() — так эти сообщения гарантированно попадают
// в единый системный лог (видно в Console.app / idevicesyslog), в отличие от обычного
// print() или fprintf(stderr, ...) внутри llama.cpp, которые в собранном не под Xcode
// приложении в системный лог не долетают вообще.
private let llamaLogger = Logger(
    subsystem: "com.SiaSoft.Myfosa",
    category: "llama"
)

// llama.cpp/ggml по умолчанию пишет свои внутренние сообщения через stderr.
// В собранном приложении эти сообщения могут не попадать в системный лог.
// Перехватываем их через llama_log_set и отправляем в os.Logger.
private func llamaLogCallback(
    level: ggml_log_level,
    text: UnsafePointer<CChar>?,
    userData: UnsafeMutableRawPointer?
) {
    guard let text else { return }

    let message = String(cString: text)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !message.isEmpty else { return }

    switch level {
    case GGML_LOG_LEVEL_ERROR:
        llamaLogger.error("llama.cpp: \(message, privacy: .public)")

    case GGML_LOG_LEVEL_WARN:
        llamaLogger.warning("llama.cpp: \(message, privacy: .public)")

    default:
        llamaLogger.notice("llama.cpp: \(message, privacy: .public)")
    }
}

enum ModelState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    case translating
    case unloading
}

enum TranslatorError: LocalizedError {
    case modelUnavailable
    case contextCreationFailed
    case inferenceFailed
    case inputTooLong

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Модель недоступна."

        case .contextCreationFailed:
            return "Не удалось загрузить модель в память."

        case .inferenceFailed:
            return "Не удалось выполнить перевод."

        case .inputTooLong:
            return "Текст слишком длинный для текущего контекста."
        }
    }
}

protocol TranslatorService: Sendable {

    func loadModel(path: URL) async throws

    /// onToken вызывается по мере генерации каждого нового фрагмента текста.
    /// Возвращает полностью собранный и обрезанный результат.
    func translate(
        text: String,
        sourceLang: String,
        targetLang: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String

    func unloadModel() async

    func currentState() async -> ModelState
}

actor LlamaTranslatorService: TranslatorService {

    private var context: LlamaContext?
    private var state: ModelState = .unloaded

    func currentState() async -> ModelState {
        state
    }

    func loadModel(path: URL) async throws {
        guard context == nil else { return }

        state = .loading

        llamaLogger.notice(
            "loadModel: старт, путь = \(path.path, privacy: .public)"
        )

        let exists = FileManager.default.fileExists(atPath: path.path)

        let size =
            (try? FileManager.default.attributesOfItem(
                atPath: path.path
            )[.size] as? Int64) ?? nil

        llamaLogger.notice(
            "loadModel: файл существует = \(exists), размер на диске = \(size ?? -1, privacy: .public) байт"
        )

        do {
            context = try await LlamaContext.create(path: path.path)

            state = .loaded

            llamaLogger.notice(
                "loadModel: модель и контекст успешно созданы"
            )

        } catch {
            context = nil
            state = .unloaded

            llamaLogger.error(
                "loadModel: ошибка создания контекста: \(String(describing: error), privacy: .public)"
            )

            throw TranslatorError.contextCreationFailed
        }
    }

    func translate(
        text: String,
        sourceLang: String,
        targetLang: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {

        guard let context else {
            throw TranslatorError.modelUnavailable
        }

        state = .translating

        defer {
            if self.context != nil {
                self.state = .loaded
            }
        }

        let prompt =
            "Translate the following segment into \(targetLang), without additional explanation: \(text)"

        do {
            let result = try await context.generate(
                prompt: prompt,
                maxTokens: 2048,
                onToken: onToken
            )

            return result.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        } catch let error as TranslatorError {
            throw error

        } catch is CancellationError {
            // Отмена — не ошибка перевода: пробрасываем как есть, чтобы
            // вызывающий код мог отличить её от реального сбоя.
            throw CancellationError()

        } catch {
            throw TranslatorError.inferenceFailed
        }
    }

    func unloadModel() async {
        state = .unloading
        context = nil
        state = .unloaded
    }
}

actor LlamaContext {

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer

    private let sampling: UnsafeMutablePointer<llama_sampler>

    private var batch: llama_batch

    private var nCur: Int32 = 0

    private var invalidUTF8: [CChar] = []

    /// Ёмкость batch (в токенах). Промпт длиннее этого значения декодируется
    /// порциями — иначе запись в batch.token/pos/seq_id выходила за выделенную
    /// память (heap overflow → краш на длинном тексте).
    private static let batchCapacity: Int32 = 512

    /// Температура генерации.
    private static let temperature: Float = 0.7

    private init(
        model: OpaquePointer,
        context: OpaquePointer
    ) {
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)

        self.batch = llama_batch_init(
            Self.batchCapacity,
            0,
            1
        )

        // Сэмплер: температура 0.7, затем случайный выбор из распределения.
        // llama_sampler_chain_init в этом заголовке возвращает Optional
        // (nil только при нехватке памяти) — разворачиваем явно.
        let chain = llama_sampler_chain_init(
            llama_sampler_chain_default_params()
        )!

        llama_sampler_chain_add(
            chain,
            llama_sampler_init_temp(Self.temperature)
        )

        llama_sampler_chain_add(
            chain,
            llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max))
        )

        self.sampling = chain
    }

    deinit {
        llama_sampler_free(sampling)
        llama_batch_free(batch)

        llama_free(context)
        llama_model_free(model)

        llama_backend_free()
    }

    static func create(path: String) throws -> LlamaContext {

        llama_log_set(
            llamaLogCallback,
            nil
        )

        llama_backend_init()

        var modelParams = llama_model_default_params()

        // Полный offload слоёв на GPU через Metal.
        modelParams.n_gpu_layers = 999

        llamaLogger.notice(
            "LlamaContext.create: вызываю llama_model_load_from_file (n_gpu_layers=\(modelParams.n_gpu_layers, privacy: .public))"
        )

        guard let model = llama_model_load_from_file(
            path,
            modelParams
        ) else {

            llamaLogger.error(
                "LlamaContext.create: llama_model_load_from_file вернул nil — файл не распознан как валидный gguf/архитектура/квантование не поддерживаются текущей сборкой llama.xcframework"
            )

            llama_backend_free()

            throw TranslatorError.contextCreationFailed
        }

        llamaLogger.notice(
            "LlamaContext.create: модель загружена, создаю контекст"
        )

        let threads = max(
            1,
            min(
                6,
                ProcessInfo.processInfo.activeProcessorCount
            )
        )

        var contextParams = llama_context_default_params()

        // Для короткого перевода 2048 токенов достаточно.
        contextParams.n_ctx = 2048

        contextParams.n_threads = Int32(threads)
        contextParams.n_threads_batch = Int32(threads)

        guard let context = llama_init_from_model(
            model,
            contextParams
        ) else {

            llamaLogger.error(
                "LlamaContext.create: llama_init_from_model вернул nil (n_ctx=2048, threads=\(threads, privacy: .public)) — вероятно не хватает памяти под контекст, либо параметры контекста несовместимы с моделью"
            )

            llama_model_free(model)
            llama_backend_free()

            throw TranslatorError.contextCreationFailed
        }

        llamaLogger.notice(
            "LlamaContext.create: контекст создан успешно"
        )

        return LlamaContext(
            model: model,
            context: context
        )
    }

    func generate(
        prompt: String,
        maxTokens: Int32,
        onToken: @escaping @Sendable (String) -> Void
    ) throws -> String {

        // Полностью очищаем KV-cache перед каждым новым переводом.
        // Это важно, поскольку один и тот же context используется
        // для нескольких переводов.
        llama_memory_clear(
            llama_get_memory(context),
            true
        )

        nCur = 0

        // HY-MT2 является chat-моделью.
        // Используем формат Hunyuan chat template.
        guard let formattedPrompt = applyChatTemplate(
            userContent: prompt
        ) else {

            llamaLogger.error(
                "generate: не удалось применить chat template hunyuan-dense"
            )

            throw TranslatorError.inferenceFailed
        }

        // BOS уже находится внутри chat template.
        // Поэтому llama_tokenize не должен добавлять его второй раз.
        let shouldAddBOS = false

        // Текст пользователя в системный лог не пишем (.private): приложение
        // обещает, что переводимый текст не покидает устройство, а .public-логи
        // попадают в sysdiagnose и Console.app.
        llamaLogger.notice(
            "generate: chat_template hunyuan-dense применён, длина prompt = \(formattedPrompt.utf8.count, privacy: .public) байт"
        )

        // parseSpecial = true нужен для того, чтобы специальные токены
        // HY-MT2 распознавались именно как специальные токены.
        let tokens = tokenize(
            formattedPrompt,
            addBOS: shouldAddBOS,
            parseSpecial: true
        )

        // Если токенизация не удалась (вернула пустой массив) — дальше идти
        // нельзя: ниже обращение к batch.logits[n_tokens - 1] давало индекс -1.
        guard !tokens.isEmpty else {
            throw TranslatorError.inferenceFailed
        }

        // Сколько места осталось после prompt.
        let available =
            Int(llama_n_ctx(context)) - tokens.count

        guard available > 0 else {
            throw TranslatorError.inputTooLong
        }

        let effectiveMaxTokens =
            min(
                Int(maxTokens),
                available
            )

        // Декодируем prompt порциями не больше ёмкости batch.
        // Logits нужны только у самого последнего токена всего prompt.
        let chunkSize = Int(Self.batchCapacity)
        var offset = 0

        while offset < tokens.count {

            if Task.isCancelled {
                throw CancellationError()
            }

            let end = min(offset + chunkSize, tokens.count)
            let isLastChunk = end == tokens.count

            batch.n_tokens = 0

            for i in offset..<end {

                let slot = Int(batch.n_tokens)

                batch.token[slot] = tokens[i]

                batch.pos[slot] = Int32(i)

                batch.n_seq_id[slot] = 1

                batch.seq_id[slot]![0] = 0

                batch.logits[slot] = 0

                batch.n_tokens += 1
            }

            if isLastChunk {
                batch.logits[Int(batch.n_tokens) - 1] = 1
            }

            guard llama_decode(
                context,
                batch
            ) == 0 else {

                throw TranslatorError.inferenceFailed
            }

            offset = end
        }

        nCur = Int32(tokens.count)

        invalidUTF8.removeAll(
            keepingCapacity: true
        )

        var output = ""

        for _ in 0..<effectiveMaxTokens {

            // Кооперативная отмена: если задача (Task), в рамках которой
            // выполняется эта генерация, была отменена (пользователь
            // продолжил печатать и schedulePreview() запустил новую),
            // немедленно прерываем цикл — иначе актор останется занят
            // устаревшей генерацией и заблокирует следующий запрос.
            if Task.isCancelled {
                throw CancellationError()
            }

            let token = llama_sampler_sample(
                sampling,
                context,
                batch.n_tokens - 1
            )

            // ============================================================
            // ВАЖНО:
            //
            // llama.cpp в GGUF этой модели сообщает только 120020
            // как EOG, хотя реальные специальные токены HY-MT2
            // содержат также:
            //
            // 120008 = <｜hy_EOT｜>
            // 120001 = <｜hy_end_of_sentence｜>
            //
            // В логах модели 120008 явно отмечен как:
            // "is not marked as EOG"
            //
            // Поэтому проверяем их вручную.
            // ============================================================

            let isEndOfGeneration =
                llama_vocab_is_eog(vocab, token) ||
                token == 120008 || // <｜hy_EOT｜>
                token == 120001   // <｜hy_end_of_sentence｜>

            if isEndOfGeneration {
                break
            }

            // Преобразуем токен в UTF-8 fragment.
            let chars = tokenToPiece(token)

            if !chars.isEmpty {
                invalidUTF8.append(contentsOf: chars)

                if let str = String(
                    validatingUTF8: invalidUTF8 + [0]
                ) {

                    output += str

                    invalidUTF8.removeAll(
                        keepingCapacity: true
                    )

                    // Потоковый вывод в UI.
                    onToken(str)

                } else if invalidUTF8.count > 8 {
                    // Максимальная длина корректной UTF-8 последовательности —
                    // 4 байта. Если накопилось больше, а строка так и не
                    // стала валидной, байты битые: сбрасываем их, иначе
                    // весь дальнейший вывод навсегда «застрял» бы в буфере.
                    invalidUTF8.removeAll(
                        keepingCapacity: true
                    )
                }
            }

            // Готовим следующий decode.
            batch.n_tokens = 0

            batch.token[0] = token

            batch.pos[0] = nCur

            batch.n_seq_id[0] = 1

            batch.seq_id[0]![0] = 0

            batch.logits[0] = 1

            batch.n_tokens = 1

            guard llama_decode(
                context,
                batch
            ) == 0 else {

                throw TranslatorError.inferenceFailed
            }

            nCur += 1
        }

        return output
    }

    private func tokenize(
        _ text: String,
        addBOS: Bool,
        parseSpecial: Bool = false
    ) -> [llama_token] {

        let count = text.utf8.count

        var capacity = count + (addBOS ? 1 : 0) + 8

        // llama_tokenize возвращает отрицательное значение (-нужный размер),
        // если буфер мал — тогда повторяем с точным размером, а не отдаём
        // пустой результат.
        for _ in 0..<2 {

            let ptr = UnsafeMutablePointer<llama_token>.allocate(
                capacity: capacity
            )

            defer {
                ptr.deallocate()
            }

            let n = llama_tokenize(
                vocab,
                text,
                Int32(count),
                ptr,
                Int32(capacity),
                addBOS,
                parseSpecial
            )

            if n >= 0 {
                return (0..<Int(n)).map {
                    ptr[$0]
                }
            }

            capacity = Int(-n) + 8
        }

        return []
    }

    /// Формирует chat prompt из GGUF metadata HY-MT2.
    ///
    /// Формат:
    ///
    /// <｜hy_begin▁of▁sentence｜>
    /// <｜hy_User｜>
    /// {{ content }}
    /// <｜hy_Assistant｜>
    ///
    /// BOS уже находится внутри шаблона.
    private func applyChatTemplate(
        userContent: String
    ) -> String? {

        return
            "<｜hy_begin▁of▁sentence｜>" +
            "<｜hy_User｜>" +
            userContent +
            "<｜hy_Assistant｜>"
    }

    /// Преобразует один llama_token в UTF-8 fragment.
    ///
    /// В GGUF HY-MT2 максимальная длина token piece указана как 1024 байта.
    /// Поэтому фиксированный буфер 256 байт был недостаточен.
    ///
    /// Здесь используется динамический буфер с повторной попыткой.
    private func tokenToPiece(
        _ token: llama_token
    ) -> [CChar] {

        var bufferSize = 256

        while bufferSize <= 4096 {

            var buffer = [CChar](
                repeating: 0,
                count: bufferSize
            )

            let n = llama_token_to_piece(
                vocab,
                token,
                &buffer,
                Int32(buffer.count),
                0,
                false
            )

            // n < 0 обычно означает, что буфер недостаточного размера.
            if n < 0 {
                bufferSize *= 2
                continue
            }

            if n == 0 {
                return []
            }

            // Если результат помещается целиком —
            // возвращаем его.
            if n < Int32(buffer.count) {
                return Array(
                    buffer.prefix(Int(n))
                )
            }

            // Если n достиг размера буфера,
            // увеличиваем буфер и пробуем ещё раз.
            bufferSize *= 2
        }

        llamaLogger.warning(
            "tokenToPiece: не удалось получить полный token piece для token=\(token, privacy: .public)"
        )

        return []
    }
}

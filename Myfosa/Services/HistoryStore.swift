import Foundation
import CoreData

extension Notification.Name {
    /// Постится при любом изменении архива истории (добавление или полная очистка),
    /// чтобы экран «История» мог обновить список.
    static let historyArchiveDidChange = Notification.Name("historyArchiveDidChange")
}

final class HistoryStore {
    static let shared = HistoryStore()
    let container: NSPersistentContainer

    private init() {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "HistoryEntry"
        entity.managedObjectClassName = "NSManagedObject"
        let fields: [(String, NSAttributeType, Bool)] = [
            ("sourceText", .stringAttributeType, false), ("translatedText", .stringAttributeType, false),
            ("sourceLang", .stringAttributeType, false), ("targetLang", .stringAttributeType, false), ("timestamp", .dateAttributeType, false)
        ]
        entity.properties = fields.map { name, type, optional in
            let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = optional; return a
        }
        model.entities = [entity]
        container = NSPersistentContainer(name: "Myfosa", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: Self.storeURL())
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { fatalError("Core Data store failed: \(error)") }
        }
    }

    private static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("History.sqlite")
    }

    /// Добавляет один перевод в постоянный архив (экран «История»).
    /// Вызывается не сразу при подтверждении перевода, а когда текущая сессия
    /// «уходит» в архив — см. `TranslatorViewModel.appDidEnterBackground()`.
    func add(_ item: TranslationItem) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "HistoryEntry", into: container.viewContext)
        object.setValue(item.source, forKey: "sourceText")
        object.setValue(item.translated, forKey: "translatedText")
        object.setValue(item.sourceLang, forKey: "sourceLang")
        object.setValue(item.targetLang, forKey: "targetLang")
        object.setValue(item.date, forKey: "timestamp")
        try? container.viewContext.save()
        NotificationCenter.default.post(name: .historyArchiveDidChange, object: nil)
    }

    /// Возвращает весь сохранённый архив истории, от новых к старым.
    func fetchAll() -> [TranslationItem] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "HistoryEntry")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        guard let objects = try? container.viewContext.fetch(request) else { return [] }
        return objects.map { object in
            TranslationItem(
                source: object.value(forKey: "sourceText") as? String ?? "",
                translated: object.value(forKey: "translatedText") as? String ?? "",
                sourceLang: object.value(forKey: "sourceLang") as? String ?? "",
                targetLang: object.value(forKey: "targetLang") as? String ?? "",
                date: object.value(forKey: "timestamp") as? Date ?? .now
            )
        }
    }

    /// Полностью очищает сохранённую историю переводов. Необратимо.
    func clearAll() {
        let context = container.viewContext
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: "HistoryEntry")
        if let objects = try? context.fetch(fetchRequest) {
            objects.forEach { context.delete($0) }
            try? context.save()
        }
        NotificationCenter.default.post(name: .historyArchiveDidChange, object: nil)
    }
}

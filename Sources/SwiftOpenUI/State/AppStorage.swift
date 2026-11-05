import Foundation

/// A property wrapper that reads and writes a value in `UserDefaults` and
/// re-renders when it changes (SwiftUI parity).
///
/// It works both in a view (like `@State`) and inside an `ObservableObject`
/// (like `@Published`). Every `@AppStorage` with the same key and store sees a
/// write made through any of them.
@propertyWrapper
public struct AppStorage<Value>: AnyStateStorageProvider, AnyPublishedProvider {
    public let storage: AppStorageStorage<Value>

    init(
        key: String,
        store: UserDefaults?,
        defaultValue: Value,
        read: @escaping (UserDefaults, String) -> Value?,
        write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        storage = AppStorageStorage(
            key: key, store: store ?? .standard, defaultValue: defaultValue, read: read, write: write)
    }

    public var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.setValue(newValue) }
    }

    public var projectedValue: Binding<Value> {
        let storage = self.storage
        return Binding(get: { storage.value }, set: { storage.setValue($0) })
    }

    public var anyStorage: AnyStateStorage { storage }
    public var anyPublished: AnyPublishedStorage { storage }
}

extension AppStorage where Value == Bool {
    public init(wrappedValue: Bool, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.object(forKey: $1) as? Bool }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value == Int {
    public init(wrappedValue: Int, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.object(forKey: $1) as? Int }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value == Double {
    public init(wrappedValue: Double, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.object(forKey: $1) as? Double }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value == String {
    public init(wrappedValue: String, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.string(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value == URL {
    public init(wrappedValue: URL, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.url(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value == Data {
    public init(wrappedValue: Data, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.data(forKey: $1) }, write: { $0.set($2, forKey: $1) })
    }
}

extension AppStorage where Value: RawRepresentable, Value.RawValue == String {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { $0.string(forKey: $1).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }
}

extension AppStorage where Value: RawRepresentable, Value.RawValue == Int {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) {
        self.init(key: key, store: store, defaultValue: wrappedValue,
                  read: { ($0.object(forKey: $1) as? Int).flatMap(Value.init(rawValue:)) },
                  write: { $0.set($2.rawValue, forKey: $1) })
    }
}

/// Backing storage for `@AppStorage`. The value lives in `UserDefaults`;
/// this object only notifies the views and observable objects that use it.
public final class AppStorageStorage<Value>: AnyStateStorage, AnyPublishedStorage, GenerationTracked, AppStorageChangeObserver {
    let key: String
    private let store: UserDefaults
    private let defaultValue: Value
    private let read: (UserDefaults, String) -> Value?
    private let write: (UserDefaults, String, Value) -> Void
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    public weak var host: AnyViewHost?
    public private(set) var generation: UInt64 = 0

    init(
        key: String,
        store: UserDefaults,
        defaultValue: Value,
        read: @escaping (UserDefaults, String) -> Value?,
        write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        self.key = key
        self.store = store
        self.defaultValue = defaultValue
        self.read = read
        self.write = write
        AppStorageRegistry.shared.add(self)
    }

    public var value: Value {
        recordDependencyRead(self)
        return read(store, key) ?? defaultValue
    }

    public func setValue(_ newValue: Value) {
        write(store, key, newValue)
        // Outside Apple platforms UserDefaults may only reach disk later; a
        // setting must survive the app being closed right after the change.
        store.synchronize()
        notifyChange()
        AppStorageRegistry.shared.notifyOthers(of: key, except: self)
    }

    func notifyChange() {
        generation += 1
        for observer in observers.values {
            observer()
        }
        host?.scheduleRebuild()
    }

    public func setObserver(token: ObjectIdentifier, _ observer: @escaping () -> Void) {
        observers[token] = observer
    }

    public func restoreValue(from other: AnyStateStorage) {
        // The value lives in UserDefaults — nothing to restore.
    }
}

/// An `@AppStorage` that is told when another one with the same key writes.
protocol AppStorageChangeObserver: AnyObject {
    var key: String { get }
    func notifyChange()
}

/// Every live `@AppStorage`, held weakly, so a write through one notifies the
/// others with the same key.
final class AppStorageRegistry {
    static let shared = AppStorageRegistry()

    private struct WeakEntry {
        weak var storage: AppStorageChangeObserver?
    }

    private let lock = NSLock()
    private var entries: [WeakEntry] = []

    func add(_ storage: AppStorageChangeObserver) {
        lock.lock()
        entries.removeAll { $0.storage == nil }
        entries.append(WeakEntry(storage: storage))
        lock.unlock()
    }

    func notifyOthers(of key: String, except writer: AppStorageChangeObserver) {
        lock.lock()
        let others = entries.compactMap(\.storage).filter { $0 !== writer && $0.key == key }
        lock.unlock()
        for storage in others {
            storage.notifyChange()
        }
    }
}

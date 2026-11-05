/// A two-way reference to a value owned by a parent view's @State.
/// Created via `$stateName` (State's projectedValue).
///
/// Binding lifetime is tied to the parent view's render cycle.
/// The get/set closures capture the parent's StateStorage, so mutations
/// flow through the same lock + scheduling path as direct @State writes.
@propertyWrapper
@dynamicMemberLookup
public struct Binding<Value> {
    public let get: () -> Value
    public let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    /// Lets a closure take a binding as `$name` (`ForEach($items) { $item in ... }`).
    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    /// Projects self so `$bindingName` returns a `Binding<Value>` (SwiftUI parity).
    public var projectedValue: Binding<Value> { self }

    /// Creates a binding with an immutable value (SwiftUI-compatible).
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    /// Projects a binding to a property of the bound value, so that
    /// `$task.title` is a `Binding<String>` (SwiftUI parity).
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        let get = self.get
        let set = self.set
        return Binding<Subject>(
            get: { get()[keyPath: keyPath] },
            set: { newValue in
                var value = get()
                value[keyPath: keyPath] = newValue
                set(value)
            }
        )
    }
}

// MARK: - Collection of bindings

// A binding to a mutable collection is itself a collection of bindings to its
// elements, so `$items[i]` and `ForEach($items) { $item in ... }` work (SwiftUI parity).

extension Binding: Sequence where Value: MutableCollection {
    public typealias Element = Binding<Value.Element>
    public typealias Iterator = IndexingIterator<Binding<Value>>
    public typealias SubSequence = Slice<Binding<Value>>
}

extension Binding: Collection where Value: MutableCollection {
    public typealias Index = Value.Index
    public typealias Indices = Value.Indices

    public var startIndex: Index { wrappedValue.startIndex }
    public var endIndex: Index { wrappedValue.endIndex }
    public var indices: Indices { wrappedValue.indices }

    public func index(after i: Index) -> Index { wrappedValue.index(after: i) }

    public subscript(position: Index) -> Binding<Value.Element> {
        let get = self.get
        let set = self.set
        return Binding<Value.Element>(
            get: { get()[position] },
            set: { newValue in
                var value = get()
                value[position] = newValue
                set(value)
            }
        )
    }
}

extension Binding: BidirectionalCollection where Value: BidirectionalCollection & MutableCollection {
    public func index(before i: Index) -> Index { wrappedValue.index(before: i) }
}

extension Binding: RandomAccessCollection where Value: RandomAccessCollection & MutableCollection {}

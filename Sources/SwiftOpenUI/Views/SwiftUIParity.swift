import Foundation

// SwiftUI API forms used by common app code (lists of bindings, value-based
// sidebars, toolbars without ToolbarItem, ...), expressed on top of the
// primitives SwiftOpenUI already renders.

// MARK: - ForEach over a binding

extension ForEach {
    /// SwiftUI's `ForEach($items) { $item in ... }`.
    ///
    /// Each element binding follows its element by `id`, so a row that is
    /// still on screen while the collection shrinks reads a valid element.
    public init<C>(
        _ data: Binding<C>,
        @ViewBuilder content: @escaping (Binding<C.Element>) -> Content
    ) where C: MutableCollection & RandomAccessCollection,
            C.Element: Identifiable,
            Data == Binding<C.Element>,
            ID == C.Element.ID
    {
        self.data = data.wrappedValue.indices.map { index in
            let last = LastValueBox(data.wrappedValue[index])
            let id = last.value.id
            return Binding<C.Element>(
                get: {
                    let items = data.wrappedValue
                    if items.indices.contains(index), items[index].id == id {
                        last.value = items[index]
                    } else if let found = items.first(where: { $0.id == id }) {
                        last.value = found
                    }
                    return last.value
                },
                set: { newValue in
                    var items = data.wrappedValue
                    if items.indices.contains(index), items[index].id == id {
                        items[index] = newValue
                    } else if let found = items.firstIndex(where: { $0.id == id }) {
                        items[found] = newValue
                    } else {
                        return
                    }
                    data.wrappedValue = items
                }
            )
        }
        self.id = \Binding<C.Element>.wrappedValue.id
        self.content = content
    }

    /// SwiftUI's `.onDelete(perform:)`.
    ///
    /// The desktop backends have no swipe-to-delete row gesture, so the action
    /// is accepted but rows are not made deletable by it; offer deletion with a
    /// `.contextMenu` or a button instead.
    public func onDelete(perform action: ((IndexSet) -> Void)?) -> ForEach {
        self
    }
}

private final class LastValueBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - List

extension List {
    /// SwiftUI's `List(items) { item in ... }`.
    public init<Data: Identifiable, RowContent: View>(
        _ data: [Data],
        @ViewBuilder rowContent: @escaping (Data) -> RowContent
    ) where Content == ForEach<Data, Data.ID, RowContent> {
        self.content = ForEach(data, content: rowContent)
    }

    /// SwiftUI's `List($items) { $item in ... }`.
    public init<C, RowContent: View>(
        _ data: Binding<C>,
        @ViewBuilder rowContent: @escaping (Binding<C.Element>) -> RowContent
    ) where C: MutableCollection & RandomAccessCollection,
            C.Element: Identifiable,
            Content == ForEach<Binding<C.Element>, C.Element.ID, RowContent>
    {
        self.content = ForEach(data, content: rowContent)
    }

    /// SwiftUI's `List(selection:)`: a `NavigationLink(value:)` inside the list
    /// selects its value instead of pushing it, as in a sidebar.
    public init<SelectionValue: Hashable, C: View>(
        selection: Binding<SelectionValue?>,
        @ViewBuilder content: () -> C
    ) where Content == EnvironmentModifierView<C, ListSelection?> {
        let current = selection.wrappedValue.map { AnyHashable($0) }
        let listSelection = ListSelection(selected: current) { value in
            if let typed = value.base as? SelectionValue {
                selection.wrappedValue = typed
            }
        }
        self.content = content().environment(\.listSelection, listSelection)
    }

    /// SwiftUI's `List(selection:)` with a non-optional selection.
    public init<SelectionValue: Hashable, C: View>(
        selection: Binding<SelectionValue>,
        @ViewBuilder content: () -> C
    ) where Content == EnvironmentModifierView<C, ListSelection?> {
        let listSelection = ListSelection(selected: AnyHashable(selection.wrappedValue)) { value in
            if let typed = value.base as? SelectionValue {
                selection.wrappedValue = typed
            }
        }
        self.content = content().environment(\.listSelection, listSelection)
    }
}

/// The selection of the enclosing `List(selection:)`, read by backends when they
/// render a value-based `NavigationLink`.
public struct ListSelection {
    /// The selected value, if any.
    public let selected: AnyHashable?
    /// Selects a value.
    public let select: (AnyHashable) -> Void

    public init(selected: AnyHashable?, select: @escaping (AnyHashable) -> Void) {
        self.selected = selected
        self.select = select
    }
}

private struct ListSelectionKey: EnvironmentKey {
    static let defaultValue: ListSelection? = nil
}

extension EnvironmentValues {
    /// The selection of the enclosing `List(selection:)`, or `nil` outside one.
    public var listSelection: ListSelection? {
        get { self[ListSelectionKey.self] }
        set { self[ListSelectionKey.self] = newValue }
    }
}

// MARK: - NavigationLink with a destination view

extension NavigationLink {
    /// SwiftUI's `NavigationLink(destination: Detail()) { label }`.
    public init<Label: View>(destination: Destination, @ViewBuilder label: () -> Label) {
        self.init(title: "", destination: { destination }, label: label)
    }

    /// SwiftUI's `NavigationLink("Title", destination: Detail())`.
    public init(_ label: String, destination: Destination) {
        self.init(label, destination: { destination })
    }
}

// MARK: - Toolbar content without ToolbarItem

extension ToolbarContentBuilder {
    /// SwiftUI accepts plain views in `.toolbar { ... }`; they go to the primary action area.
    public static func buildExpression<Content: View>(_ expression: Content) -> ToolbarContent {
        ToolbarContent(items: [AnyToolbarItem(ToolbarItem(placement: .primaryAction) { expression })])
    }
}

// MARK: - Accent color

extension Color {
    /// The app's accent color (the system blue, as in SwiftUI's default).
    public static var accentColor: Color { Color(red: 0.0, green: 0.48, blue: 1.0) }

    /// SwiftUI's `.tint` style, as in `.foregroundStyle(.tint)` (Xcode's app template).
    public static var tint: Color { accentColor }
}

// MARK: - View labels

extension Toggle {
    /// SwiftUI's `Toggle(isOn: $flag) { Text("Label") }`.
    public init<Label: View>(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        self.init(menuItemLabelText(from: label()), isOn: isOn)
    }
}

extension View {
    /// SwiftUI's `.navigationTitle($title)`: shows the bound title.
    public func navigationTitle(_ title: Binding<String>) -> TitledView<Self> {
        navigationTitle(title.wrappedValue)
    }
}

/// Text of a control built from a view label (`Text` or `Label`), or an empty string.
func menuItemLabelText<V: View>(from label: V) -> String {
    if let text = label as? Text {
        return text.content
    }
    for child in Mirror(reflecting: label).children {
        if let text = child.value as? Text {
            return text.content
        }
        if let title = child.value as? String, child.label == "title" {
            return title
        }
    }
    return ""
}

// MARK: - Collection editing used with lists

extension RangeReplaceableCollection where Self: MutableCollection {
    /// SwiftUI's `remove(atOffsets:)`, as used from `.onDelete`.
    public mutating func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) {
            remove(at: index(startIndex, offsetBy: offset))
        }
    }
}

extension MutableCollection where Self: RangeReplaceableCollection {
    /// SwiftUI's `move(fromOffsets:toOffset:)`, as used from `.onMove`.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[index(startIndex, offsetBy: $0)] }
        let removedBefore = source.filter { $0 < destination }.count
        remove(atOffsets: source)
        let target = index(startIndex, offsetBy: destination - removedBefore)
        insert(contentsOf: moving, at: target)
    }
}

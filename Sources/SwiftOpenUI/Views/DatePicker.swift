import Foundation

/// A simple date value type for DatePicker (no Foundation dependency).
public struct DateComponents: Equatable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Creates DateComponents for today's date.
    public init() {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        self.year = components.year ?? 1970
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }
}

/// A date picker backed by a native calendar widget.
public struct DatePicker: View {
    public typealias Body = Never

    public let title: String
    public let selection: Binding<DateComponents>?
    public let onChange: ((DateComponents) -> Void)?

    /// The bound date when the picker also shows the time of day
    /// (`displayedComponents` includes `.hourAndMinute`).
    public private(set) var timeSelection: Binding<Date>?

    /// Creates a DatePicker with a binding.
    public init(_ title: String = "", selection: Binding<DateComponents>) {
        self.title = title
        self.selection = selection
        self.onChange = nil
    }

    /// Creates a DatePicker with a callback.
    public init(_ title: String = "", onChange: ((DateComponents) -> Void)? = nil) {
        self.title = title
        self.selection = nil
        self.onChange = onChange
    }

    /// SwiftUI's `DatePicker(_:selection:displayedComponents:)` over a `Date`.
    ///
    /// The native widget picks the calendar day; with `.hourAndMinute` the
    /// backends also show `timeControls` for the hour and minute.
    public init(
        _ title: String = "",
        selection: Binding<Date>,
        displayedComponents: DatePickerComponents = [.date, .hourAndMinute]
    ) {
        let calendar = Calendar.current
        let day = Binding<DateComponents>(
            get: {
                let parts = calendar.dateComponents([.year, .month, .day], from: selection.wrappedValue)
                return DateComponents(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
            },
            set: { newDay in
                var parts = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: selection.wrappedValue)
                parts.year = newDay.year
                parts.month = newDay.month
                parts.day = newDay.day
                if let date = calendar.date(from: parts) {
                    selection.wrappedValue = date
                }
            }
        )
        self.init(title, selection: day)
        if displayedComponents.contains(.hourAndMinute) {
            self.timeSelection = selection
        }
    }

    /// Hour and minute pickers for `timeSelection`, built from views every
    /// backend renders, so backends only place them next to the calendar.
    public var timeControls: AnyView? {
        guard let time = timeSelection else { return nil }
        let calendar = Calendar.current
        func component(_ unit: Calendar.Component) -> Binding<Int> {
            Binding(
                get: { calendar.component(unit, from: time.wrappedValue) },
                set: { newValue in
                    var parts = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: time.wrappedValue)
                    if unit == .hour { parts.hour = newValue } else { parts.minute = newValue }
                    if let date = calendar.date(from: parts) {
                        time.wrappedValue = date
                    }
                }
            )
        }
        let twoDigits = { (n: Int) in n < 10 ? "0\(n)" : "\(n)" }
        return AnyView(HStack(spacing: 4) {
            Picker("", selection: component(.hour), options: (0..<24).map(twoDigits))
            Text(":")
            Picker("", selection: component(.minute), options: (0..<60).map(twoDigits))
        })
    }

    public var body: Never { fatalError("DatePicker is a primitive view") }
}

/// The parts of a date a `DatePicker` shows (SwiftUI parity).
public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let date = DatePickerComponents(rawValue: 1 << 0)
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 1)
}

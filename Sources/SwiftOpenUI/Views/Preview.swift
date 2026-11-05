/// SwiftUI's `#Preview`. Previews are an Xcode feature; on other platforms the
/// body is type-checked and the macro expands to nothing.
@freestanding(declaration)
public macro Preview(
    _ name: String? = nil,
    @ViewBuilder body: @escaping @MainActor () -> any View
) = #externalMacro(module: "SwiftOpenUIMacros", type: "PreviewMacro")

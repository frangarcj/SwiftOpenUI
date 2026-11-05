import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

/// `#Preview { ... }` outside Xcode: the closure is type-checked and nothing is
/// generated, since only Xcode shows previews.
public struct PreviewMacro: DeclarationMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

@main
struct SwiftOpenUIMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PreviewMacro.self]
}

// State declared in the `App` (`@State` in the struct marked `@main`), as in
// SwiftUI. The backends evaluate `app.body` once to create the windows; when
// the app has state, each window shows an `AppWindowRoot` instead, a view that
// re-evaluates `app.body` and owns the app's state, so a change re-renders it.

/// The scene of `app`, with each window group's content rooted in the app's
/// state when the app has any. Backends call this instead of `app.body`.
public func appScene<A: App>(_ app: A) -> A.Body {
    let scene = app.body
    guard appHasState(app) else { return scene }
    var nextWindow = 0
    return installingAppRoots(in: scene, app: app, nextWindow: &nextWindow)
}

/// A window's content view for an app with state.
///
/// It reflects as the app itself, so the view host finds and wires the app's
/// `@State` like a view's, and re-evaluates `body` (the app's body) on change.
public struct AppWindowRoot<A: App>: View, CustomReflectable {
    let app: A
    let window: Int

    public var body: AnyView {
        let contents = windowContents(of: app.body)
        return contents.indices.contains(window) ? contents[window] : AnyView(EmptyView())
    }

    public var customMirror: Mirror { Mirror(reflecting: app) }
}

private func appHasState<A: App>(_ app: A) -> Bool {
    Mirror(reflecting: app).children.contains { $0.value is AnyStateStorageProvider }
}

// MARK: - Walking the scene tree

private protocol AppRootInstallable {
    func installingAppRoots<A: App>(app: A, nextWindow: inout Int) -> Self
}

private protocol WindowContentsProviding {
    var windowContents: [AnyView] { get }
}

private func installingAppRoots<S: Scene, A: App>(in scene: S, app: A, nextWindow: inout Int) -> S {
    guard let installable = scene as? AppRootInstallable else { return scene }
    return installable.installingAppRoots(app: app, nextWindow: &nextWindow) as! S
}

private func windowContents<S: Scene>(of scene: S) -> [AnyView] {
    if let provider = scene as? WindowContentsProviding {
        return provider.windowContents
    }
    if S.Body.self != Never.self {
        return windowContents(of: scene.body)
    }
    return []
}

extension WindowGroup: AppRootInstallable, WindowContentsProviding {
    fileprivate func installingAppRoots<A: App>(app: A, nextWindow: inout Int) -> WindowGroup {
        var rooted = self
        rooted.appRoot = AnyView(AppWindowRoot(app: app, window: nextWindow))
        nextWindow += 1
        return rooted
    }

    fileprivate var windowContents: [AnyView] { [AnyView(content)] }
}

extension TupleScene: AppRootInstallable, WindowContentsProviding {
    fileprivate func installingAppRoots<A: App>(app: A, nextWindow: inout Int) -> TupleScene {
        TupleScene(
            SwiftOpenUI.installingAppRoots(in: scene0, app: app, nextWindow: &nextWindow),
            SwiftOpenUI.installingAppRoots(in: scene1, app: app, nextWindow: &nextWindow)
        )
    }

    fileprivate var windowContents: [AnyView] {
        SwiftOpenUI.windowContents(of: scene0) + SwiftOpenUI.windowContents(of: scene1)
    }
}

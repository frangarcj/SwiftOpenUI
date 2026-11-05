import WinSDK
import CWin32
import CWin32Bridge
import SwiftOpenUI
import Foundation

// MARK: - Navigation context (Win32-specific)

/// Entry in the navigation stack.
struct Win32NavigationEntry {
    let title: String
    let hwnd: HWND
    /// Toolbar items this entry put in the header; shown only while it is on top.
    var toolbarWindows: [HWND] = []
}

/// Re-pushes one entry of a navigation stack onto a new context.
typealias Win32NavigationRestore = (Win32NavigationContext) -> Void

/// The pushed entries of a NavigationStack, kept by the owning view host so
/// that the stack survives a rebuild of the view that contains it (a rebuild
/// creates a new stack with only the root).
final class Win32NavigationMemory {
    var entries: [Win32NavigationRestore] = []
}

/// Manages the navigation stack state for Win32.
/// Shared between NavigationStack and NavigationLink via thread-local
/// capture at render time (same pattern as GTK4 backend).
class Win32NavigationContext {
    let container: HWND
    let headerContainer: HWND
    let titleLabel: HWND
    let backButton: HWND
    let contentArea: HWND
    let hInstance: HINSTANCE
    var entries: [Win32NavigationEntry] = []

    /// Resources to clean up on deinit.
    var titleFont: HFONT?
    var backControlID: WORD = 0

    /// Registry for type-based navigation destinations.
    let destinationRegistry = Win32DestinationRegistry()

    /// Optional binding to a NavigationPath for programmatic navigation sync.
    /// Note: sync is push/pop mirroring only — external path mutations are
    /// not observed (same limitation as GTK4 backend).
    var pathBinding: Binding<NavigationPath>?
    private var isSyncing = false

    /// Pushed entries kept across rebuilds, when the stack has an owning view host.
    var memory: Win32NavigationMemory?

    init(container: HWND, headerContainer: HWND, titleLabel: HWND,
         backButton: HWND, contentArea: HWND, hInstance: HINSTANCE) {
        self.container = container
        self.headerContainer = headerContainer
        self.titleLabel = titleLabel
        self.backButton = backButton
        self.contentArea = contentArea
        self.hInstance = hInstance
    }

    deinit {
        if let font = titleFont { DeleteObject(font) }
        if backControlID != 0 { unregisterCommandHandler(controlID: backControlID) }
    }

    /// Push a new view onto the navigation stack.
    ///
    /// `restore` re-creates this entry on a new context after a rebuild; pass it
    /// when calling `content` again would not reproduce the entry.
    func push(title: String, restore: Win32NavigationRestore? = nil, content: @escaping () -> HWND?) {
        memory?.entries.append(restore ?? { context in
            context.push(title: title, content: content)
        })

        // Hide current top, with its toolbar items
        if let top = entries.last {
            ShowWindow(top.hwnd, SW_HIDE)
            for item in top.toolbarWindows { ShowWindow(item, SW_HIDE) }
        }
        let toolbarBefore = Set(win32ToolbarItemWindows(in: headerContainer))

        setCurrentNavigationContext(self)
        let prevEnv = getCurrentEnvironment()
        var env = prevEnv
        env[NavigateKey.self] = NavigateAction(
            push: { [weak self] value in self?.pushValue(value) },
            pop: { [weak self] in self?.pop() },
            popToRoot: { [weak self] in self?.popToRoot() }
        )
        setCurrentEnvironment(env)

        guard let childHwnd = content() else {
            setCurrentEnvironment(prevEnv)
            setCurrentNavigationContext(nil)
            return
        }
        setCurrentEnvironment(prevEnv)
        setCurrentNavigationContext(nil)

        // Size to fill content area
        var rect = RECT()
        GetClientRect(contentArea, &rect)
        SetWindowPos(childHwnd, nil, 0, 0,
                     rect.right - rect.left, rect.bottom - rect.top,
                     UINT(SWP_NOZORDER))

        // Toolbar items the pushed view added to the header belong to it.
        let toolbarWindows = win32ToolbarItemWindows(in: headerContainer).filter { !toolbarBefore.contains($0) }
        entries.append(Win32NavigationEntry(title: title, hwnd: childHwnd, toolbarWindows: toolbarWindows))
        updateHeader()
    }

    /// Push a hashable value, resolving destination via the registry.
    func pushValue(_ value: AnyHashable) {
        guard let factory = destinationRegistry.resolve(value) else { return }
        let title = String(describing: value.base)

        push(title: title, restore: { context in context.pushValue(value) }) {
            factory()
        }
        syncPathAfterPush(value)
    }

    /// Pop the top view from the navigation stack.
    func pop() {
        guard entries.count > 1 else { return }
        if memory?.entries.isEmpty == false {
            memory?.entries.removeLast()
        }

        let removed = entries.removeLast()
        for item in removed.toolbarWindows { DestroyWindow(item) }
        DestroyWindow(removed.hwnd)

        // Show previous, with its toolbar items
        if let top = entries.last {
            ShowWindow(top.hwnd, SW_SHOW)
            for item in top.toolbarWindows { ShowWindow(item, SW_SHOW) }
        }

        updateHeader()
        syncPathAfterPop()
    }

    /// Pop to the root view.
    func popToRoot() {
        while entries.count > 1 {
            pop()
        }
    }

    // MARK: - Path binding sync

    func beginSync() { isSyncing = true }
    func endSync() { isSyncing = false }

    private func syncPathAfterPush(_ value: AnyHashable) {
        guard let pathBinding = pathBinding, !isSyncing else { return }
        isSyncing = true
        var path = pathBinding.wrappedValue
        path.elements.append(value)
        pathBinding.wrappedValue = path
        isSyncing = false
    }

    private func syncPathAfterPop() {
        guard let pathBinding = pathBinding, !isSyncing else { return }
        isSyncing = true
        var path = pathBinding.wrappedValue
        if !path.isEmpty {
            path.removeLast()
        }
        pathBinding.wrappedValue = path
        isSyncing = false
    }

    private func updateHeader() {
        let title = entries.last?.title ?? ""
        _ = title.withCString(encodedAs: UTF16.self) { wstr in
            SetWindowTextW(titleLabel, wstr)
        }
        ShowWindow(backButton, entries.count > 1 ? SW_SHOW : SW_HIDE)
        // Re-layout header to position back button and title correctly
        layoutNavContainer(self)
        // Size the visible entry to fill the content area
        if let top = entries.last {
            var caRect = RECT()
            GetClientRect(contentArea, &caRect)
            SetWindowPos(top.hwnd, nil, 0, 0,
                         caRect.right, caRect.bottom, UINT(SWP_NOZORDER))
        }
    }
}

// MARK: - Destination registry

class Win32DestinationRegistry {
    private var factories: [ObjectIdentifier: (AnyHashable) -> HWND?] = [:]

    func register<V: Hashable>(for type: V.Type, factory: @escaping (V) -> HWND?) {
        factories[ObjectIdentifier(type)] = { anyValue in
            factory(anyValue.base as! V)
        }
    }

    func resolve(_ value: AnyHashable) -> (() -> HWND?)? {
        let typeId = ObjectIdentifier(type(of: value.base))
        guard let factory = factories[typeId] else { return nil }
        return { factory(value) }
    }
}

// MARK: - Thread-local context (Win32 TLS)

private let _navContextTlsIndex: DWORD = TlsAlloc()

func setCurrentNavigationContext(_ context: Win32NavigationContext?) {
    if let context = context {
        let ptr = Unmanaged.passUnretained(context).toOpaque()
        TlsSetValue(_navContextTlsIndex, ptr)
    } else {
        TlsSetValue(_navContextTlsIndex, nil)
    }
}

func getCurrentNavigationContext() -> Win32NavigationContext? {
    guard let ptr = TlsGetValue(_navContextTlsIndex) else { return nil }
    return Unmanaged<Win32NavigationContext>.fromOpaque(ptr).takeUnretainedValue()
}

// MARK: - Title extraction

func win32ExtractTitle<V: View>(from view: V) -> String {
    return win32ExtractTitleAny(from: view)
}

private func win32ExtractTitleAny(from view: Any, depth: Int = 0) -> String {
    guard depth < 20 else { return "" }
    if let titled = view as? NavigationTitled {
        return titled.navigationTitle
    }
    let mirror = Mirror(reflecting: view)
    for child in mirror.children {
        if let titled = child.value as? NavigationTitled {
            return titled.navigationTitle
        }
    }
    for child in mirror.children {
        // Views, and the tuples/arrays a ViewBuilder stores several views in.
        if child.value is any View || win32IsViewContainer(child.value) {
            let result = win32ExtractTitleAny(from: child.value, depth: depth + 1)
            if !result.isEmpty { return result }
        }
    }
    // A composite view (e.g. a destination `TaskDetailView`) sets its title in
    // its body: look there too.
    if let view = view as? any View, let body = win32CompositeBody(of: view) {
        return win32ExtractTitleAny(from: body, depth: depth + 1)
    }
    return ""
}

/// Whether a stored value is a tuple or array a ViewBuilder keeps views in.
private func win32IsViewContainer(_ value: Any) -> Bool {
    let style = Mirror(reflecting: value).displayStyle
    return style == .tuple || style == .collection
}

/// The body of a composite view, or nil for primitive views.
private func win32CompositeBody<V: View>(of view: V) -> Any? {
    if view is any PrimitiveView || V.Body.self == Never.self {
        return nil
    }
    return view.body
}

// MARK: - Window classes

private let navContainerClassName: UnsafePointer<WCHAR> = {
    "SwiftUINavContainer".withCString(encodedAs: UTF16.self) { ptr in
        let len = wcslen(ptr) + 1
        let buf = UnsafeMutablePointer<WCHAR>.allocate(capacity: len)
        buf.initialize(from: ptr, count: len)
        return UnsafePointer(buf)
    }
}()

private var navClassRegistered = false

func registerNavClassIfNeeded(hInstance: HINSTANCE) {
    guard !navClassRegistered else { return }
    navClassRegistered = true

    var wc = WNDCLASSEXW()
    wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
    wc.lpfnWndProc = navContainerWndProc
    wc.hInstance = hInstance
    wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
    wc.lpszClassName = navContainerClassName
    RegisterClassExW(&wc)
}

/// WndProc for the navigation container — handles layout of header + content area.
private let navContainerWndProc: WNDPROC = { (hwnd, uMsg, wParam, lParam) in
    switch uMsg {
    case UINT(WM_SIZE):
        let userData = win32_GetWindowLongPtrW(hwnd!, GWLP_USERDATA)
        if userData != 0 {
            let ctx = Unmanaged<Win32NavigationContext>.fromOpaque(
                UnsafeMutableRawPointer(bitPattern: Int(userData))!
            ).takeUnretainedValue()
            layoutNavContainer(ctx)
        }
        return 0

    case UINT(WM_COMMAND):
        // Forward to root for global command dispatch (back button, etc.)
        if lParam != 0, let childHwnd = HWND(bitPattern: Int(lParam)) {
            SendMessageW(childHwnd, uMsg, wParam, lParam)
        }
        if let root = findRootWindow(from: hwnd!) as HWND? {
            return SendMessageW(root, uMsg, wParam, lParam)
        }
        return DefWindowProcW(hwnd, uMsg, wParam, lParam)

    case UINT(WM_CTLCOLORSTATIC), UINT(WM_CTLCOLORBTN):
        if let parent = GetParent(hwnd!) {
            return SendMessageW(parent, uMsg, wParam, lParam)
        }
        let hdc = HDC(bitPattern: Int(bitPattern: UInt(wParam)))
        SetBkMode(hdc, TRANSPARENT)
        return LRESULT(Int(bitPattern: GetSysColorBrush(COLOR_WINDOW)))

    case UINT(WM_NCDESTROY):
        let userData = win32_GetWindowLongPtrW(hwnd!, GWLP_USERDATA)
        if userData != 0 {
            Unmanaged<Win32NavigationContext>.fromOpaque(
                UnsafeMutableRawPointer(bitPattern: Int(userData))!
            ).release()
        }
        return DefWindowProcW(hwnd, uMsg, wParam, lParam)

    default:
        return DefWindowProcW(hwnd, uMsg, wParam, lParam)
    }
}

/// Measure the back button text with the title font (the font applied
/// to the button via WM_SETFONT). Querying the button for its font here
/// would re-enter the control while it processes a message.
private func measureBackButton(ctx: Win32NavigationContext) -> Int32 {
    let hdc = GetDC(ctx.backButton)
    defer { ReleaseDC(ctx.backButton, hdc) }
    var size = SIZE()
    "← Back".withCString(encodedAs: UTF16.self) { wstr in
        let len = Int32(wcslen(wstr))
        let old = ctx.titleFont.flatMap { SelectObject(hdc, $0) }
        win32_GetTextExtentPoint32W(hdc, wstr, len, &size)
        if let old = old { SelectObject(hdc, old) }
    }
    return size.cx
}

/// Layout the navigation container: header bar at top, content area fills the rest.
private func layoutNavContainer(_ ctx: Win32NavigationContext) {
    var rect = RECT()
    GetClientRect(ctx.container, &rect)
    let w = rect.right - rect.left
    let h = rect.bottom - rect.top

    // Header sizes are physical px; scale the 96-DPI defaults by the window DPI.
    // Keep the ratio fractional and round each scaled dimension (125%, 175%).
    let dpiScale = dpiScaleFactor(for: ctx.container)
    let headerHeight = Int32((32 * dpiScale).rounded())
    SetWindowPos(ctx.headerContainer, nil, 0, 0, w, headerHeight, UINT(SWP_NOZORDER))

    // Layout back button (child of headerContainer)
    let backVisible = IsWindowVisible(ctx.backButton) != false
    let backWidth: Int32 = backVisible ? measureBackButton(ctx: ctx) + Int32((16 * dpiScale).rounded()) : 0
    let inset = Int32((4 * dpiScale).rounded())
    if backVisible {
        SetWindowPos(ctx.backButton, nil, inset, inset, backWidth - 2 * inset, headerHeight - 2 * inset, UINT(SWP_NOZORDER))
    }
    // Toolbar items are placed here, with the header's real width: when they
    // are rendered the header is still zero-wide, so trailing items would end
    // up off-screen. The title takes the space between them.
    let toolbar = win32LayoutToolbarItems(in: ctx.headerContainer, leadingStart: backWidth + inset)
    let titleLeft = toolbar.leadingEnd
    let titleRight = toolbar.trailingStart
    SetWindowPos(ctx.titleLabel, nil, titleLeft, 0,
                 max(titleRight - titleLeft, 0), headerHeight, UINT(SWP_NOZORDER))

    // Content area fills the rest
    SetWindowPos(ctx.contentArea, nil, 0, headerHeight, w, h - headerHeight, UINT(SWP_NOZORDER))

    // Resize current visible entry to fill content area
    if let top = ctx.entries.last {
        SetWindowPos(top.hwnd, nil, 0, 0, w, h - headerHeight, UINT(SWP_NOZORDER))
    }
}

// MARK: - WinRenderable extensions

extension NavigationStack: WinRenderable {
    public func winCreateWidget(in context: RenderContext) -> HWND? {
        registerNavClassIfNeeded(hInstance: context.hInstance)
        registerStackClassIfNeeded(hInstance: context.hInstance)

        // The owning view host keeps this stack's pushed entries by render
        // position, so a rebuild of the containing view re-opens them. The key
        // is taken before the content renders, so it doesn't depend on how
        // many stateful children the content has.
        let owner = Win32ViewHost.current
        let memoryKey = owner?.nextChildKey(type: "NavigationStack")

        // Main container
        let container = CreateWindowExW(
            0, navContainerClassName, nil,
            DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN),
            0, 0, 0, 0,
            context.parent, nil, context.hInstance, nil
        )!

        // Header bar (background: button face color). Sizes are physical
        // pixels, so scale the 96-DPI defaults by the window's DPI.
        // Keep the ratio fractional and round each scaled dimension (125%, 175%).
        let dpiScale = dpiScaleFactor(for: container)
        let headerHeight = Int32((32 * dpiScale).rounded())
        let headerContainer = CreateWindowExW(
            0, stackContainerClassName, nil,
            DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN),
            0, 0, 0, headerHeight,
            container, nil, context.hInstance, nil
        )!

        // Back button — child of headerContainer for correct z-order.
        // WM_COMMAND routing: headerContainer uses stackContainerClassName which
        // has no subclass, but WM_COMMAND from buttons goes to the button's
        // direct parent. We use registerCommandHandler + dispatchCommand via root.
        let backControlID = nextControlID()
        let backButton = "← Back".withCString(encodedAs: UTF16.self) { wstr in
            win32_CreateChildWindow(
                win32_WC_BUTTON(), wstr, DWORD(BS_PUSHBUTTON),
                0, 0, Int32((60 * dpiScale).rounded()), Int32((24 * dpiScale).rounded()),
                headerContainer,
                HMENU(bitPattern: UInt(backControlID)),
                context.hInstance
            )
        }!
        ShowWindow(backButton, SW_HIDE)

        // Install a subclass on headerContainer to forward WM_COMMAND to root
        SetWindowSubclass(headerContainer, stackLayoutProc, 1, 0)

        // Title label
        let titleLabel = win32_CreateChildWindow(
            win32_WC_STATIC(), nil, DWORD(SS_CENTER | SS_CENTERIMAGE),
            0, 0, 0, headerHeight,
            headerContainer, nil, context.hInstance
        )!

        // Apply bold font to title (tracked for cleanup in context deinit).
        // -height is physical px; scale the 16px default by the window DPI.
        let titleFont = "Segoe UI".withCString(encodedAs: UTF16.self) { namePtr in
            CreateFontW(Int32((-16 * dpiScale).rounded()), 0, 0, 0, FW_BOLD, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                        DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY),
                        DWORD(DEFAULT_PITCH), namePtr)
        }
        if let f = titleFont {
            SendMessageW(titleLabel, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: f)), 1)
            // The native button's default font is not DPI-scaled; use the
            // same scaled font as the title.
            SendMessageW(backButton, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: f)), 1)
        }

        // Content area
        let contentArea = CreateWindowExW(
            0, stackContainerClassName, nil,
            DWORD(WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN),
            0, 32, 0, 0,
            container, nil, context.hInstance, nil
        )!

        // Create navigation context
        let navCtx = Win32NavigationContext(
            container: container, headerContainer: headerContainer,
            titleLabel: titleLabel, backButton: backButton,
            contentArea: contentArea, hInstance: context.hInstance
        )
        if let pb = pathBinding {
            navCtx.pathBinding = pb
        }

        // Track resources for cleanup
        navCtx.titleFont = titleFont
        navCtx.backControlID = backControlID

        // Store context on container for lifetime + WndProc access
        let retained = Unmanaged.passRetained(navCtx).toOpaque()
        win32_SetWindowLongPtrW(container, GWLP_USERDATA, LONG_PTR(Int(bitPattern: retained)))

        // Register back button command handler
        registerCommandHandler(controlID: backControlID, action: { [weak navCtx] in
            navCtx?.pop()
        })

        // Set context for render pass
        setCurrentNavigationContext(navCtx)
        var env = getCurrentEnvironment()
        env[NavigateKey.self] = NavigateAction(
            push: { [weak navCtx] value in navCtx?.pushValue(value) },
            pop: { [weak navCtx] in navCtx?.pop() },
            popToRoot: { [weak navCtx] in navCtx?.popToRoot() }
        )
        let prevEnv = getCurrentEnvironment()
        setCurrentEnvironment(env)

        let title = win32ExtractTitle(from: content)
        let rootContext = RenderContext(parent: contentArea, hInstance: context.hInstance)
        let rootHwnd = winRenderView(content, in: rootContext)

        setCurrentEnvironment(prevEnv)
        setCurrentNavigationContext(nil)

        // Add root as first entry and size the nav container
        if let rootHwnd = rootHwnd {
            // Get root content's natural size
            var rootRect = RECT()
            GetWindowRect(rootHwnd, &rootRect)
            let rootW = rootRect.right - rootRect.left
            let rootH = rootRect.bottom - rootRect.top

            // Size the nav container = root content + header
            let totalH = rootH + headerHeight
            let totalW = max(rootW, px(200, for: container))
            SetWindowPos(container, nil, 0, 0, totalW, totalH, UINT(SWP_NOZORDER | SWP_NOMOVE))

            // Now layout header + content area inside the sized container
            layoutNavContainer(navCtx)

            // Size root to fill content area
            var caRect = RECT()
            GetClientRect(contentArea, &caRect)
            SetWindowPos(rootHwnd, nil, 0, 0,
                         caRect.right, caRect.bottom, UINT(SWP_NOZORDER))

            navCtx.entries.append(Win32NavigationEntry(
                title: title, hwnd: rootHwnd,
                toolbarWindows: win32ToolbarItemWindows(in: headerContainer)))
            // Propagate the root content's expansion so the stack fills
            // its available space. This is root-only: push() sizes a
            // destination inside the existing content area and does not
            // update these flags, so a pushed view that should expand
            // changes nothing. Marking the container in push() would not be
            // enough either, because the outer window caches expansion.
            propagateExpandFlags(from: rootHwnd, to: container)
        }

        // Set initial title
        let titleText = title.isEmpty ? "Home" : title
        _ = titleText.withCString(encodedAs: UTF16.self) { wstr in
            SetWindowTextW(titleLabel, wstr)
        }

        // Re-open the entries pushed before a rebuild. A path-bound stack has
        // no memory restore (its path is its state).
        if let owner, let memoryKey {
            let memory = owner.navigationMemory[memoryKey] ?? Win32NavigationMemory()
            owner.navigationMemory[memoryKey] = memory
            let remembered = memory.entries
            memory.entries = []
            navCtx.memory = memory
            if pathBinding == nil, !navCtx.entries.isEmpty {
                for restore in remembered {
                    restore(navCtx)
                }
            }
        }

        return container
    }
}

extension NavigationLink: WinRenderable {
    public func winCreateWidget(in context: RenderContext) -> HWND? {
        // Value-based NavigationLink inside List(selection:) — select the value
        // (sidebar behavior) instead of pushing it.
        if let value = pushValue, let listSelection = getCurrentEnvironment().listSelection {
            let action = bindActionToCurrentEnvironment {
                listSelection.select(value)
            }
            if label.isEmpty {
                return createCustomLabelButton(label: labelView, action: action, context: context)
            }
            return createNativeButton(title: label, action: action, context: context)
        }

        guard let navCtx = getCurrentNavigationContext() else {
            // Not inside a NavigationStack — render the label only.
            return winRenderView(labelView, in: context)
        }

        let destTitle = self.title
        let hInst = context.hInstance

        if let value = pushValue {
            // Value-based NavigationLink — resolve via destination registry
            let action = bindActionToCurrentEnvironment { [weak navCtx] in
                guard let navCtx = navCtx else { return }
                if let factory = navCtx.destinationRegistry.resolve(value) {
                    navCtx.push(title: destTitle) { factory() }
                }
            }
            if label.isEmpty {
                return createCustomLabelButton(label: labelView, action: action, context: context)
            }
            return createNativeButton(title: label, action: action, context: context)
        }

        // Destination-based NavigationLink
        let dest = self.destination
        // Pushes the destination onto a context; also how the entry is
        // re-created after a rebuild, so its title is re-read then.
        func pushDestination(on navCtx: Win32NavigationContext) {
            let destView = dest()
            let extracted = win32ExtractTitle(from: destView)
            let title = extracted.isEmpty ? destTitle : extracted
            navCtx.push(title: title, restore: { pushDestination(on: $0) }) { [weak navCtx] in
                guard let navCtx = navCtx else { return nil }
                let destContext = RenderContext(parent: navCtx.contentArea, hInstance: hInst)
                return winRenderView(destView, in: destContext)
            }
        }
        let action = bindActionToCurrentEnvironment { [weak navCtx] in
            guard let navCtx = navCtx else { return }
            pushDestination(on: navCtx)
        }
        if label.isEmpty {
            return createCustomLabelButton(label: labelView, action: action, context: context)
        }
        return createNativeButton(title: label, action: action, context: context)
    }
}

extension NavigationDestinationModifier: WinRenderable {
    public func winCreateWidget(in context: RenderContext) -> HWND? {
        // Register the destination factory on the current context
        if let navCtx = getCurrentNavigationContext() {
            let destinationBuilder = destination
            let hInst = context.hInstance
            navCtx.destinationRegistry.register(for: dataType) { [weak navCtx] value -> HWND? in
                guard let navCtx = navCtx else { return nil }
                let destContext = RenderContext(parent: navCtx.contentArea, hInstance: hInst)
                return winRenderView(destinationBuilder(value), in: destContext)
            }
        }
        return winRenderView(content, in: context)
    }
}

extension TitledView: WinRenderable {
    public func winCreateWidget(in context: RenderContext) -> HWND? {
        winRenderView(content, in: context)
    }
}

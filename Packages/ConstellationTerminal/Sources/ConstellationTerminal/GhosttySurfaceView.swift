import AppKit
import GhosttyKit

// Adapted from Ghostty.app (MIT, © Mitchell Hashimoto and contributors):
// macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift.

@MainActor
protocol GhosttySurfaceViewDelegate: AnyObject {
    func surfaceView(_ view: GhosttySurfaceView, didSetTitle title: String)
    func surfaceView(_ view: GhosttySurfaceView, childExitedWithCode code: Int32, runtime: Duration)
    func surfaceViewDidRequestClose(_ view: GhosttySurfaceView, processAlive: Bool)
    func surfaceViewDidRingBell(_ view: GhosttySurfaceView)
    func surfaceView(_ view: GhosttySurfaceView, rendererHealthy healthy: Bool)
}

/// Hosts one `ghostty_surface_t`. libghostty attaches its own Metal layer to
/// this view and renders into it; the view forwards input and size changes.
@MainActor
public final class GhosttySurfaceView: NSView {
    enum TextRegion {
        case viewport
        case screen
    }

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    weak var delegate: GhosttySurfaceViewDelegate?

    private(set) var cellSize: CGSize = .zero
    private(set) var focused = false
    private var currentCursor: NSCursor = .iBeam

    // Keyboard and IME state; see GhosttySurfaceView+Keyboard.swift.
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var lastPerformKeyEvent: TimeInterval?

    public override var acceptsFirstResponder: Bool { true }

    init(runtime: GhosttyRuntime, command: TerminalCommand) throws {
        // Non-zero so the renderer has bounds to start with.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        guard let app = runtime.app else { throw TerminalError.appCreationFailed }
        let created = try command.withSurfaceConfig(view: self, scale: backingScale) { config in
            var config = config
            return ghostty_surface_new(app, &config)
        }
        guard let created else { throw TerminalError.surfaceCreationFailed }
        surface = created
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    /// Frees the surface now rather than at deinit so the child process is
    /// torn down while the caller can still observe it.
    func destroySurface() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    // MARK: Lookup from C callbacks

    static func from(userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func from(target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return nil }
        return from(userdata: ghostty_surface_userdata(surface))
    }

    // MARK: Commands

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(strlen(pointer)))
        }
    }

    @discardableResult
    func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(strlen(pointer)))
        }
    }

    // MARK: Accessibility

    // VoiceOver reads the viewport as a text area; libghostty draws into its
    // own layer, so without this the terminal is silent.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    public override func accessibilityLabel() -> String? { "Terminal" }
    public override func accessibilityValue() -> Any? { readText(.viewport) }
    public override func accessibilitySelectedText() -> String? { selectionText() }
    public override func accessibilitySelectedTextRange() -> NSRange { selectionRange() }

    func readText(_ region: TextRegion) -> String {
        guard let surface else { return "" }
        let tag = region == .viewport ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        return String(cString: pointer)
    }

    func selectionText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        return String(cString: pointer)
    }

    func selectionRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func foregroundProcessID() -> pid_t? {
        guard let surface else { return nil }
        // libghostty reports 0 or an out-of-range value once the process is gone.
        guard let pid = pid_t(exactly: ghostty_surface_foreground_pid(surface)), pid > 0 else { return nil }
        return pid
    }

    // MARK: Size and scale

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSurfaceSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        pushContentScale()
        pushSurfaceSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        pushContentScale()
        pushSurfaceSize()
    }

    private func pushContentScale() {
        guard let surface else { return }
        let scale = backingScale
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func pushSurfaceSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(max(pixels.width, 0)), UInt32(max(pixels.height, 0)))
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ focused: Bool) {
        guard self.focused != focused, let surface else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentCursor)
    }

    public override func mouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    public override func mouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseDown(with: event)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) {
            super.rightMouseUp(with: event)
        }
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_PRESS, mouseButton(for: event.buttonNumber), event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, mouseButton(for: event.buttonNumber), event)
    }

    @discardableResult
    private func sendMouseButton(
        _ state: ghostty_input_mouse_state_e,
        _ button: ghostty_input_mouse_button_e,
        _ event: NSEvent
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, GhosttyMods.from(event.modifierFlags))
    }

    private func mouseButton(for number: Int) -> ghostty_input_mouse_button_e {
        switch number {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: ghostty_input_mouse_button_e(UInt32(min(number + 1, 11)))
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func mouseExited(with event: NSEvent) {
        // Dragging keeps delivering mouseDragged after leaving the view.
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyMods.from(event.modifierFlags))
    }

    public override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // libghostty's origin is top-left.
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, GhosttyMods.from(event.modifierFlags))
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        ghostty_surface_mouse_scroll(surface, x, y, GhosttyScrollMods.encode(precise: precise, phase: event.momentumPhase))
    }

    // MARK: Actions from libghostty

    func handle(action: ghostty_action_s) -> Bool {
        Log.terminal.debug("surface action tag=\(action.tag.rawValue, privacy: .public)")
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let pointer = action.action.set_title.title else { return false }
            delegate?.surfaceView(self, didSetTitle: String(cString: pointer))
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let info = action.action.child_exited
            delegate?.surfaceView(
                self,
                childExitedWithCode: Int32(truncatingIfNeeded: info.exit_code),
                runtime: .milliseconds(info.timetime_ms))
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            cellSize = CGSize(width: Double(size.width), height: Double(size.height))
            return true

        case GHOSTTY_ACTION_RING_BELL:
            delegate?.surfaceViewDidRingBell(self)
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            currentCursor = Self.cursor(for: action.action.mouse_shape)
            window?.invalidateCursorRects(for: self)
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            if action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            delegate?.surfaceView(self, rendererHealthy: action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            return openURL(action.action.open_url)

        default:
            return false
        }
    }

    private func openURL(_ request: ghostty_action_open_url_s) -> Bool {
        guard let pointer = request.url else { return false }
        let data = Data(bytes: pointer, count: Int(request.len))
        guard let string = String(data: data, encoding: .utf8),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE: .resizeUpDown
        default: .arrow
        }
    }

    // MARK: Clipboard callbacks

    func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, location == GHOSTTY_CLIPBOARD_STANDARD,
              let string = NSPasteboard.general.string(forType: .string) else { return false }
        string.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
        return true
    }

    func confirmReadClipboard(
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let surface, let string else { return }
        let contents = String(cString: string)
        // Only pastes the user initiated may proceed. OSC 52 reads stay denied.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else {
            ghostty_surface_complete_clipboard_request(surface, "", state, true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Paste text with newlines?"
        alert.informativeText = "This program does not use bracketed paste, so each line will run as if you typed it and pressed Return."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        let approved = alert.runModal() == .alertFirstButtonReturn
        (approved ? contents : "").withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
        }
    }

    func writeClipboard(
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content, count > 0 else { return }
        var text: String?
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            text = String(cString: data)
            break
        }
        guard let text else { return }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Allow the terminal to write to the clipboard?"
            alert.informativeText = "A program in this session is trying to replace your clipboard contents."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func closeRequested(processAlive: Bool) {
        delegate?.surfaceViewDidRequestClose(self, processAlive: processAlive)
    }

    // MARK: Responder actions (Edit menu)

    @IBAction func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        performBinding("paste_from_clipboard")
    }

    @IBAction public override func selectAll(_ sender: Any?) {
        performBinding("select_all")
    }
}

extension TerminalCommand {
    /// Builds a surface config with C strings that live only for `body`.
    @MainActor
    func withSurfaceConfig<T>(
        view: NSView,
        scale: CGFloat,
        _ body: (ghostty_surface_config_s) throws -> T
    ) rethrows -> T {
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.scale_factor = Double(scale)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // Keep the surface alive after exit so the session can show the result.
        config.wait_after_command = true

        let commandLine = strdup(shellCommandLine)
        defer { free(commandLine) }
        config.command = UnsafePointer(commandLine)

        let workingDirectory = self.workingDirectory.map { strdup($0) }
        defer { free(workingDirectory ?? nil) }
        config.working_directory = UnsafePointer(workingDirectory ?? nil)

        let pairs = environment.sorted { $0.key < $1.key }
        let envVars = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: max(pairs.count, 1))
        defer { envVars.deallocate() }
        for (index, pair) in pairs.enumerated() {
            envVars[index] = ghostty_env_var_s(key: UnsafePointer(strdup(pair.key)), value: UnsafePointer(strdup(pair.value)))
        }
        defer {
            for index in 0..<pairs.count {
                free(UnsafeMutablePointer(mutating: envVars[index].key))
                free(UnsafeMutablePointer(mutating: envVars[index].value))
            }
        }
        config.env_vars = pairs.isEmpty ? nil : envVars
        config.env_var_count = pairs.count

        return try body(config)
    }
}

extension GhosttySurfaceView {
    public struct GridSize: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
    }

    /// Current terminal grid as libghostty computed it from the view size.
    public var gridSize: GridSize {
        guard let surface else { return GridSize(columns: 0, rows: 0) }
        let size = ghostty_surface_size(surface)
        return GridSize(columns: Int(size.columns), rows: Int(size.rows))
    }
}

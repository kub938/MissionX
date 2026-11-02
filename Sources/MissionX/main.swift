import AppKit
import ApplicationServices
import QuartzCore
import ImageIO

// No private symbols, screen capture, network, synthetic keystrokes or quit fallback.
// The mc/appexpose AX identifiers are undocumented: fail closed when they change.
func ax(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func text(_ element: AXUIElement, _ name: String) -> String {
    ax(element, name) as? String ?? ""
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func elements(_ value: CFTypeRef?) -> [AXUIElement] {
    guard let values = value as? [AnyObject] else { return [] }
    return values.compactMap { element($0) }
}
func children(_ node: AXUIElement) -> [AXUIElement] {
    elements(ax(node, kAXChildrenAttribute))
}
func frame(_ node: AXUIElement) -> CGRect? {
    guard let p = ax(node, kAXPositionAttribute), let s = ax(node, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    let position = unsafeBitCast(p, to: AXValue.self)
    let size = unsafeBitCast(s, to: AXValue.self)
    guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent),
          origin.x.isFinite, origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
          extent.width > 0, extent.height > 0 else { return nil }
    return CGRect(origin: origin, size: extent)
}
func canPress(_ button: AXUIElement) -> Bool {
    guard (ax(button, kAXEnabledAttribute) as? Bool) != false else { return false }
    var names: CFArray?
    return AXUIElementCopyActionNames(button, &names) == .success &&
        (names as? [String] ?? []).contains(kAXPressAction)
}
func overviewID(_ id: String) -> Bool {
    ["mc", "mc.display", "appexpose", "appexpose.display"].contains(id)
}
// AX and CGEvent use a top-left origin on the primary display. Do not use the
// tallest display or NSScreen.main (which can change with keyboard focus).
func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
}
let closeButtonDiameter: CGFloat = 22
func closeRect(_ thumbnail: CGRect) -> CGRect {
    CGRect(x: thumbnail.minX - closeButtonDiameter / 2, y: thumbnail.minY - closeButtonDiameter / 2,
           width: closeButtonDiameter, height: closeButtonDiameter)
}
struct Thumbnail: Equatable {
    let title: String
    let rect: CGRect
    let ownerBundleID: String?
}
struct WindowKey: Hashable {
    let title: String
    let owner: String?
    init(_ thumbnail: Thumbnail) { title = thumbnail.title; owner = thumbnail.ownerBundleID }
}
func hoveredThumbnail(_ thumbnails: [Thumbnail], at point: CGPoint, current: Thumbnail?) -> Thumbnail? {
    // The control straddles the border, so its outer half must remain hoverable.
    if let current, let refreshed = thumbnails.first(where: { WindowKey($0) == WindowKey(current) }),
       closeRect(refreshed.rect).contains(point) { return refreshed }
    return thumbnails.filter { $0.rect.contains(point) }
        .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
}
func sameLayout(_ lhs: [Thumbnail], _ rhs: [Thumbnail]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    func sorted(_ values: [Thumbnail]) -> [CGRect] {
        values.map { $0.rect }.sorted { $0.minX == $1.minX ? $0.minY < $1.minY : $0.minX < $1.minX }
    }
    return zip(sorted(lhs), sorted(rhs)).allSatisfy { a, b in
        abs(a.minX - b.minX) <= 1.5 && abs(a.minY - b.minY) <= 1.5 &&
        abs(a.width - b.width) <= 1.5 && abs(a.height - b.height) <= 1.5
    }
}
struct Snapshot {
    var thumbnails: [Thumbnail] = []
    var markers = 0
    var truncated = false
    var lines: [String] = []
}

// Context is shared by live AX traversal and offline diagnostic replay.
struct TreeContext {
    var parentID = ""
    var overview = false
    var windows = false
    var spaces = false
    func descending(from id: String) -> TreeContext {
        let overview = self.overview || overviewID(id)
        return TreeContext(parentID: id, overview: overview,
            windows: windows || (overview && ["mc.windows", "appexpose.windows"].contains(id)),
            spaces: spaces || id == "mc.spaces" || id.hasPrefix("mc.spaces.") ||
                id == "appexpose.spaces" || id.hasPrefix("appexpose.spaces."))
    }
}
func ownerBundleID(_ identifier: String) -> String? {
    guard let separator = identifier.range(of: ".space.", options: .backwards) else { return nil }
    let bundle = String(identifier[..<separator.lowerBound])
    let space = String(identifier[separator.upperBound...])
    guard bundle.contains("."), !space.isEmpty, space.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    return bundle
}
func thumbnailLocation(_ id: String, context: TreeContext) -> Bool {
    guard context.overview, !context.spaces else { return false }
    // macOS 27.0.1: app buttons are DIRECT children of mc.display. There is no
    // mc.windows wrapper. Require the observed app-bundle.space.N identifier;
    // do not admit arbitrary descendants or buttons from the Spaces bar.
    return context.windows ||
        (["mc.display", "appexpose.display"].contains(context.parentID) && ownerBundleID(id) != nil)
}
func makeThumbnail(id: String, role: String, title: String, rect: CGRect?, context: TreeContext) -> Thumbnail? {
    guard thumbnailLocation(id, context: context), role == kAXButtonRole,
          !title.isEmpty, let rect, rect.width >= 40, rect.height >= 32 else { return nil }
    return Thumbnail(title: title, rect: rect, ownerBundleID: ownerBundleID(id))
}

final class OverviewReader {
    // Bounded traversal and per-process AX timeouts keep unavailable apps from
    // blocking indefinitely. An incomplete traversal never authorizes closing.
    func read(dump: Bool = false) -> Snapshot {
        var result = Snapshot()
        let apps = NSWorkspace.shared.runningApplications.filter {
            ["com.apple.dock", "com.apple.WindowManager"].contains($0.bundleIdentifier ?? "")
        }.sorted { ($0.bundleIdentifier == "com.apple.WindowManager" ? 0 : 1) <
                    ($1.bundleIdentifier == "com.apple.WindowManager" ? 0 : 1) }
        for app in apps {
            if !dump, !result.thumbnails.isEmpty { break } // avoid rescanning Dock icons on macOS 27
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            if dump { result.lines.append("PROCESS \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)") }
            var queue: [(AXUIElement, Int, TreeContext)] = [(root, 0, TreeContext())]
            var seen = Set<AXUIElement>()
            let deadline = Date().addingTimeInterval(0.4)
            var index = 0
            while index < queue.count {
                if index >= 2500 || Date() > deadline { result.truncated = true; break }
                let (node, depth, context) = queue[index]
                index += 1
                if !seen.insert(node).inserted { continue }
                let id = text(node, kAXIdentifierAttribute)
                let role = text(node, kAXRoleAttribute)
                let title = text(node, kAXTitleAttribute)
                if !dump, role == "AXDockItem" || id == "mc.spaces" || id == "appexpose.spaces" { continue }
                let kids = children(node)
                let nextContext = context.descending(from: id)
                if overviewID(id), !kids.isEmpty { result.markers += 1 }
                let rect = (dump || thumbnailLocation(id, context: context)) ? frame(node) : nil
                if dump {
                    result.lines.append("\(String(repeating: " ", count: depth))\(role) id=\(id) title=\(title.debugDescription) frame=\(rect.map { String(describing: $0) } ?? "nil")")
                }
                if let thumbnail = makeThumbnail(id: id, role: role, title: title, rect: rect, context: context),
                   !result.thumbnails.contains(thumbnail) {
                    result.thumbnails.append(thumbnail)
                }
                if depth < 20 {
                    queue += kids.map { ($0, depth + 1, nextContext) }
                    if depth == 0 {
                        queue += elements(ax(node, kAXWindowsAttribute)).map { ($0, 1, nextContext) }
                    }
                } else if !kids.isEmpty { result.truncated = true }
            }
        }
        return result
    }
}
struct WindowRef {
    let pid: pid_t
    let window: AXUIElement
}
// Chrome exposes an AX window title with a product suffix while Mission Control
// uses the document/tab title. Only strip known, terminal Chrome suffixes and
// only for Chrome's verified bundle ID. Never use substring/fuzzy matching.
func normalizedWindowTitle(_ title: String, owner: String?) -> String {
    var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if owner == "com.google.Chrome" {
        for suffix in [" - Google Chrome", " - Chrome"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
            break
        }
    }
    return value
}
func uniqueIndex(_ title: String, in titles: [String], owner: String? = nil) -> Int? {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !title.contains("…"), !title.contains("...") else { return nil }
    let normalized = normalizedWindowTitle(title, owner: owner)
    guard !normalized.isEmpty else { return nil }
    let matches = titles.indices.filter { normalizedWindowTitle(titles[$0], owner: owner) == normalized }
    return matches.count == 1 ? matches[0] : nil
}
struct WindowRecord {
    let ref: WindowRef
    let title: String
    let closable: Bool
}
struct Inventory {
    var records: [WindowRecord] = []
    var error: String? = nil
    var notes: [String] = []
}
// Finder's AXWindows can include the desktop and other special surfaces. They
// are not folder windows and must not make a valid folder inventory fail.
func inspectWindow(owner: String?, role: String, subrole: String) -> Bool {
    owner != "com.apple.finder" || (role == kAXWindowRole && subrole == kAXStandardWindowSubrole)
}
struct Resolution {
    var target: WindowRef? = nil
    var reason: String
}
// Worker-queue only. One inventory per owner, shared by every thumbnail from
// that app. Failed reads get a short TTL so enabling AX/app responsiveness recovers.
final class WindowResolver {
    struct Entry { let time: TimeInterval; let value: Inventory }
    var cache: [String: Entry] = [:]
    var loads = 0
    func clear() { cache.removeAll() }
    func inventory(owner: String?, now: TimeInterval, force: Bool = false,
                   loader: (() -> Inventory)? = nil) -> Inventory {
        let key = owner ?? "<legacy-all-apps>"
        if !force, let entry = cache[key], now - entry.time < (entry.value.error == nil ? 0.75 : 0.2) {
            return entry.value
        }
        loads += 1
        let value = loader?() ?? load(owner: owner)
        cache[key] = Entry(time: now, value: value)
        return value
    }
    func load(owner: String?) -> Inventory {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && (owner == nil || $0.bundleIdentifier == owner) &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard !apps.isEmpty else { return Inventory(error: "소유 앱을 찾지 못함") }
        var result = Inventory()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
            guard error == .success else {
                return Inventory(error: "AXWindows 오류 \(error.rawValue) (\(app.bundleIdentifier ?? "?"))")
            }
            for window in elements(value) {
                if ProcessInfo.processInfo.systemUptime > deadline { return Inventory(error: "창 목록 조회 시간 초과") }
                if owner == "com.apple.finder" {
                    let role = text(window, kAXRoleAttribute)
                    let subrole = text(window, kAXSubroleAttribute)
                    guard inspectWindow(owner: owner, role: role, subrole: subrole) else {
                        // A failed role query is not evidence of a known desktop.
                        guard !role.isEmpty, role != kAXWindowRole || !subrole.isEmpty else {
                            return Inventory(error: "Finder 창 종류 조회 실패", notes: result.notes)
                        }
                        result.notes.append("SKIP Finder role=\(role) subrole=\(subrole)")
                        continue
                    }
                    result.notes.append("READ Finder standard folder window")
                }
                var rawTitle: CFTypeRef?
                let titleError = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &rawTitle)
                guard titleError == .success, let title = rawTitle as? String else {
                    return Inventory(error: "AXTitle 오류 \(titleError.rawValue)", notes: result.notes)
                }
                let close = element(ax(window, kAXCloseButtonAttribute))
                let closable = close.map { canPress($0) } ?? false
                result.records.append(WindowRecord(ref: WindowRef(pid: app.processIdentifier, window: window),
                                                   title: title, closable: closable))
            }
        }
        return result
    }
    func resolve(_ thumbnail: Thumbnail, inventory: Inventory) -> Resolution {
        if let error = inventory.error { return Resolution(reason: error) }
        guard !thumbnail.title.contains("…"), !thumbnail.title.contains("...") else {
            return Resolution(reason: "축약 제목은 식별하지 않음")
        }
        guard let index = uniqueIndex(thumbnail.title, in: inventory.records.map { $0.title }, owner: thumbnail.ownerBundleID) else {
            return Resolution(reason: "제목 불일치 또는 같은 앱의 중복 제목")
        }
        let record = inventory.records[index]
        guard record.closable else { return Resolution(reason: "AX 닫기 버튼/AXPress 사용 불가") }
        return Resolution(target: record.ref, reason: "ready")
    }
    func resolve(_ thumbnail: Thumbnail, force: Bool = false) -> Resolution {
        resolve(thumbnail, inventory: inventory(owner: thumbnail.ownerBundleID,
            now: ProcessInfo.processInfo.systemUptime, force: force))
    }
    func batch(_ thumbnails: [Thumbnail], preferredOwner: String? = nil,
               onReady: (([WindowKey: Resolution]) -> Void)? = nil) -> [WindowKey: Resolution] {
        var result: [WindowKey: Resolution] = [:]
        let groups = Dictionary(grouping: thumbnails) { $0.ownerBundleID ?? "<legacy-all-apps>" }
        let keys = groups.keys.sorted {
            if ($0 == preferredOwner) != ($1 == preferredOwner) { return $0 == preferredOwner }
            return $0 < $1
        }
        // Publish one owner at a time: a slow app must not hold ready buttons back.
        for owner in keys {
            var chunk: [WindowKey: Resolution] = [:]
            for thumbnail in groups[owner]! where chunk[WindowKey(thumbnail)] == nil {
                chunk[WindowKey(thumbnail)] = resolve(thumbnail)
            }
            result.merge(chunk) { _, fresh in fresh }
            onReady?(chunk)
        }
        return result
    }

}

protocol OverlaySurface: AnyObject {
    func hideSurface()
    func placeSurface(_ frame: CGRect)
    func showSurface()
}
// Shared with the regression spy: position changes always happen while hidden.
func presentOverlayImmediately(_ surface: OverlaySurface, frame: CGRect) {
    surface.hideSurface()
    surface.placeSurface(frame)
    surface.showSurface()
}
func withoutOverlayAnimation(_ action: () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        action()
        CATransaction.commit()
    }
}

// Vector drawing in points, shared with the windowless visual preview. The
// small red traffic-light style uses a dark fine cross instead of a text glyph.
func drawMacCloseButton(in context: CGContext, bounds: CGRect) {
    context.saveGState()
    let scale = min(bounds.width, bounds.height) / 14
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.setFillColor(red: 1, green: 95.0 / 255, blue: 87.0 / 255, alpha: 1)
    context.setStrokeColor(red: 224.0 / 255, green: 68.0 / 255, blue: 62.0 / 255, alpha: 1)
    context.setLineWidth(0.6 * scale)
    context.addEllipse(in: bounds.insetBy(dx: 0.5 * scale, dy: 0.5 * scale))
    context.drawPath(using: .fillStroke)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let radius: CGFloat = 2.3 * scale
    context.setStrokeColor(red: 91.0 / 255, green: 17.0 / 255, blue: 15.0 / 255, alpha: 1)
    context.setLineWidth(scale)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: center.x - radius, y: center.y - radius))
    context.addLine(to: CGPoint(x: center.x + radius, y: center.y + radius))
    context.move(to: CGPoint(x: center.x - radius, y: center.y + radius))
    context.addLine(to: CGPoint(x: center.x + radius, y: center.y - radius))
    context.strokePath()
    context.restoreGState()
}
final class MacCloseView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        drawMacCloseButton(in: context, bounds: bounds)
    }
}

final class ClosePanel: NSPanel, OverlaySurface {
    init(axRect: CGRect, primaryTop: CGFloat) {
        super.init(contentRect: appKitRect(axRect, primaryTop: primaryTop),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        // MC can intercept normal NSButton events. A narrowly-scoped event tap
        // owns clicks; the visual panel deliberately passes everything through.
        ignoresMouseEvents = true
        let button = MacCloseView(frame: CGRect(x: 0, y: 0, width: closeButtonDiameter, height: closeButtonDiameter))
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("창 닫기")
        contentView = button
    }
    func hideSurface() { withoutOverlayAnimation { orderOut(nil) } }
    func placeSurface(_ frame: CGRect) {
        assert(!isVisible, "Never reposition a visible close overlay")
        withoutOverlayAnimation { setFrame(frame, display: false, animate: false) }
    }
    func showSurface() { withoutOverlayAnimation { orderFrontRegardless() } }
}

final class MissionX: NSObject, NSApplicationDelegate {
    let reader = OverviewReader()
    var status: NSStatusItem!
    var message: NSMenuItem!
    var enabled = true
    var permissionGranted = false
    var timer: Timer?
    var hoverTimer: Timer?
    let resolver = WindowResolver()
    var latest = Snapshot()
    var latestTime = Date.distantPast
    var resolutions: [WindowKey: Resolution] = [:]
    var resolutionBusy = false
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var panel: ClosePanel?
    var panels: [WindowKey: ClosePanel] = [:]
    var hovered: Thumbnail?
    var target: WindowRef?
    var previous: [Thumbnail] = []
    var stableSince = Date()
    var stableSamples = 0
    var swallowedDown = false
    let worker = DispatchQueue(label: "local.missionx.accessibility", qos: .userInitiated)
    let scanWorker = DispatchQueue(label: "local.missionx.overview", qos: .userInitiated)
    var scanInProgress = false
    var generation = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "⊠"
        status.button?.toolTip = "MissionX 0.6.1"
        let menu = NSMenu()
        message = NSMenuItem(title: "MissionX 0.6.1 준비 중", action: nil, keyEquivalent: "")
        menu.addItem(message)
        for (title, action) in [("일시정지 / 재개", #selector(toggle)),
                                ("손쉬운 사용 권한 요청", #selector(permission)),
                                ("5초 후 진단 저장…", #selector(saveDiagnostics)),
                                ("종료", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        status.menu = menu
        permission()
        let poll = Timer(timeInterval: 0.15, target: self, selector: #selector(scan), userInfo: nil, repeats: true)
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        let hoverPoll = Timer(timeInterval: 1.0 / 30, target: self,
                              selector: #selector(updateHover), userInfo: nil, repeats: true)
        RunLoop.main.add(hoverPoll, forMode: .common)
        hoverTimer = hoverPoll
    }
    @objc func permission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    @objc func toggle() {
        enabled.toggle(); generation += 1; clearOverlays(); previous = []; latest = Snapshot(); resolutions = [:]
        stableSince = Date()
        worker.async { self.resolver.clear() }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func hide() {
        if panel?.isVisible == true { panel?.hideSurface() }
        hovered = nil
        target = nil
    }
    func clearOverlays() {
        hide()
        for cached in panels.values { cached.hideSurface(); cached.close() }
        panels.removeAll()
        panel = nil
    }
    func retainPanels(for keys: Set<WindowKey>) {
        for (key, cached) in panels where !keys.contains(key) {
            cached.hideSurface()
            cached.close()
            if panel === cached { panel = nil; hovered = nil; target = nil }
            panels.removeValue(forKey: key)
        }
    }
    func installTap() -> Bool {
        if let tap { return CGEvent.tapIsEnabled(tap: tap) }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
                   (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MissionX>.fromOpaque(info).takeUnretainedValue()
            return owner.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hide()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, swallowedDown {
            swallowedDown = false
            return nil
        }
        guard type == .leftMouseDown, enabled, let thumbnail = hovered,
              let expected = target, closeRect(thumbnail.rect).contains(event.location) else {
            return Unmanaged.passUnretained(event)
        }
        swallowedDown = true
        generation += 1
        hide()
        // AX work is outside the event callback to avoid event tap timeouts.
        let clickGeneration = generation
        worker.async { [weak self] in
            guard let self, AXIsProcessTrusted() else { return }
            let snapshot = self.reader.read()
            guard !snapshot.truncated, snapshot.thumbnails.contains(thumbnail),
                  let fresh = self.resolver.resolve(thumbnail, force: true).target, fresh.pid == expected.pid,
                  CFEqual(fresh.window, expected.window),
                  let close = element(ax(fresh.window, kAXCloseButtonAttribute)), canPress(close) else {
                DispatchQueue.main.async { self.message.title = "창이 변경되어 닫기를 취소했습니다" }
                return
            }
            // Honor a pause/quit that happened while AX queries were in flight.
            let authorized = DispatchQueue.main.sync { self.enabled && self.generation == clickGeneration }
            guard authorized else { return }
            let result = AXUIElementPerformAction(close, kAXPressAction as CFString)
            self.resolver.clear()
            DispatchQueue.main.async {
                self.message.title = "닫기 요청 결과: \(result.rawValue) (0=전달 성공)"
                self.resolutions = [:]
                self.latest = Snapshot()
                self.previous = []
                self.stableSince = Date()
            }
        }
        return nil
    }
    @objc func scan() {
        guard enabled else { hide(); message.title = "MissionX 일시정지"; return }
        permissionGranted = AXIsProcessTrusted()
        guard permissionGranted else { hide(); message.title = "손쉬운 사용 권한이 필요합니다"; return }
        guard !scanInProgress else { return }
        scanInProgress = true
        let scanGeneration = generation
        scanWorker.async { [weak self] in
            guard let self else { return }
            let snapshot = self.reader.read()
            DispatchQueue.main.async {
                self.scanInProgress = false
                guard self.enabled, self.generation == scanGeneration, AXIsProcessTrusted() else { self.hide(); return }
                self.apply(snapshot)
            }
        }
    }
    func apply(_ snapshot: Snapshot) {
        if (snapshot.truncated || snapshot.thumbnails.isEmpty), !latest.thumbnails.isEmpty {
            generation += 1
            clearOverlays()
        }
        latest = snapshot
        latestTime = Date()
        if !sameLayout(snapshot.thumbnails, previous) { stableSince = Date(); stableSamples = 1; hide() }
        else { stableSamples = min(2, stableSamples + 1) }
        previous = snapshot.thumbnails
        let visibleKeys = Set(snapshot.thumbnails.map { WindowKey($0) })
        resolutions = resolutions.filter { visibleKeys.contains($0.key) }
        retainPanels(for: visibleKeys)
        if snapshot.truncated || snapshot.thumbnails.isEmpty {
            resolutions = [:]
            worker.async { self.resolver.clear() }
        } else if !resolutionBusy {
            // Prewarm every thumbnail, independently of pointer movement. AX work
            // never sits on the cursor-to-overlay path once this cache is warm.
            resolutionBusy = true
            let resolveGeneration = generation
            let point = CGEvent(source: nil)?.location
            let preferred = point.flatMap { hoveredThumbnail(snapshot.thumbnails, at: $0, current: hovered) }?.ownerBundleID
            worker.async {
                _ = self.resolver.batch(snapshot.thumbnails, preferredOwner: preferred) { chunk in
                    DispatchQueue.main.async {
                        guard self.generation == resolveGeneration else { return }
                        let keys = Set(self.latest.thumbnails.map { WindowKey($0) })
                        for (key, match) in chunk where keys.contains(key) { self.resolutions[key] = match }
                        self.updateHover()
                    }
                }
                DispatchQueue.main.async { self.resolutionBusy = false }
            }
        }
        updateHover()
    }
    @objc func updateHover() {
        guard enabled, permissionGranted, Date().timeIntervalSince(latestTime) < 0.6 else { hide(); return }
        guard !latest.truncated else { hide(); message.title = "접근성 응답 지연 / 트리 탐색 불완전"; return }
        guard !latest.thumbnails.isEmpty else {
            hide()
            message.title = latest.markers > 0 ? "개요 감지됨 · 지원되는 썸네일 없음" : "Mission Control 대기 중"
            return
        }
        guard stableSamples >= 2, Date().timeIntervalSince(stableSince) >= 0.12 else { hide(); return }
        guard let point = CGEvent(source: nil)?.location,
              let thumbnail = hoveredThumbnail(latest.thumbnails, at: point, current: hovered) else {
            hide(); message.title = "개요 감지됨 · 창 위에 커서를 올리세요"; return
        }
        guard let match = resolutions[WindowKey(thumbnail)], let resolved = match.target else {
            hide(); message.title = resolutions[WindowKey(thumbnail)]?.reason ?? "창 정보를 준비 중입니다"; return
        }
        if panel?.isVisible != true, !installTap() {
            hide(); message.title = "마우스 클릭 감지 불가 · 권한 확인 필요"; return
        }
        if thumbnail != hovered || panel?.isVisible != true {
            guard let primary = NSScreen.screens.first else { return }
            // Each thumbnail has its own surface. A different window never
            // inherits a visible panel that Mission Control could animate across.
            hide()
            let key = WindowKey(thumbnail)
            let next = panels[key] ?? ClosePanel(axRect: closeRect(thumbnail.rect), primaryTop: primary.frame.maxY)
            presentOverlayImmediately(next, frame: appKitRect(closeRect(thumbnail.rect), primaryTop: primary.frame.maxY))
            panels[key] = next
            panel = next
        }
        hovered = thumbnail
        target = resolved
        message.title = "닫기 버튼 준비됨"
    }
    @objc func saveDiagnostics() {
        message.title = "5초 안에 Mission Control을 여세요"
        worker.asyncAfter(deadline: .now() + 5) { [weak self] in
            let report = diagnostics(dump: true)
            DispatchQueue.main.async {
                guard let self else { return }
                let picker = NSSavePanel()
                picker.nameFieldStringValue = "MissionX-diagnostics.txt"
                picker.message = "창 제목과 접근성 구조가 포함됩니다. 공유 전에 내용을 확인하세요."
                NSApp.activate(ignoringOtherApps: true)
                if picker.runModal() == .OK, let url = picker.url {
                    do { try report.write(to: url, atomically: true, encoding: .utf8) }
                    catch { self.message.title = "진단 저장 실패: \(error.localizedDescription)" }
                }
            }
        }
    }
}
func diagnostics(dump: Bool) -> String {
    var lines = ["MissionX 0.6.1", ProcessInfo.processInfo.operatingSystemVersionString,
                 "AX trusted: \(AXIsProcessTrusted())"]
    guard AXIsProcessTrusted() else {
        return (lines + ["No AX reads attempted. Enable Accessibility for this exact app, then retry."]).joined(separator: "\n")
    }
    let scanStart = ProcessInfo.processInfo.systemUptime
    let snapshot = OverviewReader().read(dump: dump)
    lines.append("AX tree scan ms: \(Int((ProcessInfo.processInfo.systemUptime - scanStart) * 1000))")
    lines += ["Nonempty overview markers: \(snapshot.markers)",
              "Thumbnails: \(snapshot.thumbnails.count)",
              "Thumbnails with owner: \(snapshot.thumbnails.filter { $0.ownerBundleID != nil }.count)", "Incomplete: \(snapshot.truncated)"]
    if dump {
        let resolver = WindowResolver()
        for thumbnail in snapshot.thumbnails {
            let match = resolver.resolve(thumbnail)
            lines.append("MATCH owner=\(thumbnail.ownerBundleID ?? "unknown") title=\(thumbnail.title.debugDescription) result=\(match.reason)")
        }
        for (owner, entry) in resolver.cache.sorted(by: { $0.key < $1.key }) {
            lines.append("APP owner=\(owner) error=\(entry.value.error ?? "none")")
            lines += entry.value.notes.map { " NOTE \($0)" }
            for record in entry.value.records {
                lines.append(" WINDOW AXTitle=\(record.title.debugDescription) closePress=\(record.closable)")
            }
        }
    }
    return (lines + snapshot.lines).joined(separator: "\n")
}
func replayDiagnostic(_ report: String) -> [Thumbnail] {
    let pattern = #"^( *)(AX\w+) id=(.*?) title=(\"(?:[^\"\\]|\\.)*\") frame=(.*)$"#
    let expression = try! NSRegularExpression(pattern: pattern)
    var ancestors: [String] = []
    var found: [Thumbnail] = []
    for line in report.components(separatedBy: .newlines) {
        if line.hasPrefix("PROCESS ") { ancestors = []; continue }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { continue }
        func group(_ index: Int) -> String {
            String(line[Range(match.range(at: index), in: line)!])
        }
        let depth = group(1).count
        guard depth <= ancestors.count else { continue }
        ancestors = Array(ancestors.prefix(depth))
        let context = ancestors.reduce(TreeContext()) { $0.descending(from: $1) }
        let id = group(3)
        // Diagnostic titles use Swift debugDescription escaping. Count/classify
        // without evaluating the string or needing access to the user's windows.
        let quoted = group(4)
        let title = String(quoted.dropFirst().dropLast())
        let numbers = group(5).split { !("0123456789.-+eE".contains($0)) }.compactMap { Double($0) }
        let rect: CGRect? = numbers.count == 4 ?
            CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : nil
        if let thumbnail = makeThumbnail(id: id, role: group(2), title: title, rect: rect, context: context) {
            found.append(thumbnail)
        }
        ancestors.append(id)
    }
    return found
}

func selfTest() {
    var passed = 0
    func check(_ ok: Bool, _ label: String) {
        guard ok else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        passed += 1
    }
    check(overviewID("mc"), "Dock marker")
    check(overviewID("mc.display"), "WindowManager marker")
    check(overviewID("appexpose.display"), "App Expose marker")
    check(!overviewID("Mission Control") && !overviewID("mc.spaces"), "reject labels and spaces")
    check(uniqueIndex("Report", in: ["Report", "Other"]) == 0, "unique exact match")
    check(uniqueIndex("Report", in: ["Report", "Report"]) == nil, "duplicate titles rejected")
    check(uniqueIndex("", in: [""]) == nil, "empty titles rejected")
    check(uniqueIndex("Rep…", in: ["Report"]) == nil, "truncation not guessed")
    check(uniqueIndex("Rep…", in: ["Rep…"]) == nil, "ellipsis rejected even with exact live title")
    check(uniqueIndex("Rep...", in: ["Rep..."]) == nil, "ASCII ellipsis rejected")
    check(uniqueIndex("Missing", in: ["Report"]) == nil, "missing match rejected")
    let rect = CGRect(x: -1200, y: -500, width: 400, height: 200)
    check(appKitRect(rect, primaryTop: 900) == CGRect(x: -1200, y: 1200, width: 400, height: 200), "display above/left")
    check(appKitRect(CGRect(x: 100, y: 1000, width: 200, height: 100), primaryTop: 900).minY == -200, "display below")
    check(closeRect(rect).contains(CGPoint(x: -1205, y: -505)), "hit inside button")
    check(!closeRect(rect).contains(CGPoint(x: -1100, y: -490)), "pass through outside button")
    let display = TreeContext().descending(from: "mc.display")
    let sample = CGRect(x: 20, y: 100, width: 300, height: 200)
    let direct = makeThumbnail(id: "com.example.Editor.space.1", role: kAXButtonRole,
                              title: "Report", rect: sample, context: display)
    check(direct?.ownerBundleID == "com.example.Editor", "macOS 27 direct display child and owner")
    check(ownerBundleID("com.example.Editor.space.12") == "com.example.Editor", "multi-digit space")
    check(ownerBundleID("com.example.Editor.space.") == nil, "empty space rejected")
    check(ownerBundleID("com.example.Editor.space.bad") == nil, "invalid space rejected")
    check(makeThumbnail(id: "mc.spaces.add", role: kAXButtonRole, title: "Desktop", rect: sample, context: display) == nil, "display non-app button rejected")
    let spaces = display.descending(from: "mc.spaces").descending(from: "mc.spaces.list")
    check(makeThumbnail(id: "com.example.Editor.space.1", role: kAXButtonRole,
                        title: "Desktop", rect: sample, context: spaces) == nil, "nested Spaces excluded even with app-like id")
    let legacy = TreeContext().descending(from: "mc").descending(from: "mc.windows")
    check(makeThumbnail(id: "", role: kAXButtonRole, title: "Report", rect: sample, context: legacy) != nil, "legacy window group retained")
    let expose = TreeContext().descending(from: "appexpose.display")
    check(makeThumbnail(id: "com.example.Editor.space.1", role: kAXButtonRole, title: "Report", rect: sample, context: expose) != nil, "direct App Expose child")
    check(makeThumbnail(id: "com.example.Editor.space.1", role: kAXButtonRole, title: "Report", rect: sample, context: TreeContext()) == nil, "app button outside overview excluded")
    let recorded = """
    PROCESS com.apple.WindowManager pid=1
    AXApplication id= title="WindowManager" frame=nil
     AXGroup id=mc.display title="" frame=(0.0, 0.0, 1710.0, 1107.0)
      AXButton id=com.example.Editor.space.1 title="Report" frame=(20.0, 100.0, 300.0, 200.0)
      AXGroup id=mc.spaces title="Spaces Bar" frame=(0.0, 0.0, 1710.0, 73.5)
       AXButton id=mc.spaces.add title="Desktop" frame=(200.0, 0.0, 139.0, 90.0)
    """
    check(replayDiagnostic(recorded).count == 1, "diagnostic replay includes thumbnail and excludes desktop")
    check(uniqueIndex("Example - Google Docs", in: ["Example - Google Docs - Chrome"], owner: "com.google.Chrome") == 0, "Chrome observed AX suffix")
    check(uniqueIndex("Example", in: ["Example - Google Chrome"], owner: "com.google.Chrome") == 0, "Chrome full product suffix")
    check(uniqueIndex("Example", in: ["Example - Chrome"], owner: "com.example.Editor") == nil, "suffix normalization scoped to Chrome")
    check(uniqueIndex("Example", in: ["Example - Chrome", "Example - Google Chrome"], owner: "com.google.Chrome") == nil, "normalized Chrome duplicates rejected")
    check(uniqueIndex("Example", in: ["Example extended - Chrome"], owner: "com.google.Chrome") == nil, "no Chrome substring guessing")
    let thumb = Thumbnail(title: "Example", rect: sample, ownerBundleID: "com.google.Chrome")
    check(closeRect(sample).midX == sample.minX && closeRect(sample).midY == sample.minY, "X centered on top-left border")
    check(hoveredThumbnail([thumb], at: CGPoint(x: sample.minX - 5, y: sample.minY - 5), current: thumb) == thumb, "outer button half keeps hover")
    check(hoveredThumbnail([thumb], at: CGPoint(x: sample.minX - 40, y: sample.minY - 40), current: thumb) == nil, "leaving button hides hover")
    var jitter = thumb
    jitter = Thumbnail(title: "Changed title", rect: sample.offsetBy(dx: 0.3, dy: -0.3), ownerBundleID: thumb.ownerBundleID)
    check(sameLayout([thumb], [jitter]), "subpixel jitter/title change does not reset settling")
    check(!sameLayout([thumb], [Thumbnail(title: "Example", rect: sample.offsetBy(dx: 30, dy: 0), ownerBundleID: thumb.ownerBundleID)]), "moving layout resets settling")
    let cache = WindowResolver()
    var loaderCount = 0
    let load: () -> Inventory = { loaderCount += 1; return Inventory() }
    _ = cache.inventory(owner: "com.google.Chrome", now: 10, loader: load)
    _ = cache.inventory(owner: "com.google.Chrome", now: 10.1, loader: load)
    check(loaderCount == 1, "one owner inventory reused across pointer updates/windows")
    _ = cache.inventory(owner: "com.google.Chrome", now: 11, loader: load)
    check(loaderCount == 2, "inventory expiry refreshes")
    _ = cache.inventory(owner: "com.google.Chrome", now: 11.1, force: true, loader: load)
    check(loaderCount == 3, "click force bypasses cache")
    cache.clear()
    _ = cache.inventory(owner: "com.google.Chrome", now: 11.2, loader: load)
    check(loaderCount == 4, "session clear invalidates inventories")
    let fakeWindow = AXUIElementCreateApplication(123)
    let chromeInventory = Inventory(records: [WindowRecord(ref: WindowRef(pid: 123, window: fakeWindow),
                                                         title: "Example - Chrome", closable: true)])
    check(cache.resolve(thumb, inventory: chromeInventory).target?.pid == 123, "Chrome suffix matching reaches the intended window record")
    let disabled = Inventory(records: [WindowRecord(ref: WindowRef(pid: 123, window: fakeWindow),
                                                  title: "Example - Chrome", closable: false)])
    check(cache.resolve(thumb, inventory: disabled).target == nil, "missing close action still rejected")
    let duplicate = Inventory(records: chromeInventory.records + chromeInventory.records)
    check(cache.resolve(thumb, inventory: duplicate).target == nil, "Chrome same-owner duplicate records rejected")
    var failures = 0
    let failedLoad: () -> Inventory = { failures += 1; return Inventory(error: "test timeout") }
    _ = cache.inventory(owner: "com.example.Failed", now: 20, loader: failedLoad)
    _ = cache.inventory(owner: "com.example.Failed", now: 20.1, loader: failedLoad)
    _ = cache.inventory(owner: "com.example.Failed", now: 20.3, loader: failedLoad)
    check(failures == 2, "temporary AX failures retry after short negative TTL")
    let now = ProcessInfo.processInfo.systemUptime
    cache.cache["com.google.Chrome"] = WindowResolver.Entry(time: now, value: chromeInventory)
    cache.cache["com.example.Editor"] = WindowResolver.Entry(time: now, value: Inventory(records: [
        WindowRecord(ref: WindowRef(pid: 456, window: fakeWindow), title: "Report", closable: true)]))
    let editor = Thumbnail(title: "Report", rect: sample.offsetBy(dx: 500, dy: 0), ownerBundleID: "com.example.Editor")
    var chunks: [[WindowKey: Resolution]] = []
    let batch = cache.batch([editor, thumb], preferredOwner: "com.google.Chrome") { chunks.append($0) }
    check(chunks.count == 2 && chunks.first?[WindowKey(thumb)]?.target?.pid == 123, "hovered owner publishes before other owners")
    check(batch[WindowKey(editor)]?.target?.pid == 456 && batch.count == 2, "owner batches preserve separate targets")
    check(inspectWindow(owner: "com.apple.finder", role: kAXWindowRole, subrole: kAXStandardWindowSubrole), "Finder standard folder is read")
    check(!inspectWindow(owner: "com.apple.finder", role: kAXWindowRole, subrole: "AXUnknown"), "Finder desktop/special window excluded before title query")
    check(!inspectWindow(owner: "com.apple.finder", role: "AXScrollArea", subrole: "AXDesktop"), "Finder non-window desktop surface excluded")
    check(inspectWindow(owner: "com.google.Chrome", role: kAXWindowRole, subrole: "AXUnknown"), "Finder-only filtering leaves Chrome unchanged")
    final class SurfaceSpy: OverlaySurface {
        var visible = true
        var events: [String] = []
        var movedWhileVisible = false
        func hideSurface() { events.append("hide"); visible = false }
        func placeSurface(_ frame: CGRect) { events.append("place"); movedWhileVisible = movedWhileVisible || visible }
        func showSurface() { events.append("show"); visible = true }
    }
    let surface = SurfaceSpy()
    presentOverlayImmediately(surface, frame: sample)
    check(surface.events == ["hide", "place", "show"], "overlay presentation hides before relocating")
    check(!surface.movedWhileVisible, "overlay never moves while visible")
    let finderInventory = Inventory(records: [WindowRecord(ref: WindowRef(pid: 789, window: fakeWindow), title: "Downloads", closable: true)],
                                    notes: ["SKIP Finder special surface"])
    let finderThumb = Thumbnail(title: "Downloads", rect: sample, ownerBundleID: "com.apple.finder")
    check(cache.resolve(finderThumb, inventory: finderInventory).target?.pid == 789, "Finder standard folder resolves after special surface excluded")
    check(cache.resolve(finderThumb, inventory: Inventory(error: "Finder standard title failure")).target == nil, "real Finder inventory failure still blocks closing")
    // A local AXValue verifies typed decoding without Accessibility permission.
    var point = CGPoint(x: 4, y: 8)
    let value = AXValueCreate(.cgPoint, &point)!
    check(AXValueGetType(value) == .cgPoint, "typed AX point")
    print("PASS: \(passed) deterministic checks; no user windows closed")
}
if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if let index = CommandLine.arguments.firstIndex(of: "--replay-diagnostic") {
    guard index + 1 < CommandLine.arguments.count,
          let report = try? String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8) else {
        fputs("Usage: --replay-diagnostic path\n", stderr); exit(1)
    }
    let thumbnails = replayDiagnostic(report)
    print("Replayed thumbnails: \(thumbnails.count)")
    print("With app owner: \(thumbnails.filter { $0.ownerBundleID != nil }.count)")
    print("No live AX reads or close actions performed")
} else if let index = CommandLine.arguments.firstIndex(of: "--render-button") {
    guard index + 1 < CommandLine.arguments.count else { fputs("Usage: --render-button output.png\n", stderr); exit(1) }
    let scale: CGFloat = 8
    let pixels = Int(closeButtonDiameter * scale)
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
    context.scaleBy(x: scale, y: scale)
    drawMacCloseButton(in: context, bounds: CGRect(x: 0, y: 0, width: closeButtonDiameter, height: closeButtonDiameter))
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    guard let bitmap = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, bitmap, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    print("Rendered shared 22pt button drawing at 8x for visual inspection")
} else if CommandLine.arguments.contains("--ui-smoke-test") {
    fputs("Starting AppKit smoke test; require a PASS completion line\n", stderr)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let primary = NSScreen.screens.first else { fputs("No display available\n", stderr); exit(1) }
    let rect = CGRect(x: 100, y: 100, width: closeButtonDiameter, height: closeButtonDiameter)
    let panel = ClosePanel(axRect: rect, primaryTop: primary.frame.maxY)
    presentOverlayImmediately(panel, frame: appKitRect(rect, primaryTop: primary.frame.maxY))
    let correct = panel.isVisible && panel.ignoresMouseEvents &&
        panel.collectionBehavior.contains(.stationary) &&
        panel.frame == appKitRect(rect, primaryTop: primary.frame.maxY)
    panel.orderOut(nil)
    guard correct else { fputs("Panel smoke test failed\n", stderr); exit(1) }
    print("PASS: AppKit panel created, positioned, visible, stationary, click-through, then hidden")
} else if CommandLine.arguments.contains("--diagnose") {
    print(diagnostics(dump: CommandLine.arguments.contains("--dump-ax")))
} else {
    let app = NSApplication.shared
    let delegate = MissionX()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

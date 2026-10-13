import AppKit
import Foundation
import Darwin

struct QuotaWindow: Decodable {
    let used_percent: Double?
    let limit_window_seconds: Double?
    let reset_at: Double?
    let reset_after_seconds: Double?

    var percentage: Double? {
        guard let value = used_percent, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    var remainingPercentage: Double? { percentage.map { 100 - $0 } }

    var label: String {
        guard let seconds = limit_window_seconds, seconds.isFinite, seconds > 0, seconds <= 3153600000 else { return "周期未知" }
        for (unit, duration) in [("周", 604800.0), ("天", 86400.0), ("小时", 3600.0), ("分钟", 60.0)] {
            if seconds.truncatingRemainder(dividingBy: duration) == 0 { return "\(Int(seconds / duration)) \(unit)额度" }
        }
        return "\(Int(seconds)) 秒额度"
    }

    func resetText(refreshedAt: Double?, now: Date = Date()) -> String {
        var epoch = reset_at
        if epoch == nil, let interval = reset_after_seconds, interval.isFinite, interval >= 0,
           interval <= 3153600000, let refreshedAt = refreshedAt { epoch = refreshedAt / 1000 + interval }
        guard let epoch = epoch, epoch.isFinite, epoch > 0, epoch < 4102444800 else { return "重置时间：未知" }
        let remaining = epoch - now.timeIntervalSince1970
        let relative = remaining > 0 ? relativeDuration(seconds: remaining) + "后" : "已到重置时间"
        return "重置时间：" + dateText(milliseconds: epoch * 1000) + "（" + relative + "）"
    }
}

struct QuotaUsage: Decodable {
    let status: String?
    let plan_type: String?
    let windows: [QuotaWindow]?
    let message: String?
}

struct QuotaAccount: Decodable {
    let name: String
    let current: Bool?
    let usage: QuotaUsage?
    let refreshedAt: Double?
}

struct QuotaSnapshot: Decodable {
    let resolution: String?
    let sourceLabel: String?
    let observedAt: Double?
    let error: String?
    let accounts: [QuotaAccount]?

    var account: QuotaAccount? {
        guard ["recent-request", "last-official-request", "desktop-auth", "single-account", "selected-account"].contains(resolution ?? "") else { return nil }
        let current = (accounts ?? []).filter { $0.current == true }
        return current.count == 1 ? current.first : nil
    }

    var stale: Bool { return account?.usage?.status == "stale" }

    var primaryWindow: QuotaWindow? {
        let windows = account?.usage?.windows ?? []
        if let fiveHour = windows.first(where: { $0.limit_window_seconds == 18000 }) { return fiveHour }
        let timed = windows.filter { window in
            guard let duration = window.limit_window_seconds else { return false }
            return duration.isFinite && duration > 0
        }
        return timed.min { $0.limit_window_seconds! < $1.limit_window_seconds! } ?? windows.first
    }

    var statusTitle: String {
        guard let percentage = primaryWindow?.remainingPercentage else { return "--%" }
        return "\(Int(percentage.rounded()))%" + (stale ? "*" : "")
    }

    var hint: String {
        if let error = error, !error.isEmpty { return error }
        switch resolution {
        case "last-official-request": return "最近请求使用第三方通道；这里保留最近 Codex OAuth 账号额度，不是 GLM 或其他第三方模型的额度。"
        case "third-party": return "最近请求使用第三方通道，不能以 OAuth 账号额度代替。"
        case "ambiguous": return "存在多个候选账号，目前无法确定使用哪个账号。"
        case "single-account": return "唯一候选账号，尚无生成请求记录。"
        default: return account == nil ? "暂时无法确定当前账号。" : ""
        }
    }
}

enum QuotaTone {
    case high, medium, low, unknown

    init(remaining: Double?, stale: Bool = false) {
        guard !stale, let remaining = remaining, remaining.isFinite, (0...100).contains(remaining) else {
            self = .unknown
            return
        }
        self = remaining <= 10 ? .low : (remaining <= 30 ? .medium : .high)
    }

    func color(dark: Bool) -> NSColor {
        let rgb: UInt32
        switch self {
        case .high: rgb = dark ? 0x34D399 : 0x2F6B3F
        case .medium: rgb = dark ? 0xFCD34D : 0x8B5B21
        case .low: rgb = dark ? 0xFCA5A5 : 0x9F2D20
        case .unknown: rgb = dark ? 0xB0BDCF : 0x566259
        }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    var dynamicColor: NSColor {
        NSColor(name: nil) { appearance in
            self.color(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}

func quotaCapsuleImage(title: String, percentage: Double?, dark: Bool = false) -> NSImage {
    let size = NSSize(width: 46, height: 18)
    let tint = QuotaTone(remaining: percentage).color(dark: dark)
    let image = NSImage(size: size, flipped: false) { bounds in
        let capsuleBounds = bounds.insetBy(dx: 0.75, dy: 0.75)
        let capsule = NSBezierPath(roundedRect: capsuleBounds, xRadius: 8, yRadius: 8)
        tint.setStroke()
        capsule.lineWidth = 1.25
        capsule.stroke()
        if let percentage = percentage, percentage.isFinite, (0...100).contains(percentage) {
            NSGraphicsContext.saveGraphicsState()
            capsule.addClip()
            tint.withAlphaComponent(0.18).setFill()
            NSRect(x: capsuleBounds.minX, y: capsuleBounds.minY,
                   width: capsuleBounds.width * percentage / 100, height: capsuleBounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: tint
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: (bounds.height - textSize.height) / 2))
        return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Codex 额度剩余 \(title)"
    return image
}

func decodeQuota(data: Data?, status: Int?, failed: Bool) -> QuotaSnapshot? {
    guard !failed, status == 200, let data = data, data.count <= 1024 * 1024,
          let snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data), snapshot.accounts != nil,
          ["recent-request", "last-official-request", "desktop-auth", "single-account", "selected-account", "third-party", "ambiguous", "unavailable"].contains(snapshot.resolution ?? "") else { return nil }
    return snapshot
}

func staleSnapshot(_ snapshot: QuotaSnapshot) -> QuotaSnapshot {
    let accounts = (snapshot.accounts ?? []).map { account in
        let usage = account.usage.map {
            QuotaUsage(status: "stale", plan_type: $0.plan_type, windows: $0.windows, message: $0.message)
        }
        return QuotaAccount(name: account.name, current: account.current, usage: usage, refreshedAt: account.refreshedAt)
    }
    return QuotaSnapshot(resolution: snapshot.resolution, sourceLabel: snapshot.sourceLabel,
                         observedAt: snapshot.observedAt, error: snapshot.error, accounts: accounts)
}

func dateText(milliseconds: Double?) -> String {
    guard let value = milliseconds, value.isFinite, value > 0, value < 4102444800000 else { return "未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "MM-dd HH:mm:ss"
    return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
}

func relativeDuration(seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds < Double(Int.max) else { return "未知" }
    for (unit, duration) in [("天", 86400.0), ("小时", 3600.0), ("分钟", 60.0), ("秒", 1.0)] {
        if seconds >= duration { return "\(Int(seconds / duration))\(unit)" }
    }
    return "0秒"
}

func pastTimeText(label: String, milliseconds: Double?, now: Date = Date()) -> String {
    guard let value = milliseconds, value.isFinite, value > 0, value < 4102444800000 else { return label + "：未知" }
    let elapsed = max(0, now.timeIntervalSince1970 - value / 1000)
    return label + "：" + dateText(milliseconds: value) + "（" + relativeDuration(seconds: elapsed) + "前）"
}

final class QuotaSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class CardView: NSView {
    override var wantsUpdateLayer: Bool { return true }
    override var acceptsFirstResponder: Bool { return true }
    override var isFlipped: Bool { return true }
    var close: (() -> Void)?

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.075, green: 0.11, blue: 0.09, alpha: 1) : NSColor.white).cgColor
        layer?.borderColor = (dark ? NSColor(srgbRed: 0.22, green: 0.29, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.89, blue: 0.86, alpha: 1)).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close?() }
        else { super.keyDown(with: event) }
    }
}

final class QuotaProgress: NSView {
    let percentage: Double
    let stale: Bool

    init(percentage: Double, stale: Bool) {
        self.percentage = percentage
        self.stale = stale
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 7).isActive = true
        setAccessibilityLabel("剩余 \(Int(percentage.rounded()))%" + (stale ? "，过期缓存" : ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3.5, yRadius: 3.5).fill()
        let filled = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * percentage / 100, height: bounds.height)
        QuotaTone(remaining: percentage, stale: stale).dynamicColor.setFill()
        if filled.width > 0 { NSBezierPath(roundedRect: filled, xRadius: 3.5, yRadius: 3.5).fill() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class QuotaAccountPicker: NSPopUpButton {
    private(set) var handlingMouseDown = false
    var interactionEnded: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        handlingMouseDown = true
        defer {
            handlingMouseDown = false
            interactionEnded?()
        }
        super.mouseDown(with: event)
    }
}

final class QuotaRefreshButton: NSButton {
    let iconView = NSImageView()
    private(set) var refreshing = false
    private(set) var isAnimating = false
    var animationVisible = false { didSet { updateAnimation() } }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        iconView.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 24), heightAnchor.constraint(equalToConstant: 24),
                                     iconView.widthAnchor.constraint(equalToConstant: 16), iconView.heightAnchor.constraint(equalToConstant: 16),
                                     iconView.centerXAnchor.constraint(equalTo: centerXAnchor), iconView.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setRefreshing(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    func setRefreshing(_ value: Bool) {
        refreshing = value
        isEnabled = !value
        iconView.contentTintColor = value ? .labelColor : .secondaryLabelColor
        toolTip = value ? "正在刷新额度…" : "刷新额度"
        setAccessibilityLabel(value ? "正在刷新额度" : "刷新额度")
        updateAnimation()
    }

    private func updateAnimation() {
        let animate = refreshing && animationVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate != isAnimating else { return }
        if #available(macOS 15.0, *) {
            if animate { iconView.addSymbolEffect(.rotate.clockwise, options: .repeating) }
            else { iconView.removeAllSymbolEffects(animated: false) }
            isAnimating = animate
        }
    }
}

final class QuotaViewController: NSViewController, NSMenuDelegate {
    let card = CardView(frame: CGRect(x: 0, y: 0, width: 320, height: 360))
    let scroll = NSScrollView()
    let stack = NSStackView()
    let details = NSStackView()
    let accountPicker = QuotaAccountPicker(frame: .zero, pullsDown: false)
    let refreshButton = QuotaRefreshButton()
    var refresh: (() -> Void)?
    var close: (() -> Void)?
    var accounts: [NativeAccountChoice] = []
    var selectedAuthIndex: String?
    var chooseAccount: ((String?) -> Void)?
    var menuIsTracking = false
    var menuTracking: Bool { menuIsTracking || accountPicker.handlingMouseDown }
    var menuTrackingEnded: (() -> Void)?
    var relativeTimeUpdates: [(Date) -> Void] = []

    override func loadView() {
        view = NSView(frame: card.frame)
        card.wantsLayer = true
        card.close = { [weak self] in self?.close?() }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
                                     stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
                                     stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12)])
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = card
        view.addSubview(scroll)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        add(row(text("Codex 账号额度", bold: true), refreshButton), to: stack)
        accountPicker.target = self
        accountPicker.action = #selector(accountSelected(_:))
        accountPicker.menu?.delegate = self
        accountPicker.interactionEnded = { [weak self] in self?.menuTrackingEnded?() }
        add(accountPicker, to: stack)
        divider(in: stack)
        add(details, to: stack)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshButton.animationVisible = true
    }

    override func viewDidDisappear() {
        refreshButton.animationVisible = false
        super.viewDidDisappear()
    }

    func text(_ value: String, bold: Bool = false, muted: Bool = false, warning: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: String(value.prefix(2048)))
        field.font = NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        field.textColor = warning ? .systemOrange : (muted ? .secondaryLabelColor : .labelColor)
        field.preferredMaxLayoutWidth = 296
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func add(_ child: NSView, to container: NSStackView? = nil) {
        let target = container ?? details
        target.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
    }

    func row(_ left: NSView, _ right: NSView) -> NSStackView {
        let row = NSStackView(views: [left, NSView(), right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    func divider(in container: NSStackView? = nil) {
        let separator = NSBox()
        separator.boxType = .separator
        add(separator, to: container)
    }

    func update(snapshot: QuotaSnapshot?, failure: String?, loading: Bool) -> CGSize {
        _ = view
        relativeTimeUpdates.removeAll()
        for child in details.arrangedSubviews { details.removeArrangedSubview(child); child.removeFromSuperview() }
        refreshButton.setRefreshing(loading)
        accountPicker.isHidden = accounts.isEmpty
        let sameAccounts = accountPicker.numberOfItems == accounts.count + 1 && zip(accountPicker.itemArray.dropFirst(), accounts).allSatisfy {
            $0.0.title == String($0.1.name.prefix(100)) && $0.0.representedObject as? String == $0.1.authIndex
        }
        if !sameAccounts {
            accountPicker.removeAllItems()
            accountPicker.addItem(withTitle: "自动识别（CPA 最近账号 / 唯一账号）")
            for account in accounts {
                let item = NSMenuItem(title: String(account.name.prefix(100)), action: nil, keyEquivalent: "")
                item.representedObject = account.authIndex
                accountPicker.menu?.addItem(item)
            }
        }
        if let selected = selectedAuthIndex, let item = accountPicker.itemArray.first(where: { $0.representedObject as? String == selected }) {
            if accountPicker.selectedItem !== item { accountPicker.select(item) }
        } else if accountPicker.indexOfSelectedItem != 0 { accountPicker.selectItem(at: 0) }
        if let failure = failure {
            add(text(failure, warning: true))
        } else if let snapshot = snapshot {
            if snapshot.observedAt != nil {
                let observedLabel = text(pastTimeText(label: "观察时间", milliseconds: snapshot.observedAt), muted: true)
                add(observedLabel)
                relativeTimeUpdates.append { [weak observedLabel] now in
                    observedLabel?.stringValue = pastTimeText(label: "观察时间", milliseconds: snapshot.observedAt, now: now)
                }
            }
            if !snapshot.hint.isEmpty { add(text(snapshot.hint, warning: snapshot.account == nil)) }
            if let account = snapshot.account {
                divider()
                add(text(account.name, bold: true))
                if let plan = account.usage?.plan_type, !plan.isEmpty { add(text("套餐：" + plan, muted: true)) }
                if snapshot.stale { add(text("以下为过期缓存额度，可能不再准确。", warning: true)) }
                if let message = account.usage?.message, !message.isEmpty { add(text(message, warning: true)) }
                if account.usage?.status == "limit_reached" { add(text("已触及额度限制。", warning: true)) }
                if account.usage?.status == "not_allowed" { add(text("当前账号暂不允许使用。", warning: true)) }
                let windows = account.usage?.windows ?? []
                for window in windows.prefix(8) {
                    let percentage = window.remainingPercentage.map { "剩余 \(Int($0.rounded()))%" } ?? "剩余额度未知"
                    let percentageLabel = text(percentage, bold: true)
                    percentageLabel.textColor = QuotaTone(remaining: window.remainingPercentage, stale: snapshot.stale).dynamicColor
                    add(row(text(window.label), percentageLabel))
                    if let percentage = window.remainingPercentage { add(QuotaProgress(percentage: percentage, stale: snapshot.stale)) }
                    let resetLabel = text(window.resetText(refreshedAt: account.refreshedAt), muted: true)
                    add(resetLabel)
                    relativeTimeUpdates.append { [weak resetLabel] now in
                        resetLabel?.stringValue = window.resetText(refreshedAt: account.refreshedAt, now: now)
                    }
                }
                if windows.isEmpty { add(text("暂无可用额度信息", muted: true)) }
                let acquiredLabel = text(pastTimeText(label: "获取时间", milliseconds: account.refreshedAt), muted: true)
                add(acquiredLabel)
                relativeTimeUpdates.append { [weak acquiredLabel] now in
                    acquiredLabel?.stringValue = pastTimeText(label: "获取时间", milliseconds: account.refreshedAt, now: now)
                }
            }
        } else {
            add(text(loading ? "正在读取账号额度…" : "尚未读取额度", muted: true))
        }
        details.isHidden = details.arrangedSubviews.isEmpty
        card.layoutSubtreeIfNeeded()
        let height = max(180, stack.fittingSize.height + 24)
        card.setFrameSize(CGSize(width: 320, height: height))
        return CGSize(width: 320, height: min(height, max(180, (NSScreen.main?.visibleFrame.height ?? 800) * 0.75)))
    }

    @objc func refreshClicked() { refresh?() }
    @objc func accountSelected(_ sender: NSPopUpButton) { chooseAccount?(sender.selectedItem?.representedObject as? String) }

    func updateRelativeTimes(now: Date = Date()) {
        for update in relativeTimeUpdates { update(now) }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsTracking = true }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            self?.menuIsTracking = false
            self?.menuTrackingEnded?()
        }
    }
}

struct QuotaPopoverPresentation {
    enum Phase: String { case closed, opening, open, closing }
    enum Action { case show, close }

    private(set) var phase = Phase.closed
    private(set) var wantsOpen = false

    mutating func request(open: Bool) -> Action? {
        wantsOpen = open
        return nextAction()
    }

    mutating func didShow() -> Action? {
        guard phase == .opening else { return nil }
        phase = .open
        return nextAction()
    }

    mutating func willClose() {
        if phase != .closing { wantsOpen = false }
        phase = .closing
    }

    mutating func didClose() -> Action? {
        guard phase != .closed else { return nil }
        phase = .closed
        return nextAction()
    }

    private mutating func nextAction() -> Action? {
        if phase == .closed && wantsOpen { phase = .opening; return .show }
        if phase == .open && !wantsOpen { phase = .closing; return .close }
        return nil
    }
}

func isStatusContextClick(_ event: NSEvent, in view: NSView) -> Bool {
    let contextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    guard contextClick, let window = view.window, event.window === window else { return false }
    return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
}

final class QuotaApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let home: URL = {
        let args = CommandLine.arguments
        let position = args.firstIndex(of: "--home")
        let path = position.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? ProcessInfo.processInfo.environment["CODEX_ACCOUNT_WIDGET_HOME"] ?? "~/Library/Application Support/CodexQuotaMenubar"
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }()
    let socketURL: URL = {
        let args = CommandLine.arguments
        if let position = args.firstIndex(of: "--socket-path"), args.count > position + 1 {
            return URL(fileURLWithPath: NSString(string: args[position + 1]).expandingTildeInPath)
        }
        let home = args.firstIndex(of: "--home").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["CODEX_ACCOUNT_WIDGET_HOME"]
            ?? "~/Library/Application Support/CodexQuotaMenubar"
        return nativeDefaultSocketURL(home: URL(fileURLWithPath: NSString(string: home).expandingTildeInPath))
    }()
    let popover = NSPopover()
    let controller = QuotaViewController()
    var statusItem: NSStatusItem?
    let statusContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let quitItem = NSMenuItem(title: "退出", action: #selector(userQuit), keyEquivalent: "")
        menu.addItem(quitItem)
        return menu
    }()
    var statusContextClickMonitor: Any?
    var pendingStatusContextMenu = false
    var statusContextMenuVisible = false
    var engine: NativeQuotaEngine!
    var eventSource: DispatchSourceRead?
    var eventDescriptor: Int32 = -1
    var nativeLock: Int32 = -1
    var ownsNativeLock = false
    var ipcListener: NativeEventListener?
    var managed = false
    var userRequestedQuit = false
    var eventsReceived = 0
    var snapshot: QuotaSnapshot?
    var failure: String?
    var loading = false
    var requestCount = 0
    var lastRequest: TimeInterval = 0
    var terminationSignal: DispatchSourceSignal?
    var wakeObserver: NSObjectProtocol?
    var outsideClickMonitor: Any?
    var outsideClickMonitorID: UUID?
    var pendingViewUpdate = false
    var presentation = QuotaPopoverPresentation()
    var closingAnimated = true
    var relativeTimeTimer: Timer?
    var statusAppearanceObservation: NSKeyValueObservation?

    override init() {
        super.init()
        statusContextMenu.items.first?.target = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler { NSApplication.shared.terminate(nil) }
        terminationSignal.resume()
        self.terminationSignal = terminationSignal
        let directory = home.appendingPathComponent("run/menubar")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        nativeLock = open(directory.appendingPathComponent("native.lock").path, O_CREAT | O_RDWR, 0o600)
        guard nativeLock >= 0, flock(nativeLock, LOCK_EX | LOCK_NB) == 0 else { NSApplication.shared.terminate(nil); return }
        ownsNativeLock = true
        let settings = (try? boundedData(home.appendingPathComponent("cpa-plugin/settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cpaPath = settings?["cpaHome"] as? String ?? NSString(string: "~/Library/Application Support/com.cpa.gui").expandingTildeInPath
        eventDescriptor = nativeEventDescriptor(arguments: CommandLine.arguments)
        managed = eventDescriptor >= 0
        let authDirectory = (settings?["authDir"] as? String).map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        let managementPort = (settings?["managementPort"] as? NSNumber)?.intValue ?? 8317
        engine = NativeQuotaEngine(cpaHome: URL(fileURLWithPath: cpaPath), managed: managed,
            authDirectory: authDirectory, selectedAuthIndex: settings?["selectedAuthIndex"] as? String,
            settingsURL: home.appendingPathComponent("cpa-plugin/settings.json"), managementPort: managementPort)
        engine.onAccounts = { [weak self] accounts, selected in
            self?.controller.accounts = accounts
            self?.controller.selectedAuthIndex = selected
            self?.updateView()
        }
        engine.onSnapshot = { [weak self] snapshot, count in
            guard let self = self else { return }
            self.snapshot = snapshot
            self.requestCount = count
            self.failure = nil
            self.updateStatusButton()
            self.updateView()
            self.writeStatus()
        }
        engine.onLoading = { [weak self] loading in
            guard let self = self else { return }
            self.loading = loading
            if self.controller.isViewLoaded { self.controller.refreshButton.setRefreshing(loading) }
            self.updateView()
            self.writeStatus()
        }
        engine.onDisabled = { NSApplication.shared.terminate(nil) }
        let record: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "executable": Bundle.main.executableURL?.path ?? CommandLine.arguments[0], "launchedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: directory.appendingPathComponent("pid.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("pid.json").path)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let listener = NativeEventListener(socketURL: socketURL, managed: managed, version: nativeHelperVersion())
        listener.onEvent = { [weak self] count in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.eventsReceived += count
                self.engine.event()
                self.writeStatus()
            }
        }
        do { try listener.start(); ipcListener = listener }
        catch { NSApplication.shared.terminate(nil); return }
        if eventDescriptor >= 0 {
            guard fcntl(eventDescriptor, F_GETFD) >= 0 else { NSApplication.shared.terminate(nil); return }
            _ = fcntl(eventDescriptor, F_SETFL, O_NONBLOCK)
            var enabled: Int32 = 1
            _ = setsockopt(eventDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: eventDescriptor, queue: .main)
            source.setEventHandler { [weak self] in self?.readEvents() }
            source.resume()
            eventSource = source
        }
        statusItem?.button?.imagePosition = .imageOnly
        statusAppearanceObservation = statusItem?.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.updateStatusButton() }
        }
        updateStatusButton()
        configureStatusItemInteraction()
        if eventDescriptor >= 0 {
            let ready = nativeIPCReply(managed: true, version: nativeHelperVersion())
            let sent = ready.withUnsafeBytes { bytes in send(eventDescriptor, bytes.baseAddress, bytes.count, 0) }
            guard sent == ready.count else { NSApplication.shared.terminate(nil); return }
        }
        statusContextClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self = self, let button = self.statusItem?.button,
                  isStatusContextClick(event, in: button) else { return event }
            guard !self.statusContextMenuVisible else { return event }
            self.pendingStatusContextMenu = true
            self.dismissPopover()
            self.showPendingStatusContextMenu()
            return nil
        }
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentViewController = controller
        controller.refresh = { [weak self] in self?.refresh(force: true) }
        controller.chooseAccount = { [weak self] selected in self?.engine.selectAccount(selected) }
        controller.close = { [weak self] in self?.dismissPopover() }
        controller.menuTrackingEnded = { [weak self] in
            guard let self = self, self.pendingViewUpdate else { return }
            self.updateView()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.refresh(force: false, demand: true)
        }
        engine.start()
        writeStatus()
    }

    @objc func userQuit() {
        userRequestedQuit = true
        NSApplication.shared.terminate(nil)
    }

    func configureStatusItemInteraction() {
#if QUOTA_MACOS27_SDK
        if #available(macOS 27.0, *) {
            statusItem?.expandedInterfaceDelegate = self
            return
        }
#endif
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
    }

    func cancelExpandedInterfaceSession() {
#if QUOTA_MACOS27_SDK
        if #available(macOS 27.0, *) { statusItem?.expandedInterfaceSession?.cancel() }
#endif
    }

    @objc func togglePopover() {
        requestPopover(open: !presentation.wantsOpen)
    }

    func requestPopover(open: Bool, animated: Bool = true) {
        if open { pendingStatusContextMenu = false }
        if !open { closingAnimated = animated }
        applyPopoverAction(presentation.request(open: open))
        writeStatus()
    }

    func dismissPopover() {
        requestPopover(open: false)
        cancelExpandedInterfaceSession()
    }

    func showPendingStatusContextMenu() {
        guard pendingStatusContextMenu, !statusContextMenuVisible,
              presentation.phase == .closed, !popover.isShown, let button = statusItem?.button else { return }
        pendingStatusContextMenu = false
        statusContextMenuVisible = true
        button.highlight(true)
        defer {
            button.highlight(false)
            statusContextMenuVisible = false
        }
        statusContextMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
    }

    func applyPopoverAction(_ action: QuotaPopoverPresentation.Action?) {
        switch action {
        case .show:
            guard let button = statusItem?.button else { presentation = QuotaPopoverPresentation(); return }
            updateView(force: true)
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if popover.isShown && presentation.wantsOpen && presentation.phase != .closing {
                startOutsideClickMonitor()
                if ProcessInfo.processInfo.systemUptime - lastRequest >= 10 { refresh(force: false, demand: true) }
            } else if !popover.isShown && presentation.phase == .opening {
                presentation = QuotaPopoverPresentation()
                cancelExpandedInterfaceSession()
            }
        case .close:
            stopOutsideClickMonitor()
            controller.accountPicker.menu?.cancelTracking()
            popover.animates = closingAnimated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.close()
        case nil:
            break
        }
    }

    func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        let monitorID = UUID()
        let startedAt = ProcessInfo.processInfo.systemUptime
        outsideClickMonitorID = monitorID
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.outsideClickMonitorID == monitorID,
                      event.timestamp >= startedAt, self.presentation.wantsOpen else { return }
                self.dismissPopover()
            }
        }
    }

    func stopOutsideClickMonitor() {
        outsideClickMonitorID = nil
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    func popoverDidShow(_ notification: Notification) {
        applyPopoverAction(presentation.didShow())
        if presentation.phase == .open {
            relativeTimeTimer?.invalidate()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.controller.updateRelativeTimes() }
            relativeTimeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if presentation.phase == .open && !controller.menuTracking {
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            popover.contentViewController?.view.window?.makeFirstResponder(controller.card)
        }
        if pendingViewUpdate { updateView() }
        writeStatus()
    }

    func popoverWillClose(_ notification: Notification) {
        relativeTimeTimer?.invalidate()
        relativeTimeTimer = nil
        presentation.willClose()
        stopOutsideClickMonitor()
        if !presentation.wantsOpen { cancelExpandedInterfaceSession() }
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        let action = presentation.didClose()
        if action != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.presentation.wantsOpen { self.applyPopoverAction(action) }
                else { self.presentation = QuotaPopoverPresentation() }
                self.writeStatus()
            }
        } else if pendingStatusContextMenu {
            DispatchQueue.main.async { [weak self] in self?.showPendingStatusContextMenu() }
        }
        writeStatus()
    }

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = quotaCapsuleImage(title: snapshot?.statusTitle ?? "--%",
            percentage: snapshot?.stale == true ? nil : snapshot?.primaryWindow?.remainingPercentage,
            dark: button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        if let snapshot = snapshot {
            let quota = snapshot.primaryWindow?.label ?? "额度"
            let state = snapshot.stale ? "缓存已过期" : (snapshot.sourceLabel ?? "来源未知")
            statusItem?.button?.toolTip = "Codex · \(quota)剩余 \(snapshot.statusTitle) · \(state)"
        } else {
            statusItem?.button?.toolTip = failure == nil ? "Codex 账号额度 · 正在读取" : "Codex 额度服务不可用"
        }
    }

    func updateView(force: Bool = false) {
        guard force || popover.isShown else { return }
        if !force && presentation.phase != .open { pendingViewUpdate = true; return }
        guard !controller.menuTracking else { pendingViewUpdate = true; return }
        pendingViewUpdate = false
        popover.contentSize = controller.update(snapshot: snapshot, failure: failure, loading: loading)
    }

    func refresh(force: Bool, demand: Bool = false) {
        lastRequest = ProcessInfo.processInfo.systemUptime
        engine.request(force ? .manual : .demand)
    }

    func readEvents() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(eventDescriptor, &bytes, bytes.count)
            if count > 0 {
                let received = bytes.prefix(count).filter { $0 == 85 }.count
                eventsReceived += received
                if received > 0 { engine.event() }
            } else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    NSApplication.shared.terminate(nil)
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
        }
        writeStatus()
    }

    func writeStatus() {
        let directory = home.appendingPathComponent("run/menubar")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "helperVersion": nativeHelperVersion(), "protocolVersion": nativeProtocolVersion,
                                  "visible": statusItem?.isVisible ?? false,
                                  "popoverVisible": popover.isShown, "quotaAvailable": snapshot?.account?.usage?.windows?.isEmpty == false, "mode": "native", "launchMode": managed ? "cpa-managed" : "independent", "eventsReceived": eventsReceived,
                                  "popoverPhase": presentation.phase.rawValue, "popoverRequestedOpen": presentation.wantsOpen,
                                  "resolution": snapshot?.resolution ?? "unavailable", "stale": snapshot?.stale ?? false,
                                  "loading": loading, "updatedAt": Int(Date().timeIntervalSince1970), "error": failure ?? snapshot?.error ?? "",
                                  "requestCount": requestCount, "refreshIntervalSeconds": 0, "windowTrackingEnabled": false]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            let path = directory.appendingPathComponent("status.json")
            try? data.write(to: path, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingStatusContextMenu = false
        statusContextMenu.cancelTracking()
        if let monitor = statusContextClickMonitor { NSEvent.removeMonitor(monitor) }
        statusContextClickMonitor = nil
        statusAppearanceObservation?.invalidate()
        relativeTimeTimer?.invalidate()
        stopOutsideClickMonitor()
        if let wakeObserver = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        terminationSignal?.cancel()
        engine?.close()
        ipcListener?.close(userRequestedQuit: userRequestedQuit)
        eventSource?.cancel()
        if eventDescriptor >= 0 {
            if userRequestedQuit { _ = send(eventDescriptor, Array("D".utf8), 1, 0) }
            Darwin.close(eventDescriptor)
        }
        guard ownsNativeLock else { return }
        let pidURL = home.appendingPathComponent("run/menubar/pid.json")
        if let data = try? Data(contentsOf: pidURL), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           record["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: pidURL)
        }
        presentation = QuotaPopoverPresentation()
        popover.close()
        if let statusItem = statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        try? FileManager.default.removeItem(at: home.appendingPathComponent("run/menubar/status.json"))
    }
}

#if QUOTA_MACOS27_SDK
@available(macOS 27.0, *)
extension QuotaApp: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        requestPopover(open: true)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        requestPopover(open: false, animated: animated)
    }
}
#endif

let previewFixture = Data("""
    {"resolution":"recent-request","sourceLabel":"CPA 最近请求","observedAt":1790740000000,"accounts":[{"name":"fixture","current":true,"refreshedAt":1790740000000,"usage":{"status":"ok","plan_type":"plus","windows":[{"used_percent":47,"limit_window_seconds":18000,"reset_after_seconds":300},{"used_percent":82,"limit_window_seconds":604800}]}}]}
    """.utf8)

func renderPreview(to path: String) throws {
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.appearance = NSAppearance(named: .darkAqua)
    let controller = QuotaViewController()
    controller.accounts = [NativeAccountChoice(name: "fixture", authIndex: "fixture-account")]
    _ = controller.update(snapshot: try JSONDecoder().decode(QuotaSnapshot.self, from: previewFixture), failure: nil, loading: false)
    controller.updateRelativeTimes(now: Date(timeIntervalSince1970: 1790740045))
    controller.card.layoutSubtreeIfNeeded()
    guard let bitmap = controller.card.bitmapImageRepForCachingDisplay(in: controller.card.bounds) else { throw NativeQuotaError.response }
    controller.card.cacheDisplay(in: controller.card.bounds, to: bitmap)
    guard let image = bitmap.representation(using: .png, properties: [:]) else { throw NativeQuotaError.response }
    try image.write(to: URL(fileURLWithPath: path), options: .atomic)
    print("{\"ok\":true,\"fixtureOnly\":true}")
}

func nativePopoverSelfTest(check: (Bool) -> Void) {
    var presentation = QuotaPopoverPresentation()
    for _ in 0..<3 {
        check(presentation.request(open: true) == .show)
        check(presentation.didShow() == nil && presentation.phase == .open)
        check(presentation.request(open: false) == .close)
        presentation.willClose()
        check(presentation.didClose() == nil && presentation.phase == .closed)
    }
    check(presentation.request(open: true) == .show)
    check(presentation.request(open: false) == nil)
    check(presentation.didShow() == .close)
    presentation.willClose()
    check(presentation.request(open: true) == nil && presentation.wantsOpen)
    check(presentation.didClose() == .show)
    check(presentation.didShow() == nil && presentation.phase == .open)
    check(presentation.request(open: true) == nil)
    check(presentation.request(open: false) == .close)
    presentation.willClose()
    check(presentation.request(open: true) == nil)
    check(presentation.request(open: false) == nil)
    check(presentation.didClose() == nil && !presentation.wantsOpen)
    check(presentation.didClose() == nil && presentation.phase == .closed)
    check(presentation.request(open: true) == .show)
    check(presentation.didShow() == nil)
    presentation.willClose()
    check(!presentation.wantsOpen)
    check(presentation.didClose() == nil && presentation.phase == .closed)
    check(presentation.request(open: true) == .show)
    check(presentation.request(open: false) == nil)
    check(presentation.request(open: true) == nil)
    check(presentation.didShow() == nil && presentation.phase == .open && presentation.wantsOpen)
}

func nativeStatusContextMenuSelfTest(check: (Bool) -> Void) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let button = NSView(frame: NSRect(x: 20, y: 30, width: 46, height: 18))
    window.contentView?.addSubview(button)
    let inside = NSPoint(x: 43, y: 39)
    let outside = NSPoint(x: 5, y: 5)
    let cases: [(NSEvent.EventType, NSEvent.ModifierFlags, NSPoint, Int, Bool)] = [
        (.rightMouseDown, [], inside, window.windowNumber, true),
        (.leftMouseDown, .control, inside, window.windowNumber, true),
        (.leftMouseDown, [], inside, window.windowNumber, false),
        (.leftMouseDown, .command, inside, window.windowNumber, false),
        (.rightMouseUp, [], inside, window.windowNumber, false),
        (.rightMouseDown, [], outside, window.windowNumber, false),
        (.leftMouseDown, .control, outside, window.windowNumber, false),
        (.rightMouseDown, [], inside, 0, false)
    ]
    for (type, modifiers, location, windowNumber, expected) in cases {
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        check(isStatusContextClick(event, in: button) == expected)
    }
}

func selfTest() throws {
    var checks = 0
    func check(_ condition: Bool) {
        guard condition else { fputs("Native fixture check \(checks + 1) failed\n", stderr); exit(1) }
        checks += 1
    }
    let fixture = previewFixture
    let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: fixture)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let viewApp = QuotaApp()
    viewApp.snapshot = snapshot
    viewApp.controller.accounts = [NativeAccountChoice(name: "fixture", authIndex: "fixture-account")]
    viewApp.updateView(force: true)
    check(viewApp.statusContextMenu.items.map(\.title) == ["退出"])
    check(viewApp.statusContextMenu.items[0].target === viewApp)
    check(viewApp.statusContextMenu.items[0].action == #selector(QuotaApp.userQuit))
    check(viewApp.statusContextMenu.items[0].isEnabled)
    check(viewApp.controller.stack.arrangedSubviews.count == 4)
    check(viewApp.controller.stack.arrangedSubviews.last === viewApp.controller.details)
    check(viewApp.controller.refreshButton.superview?.superview === viewApp.controller.stack)
    var refreshClicks = 0
    viewApp.controller.refresh = { refreshClicks += 1 }
    viewApp.controller.refreshButton.performClick(nil)
    check(refreshClicks == 1)
    let picker = viewApp.controller.accountPicker
    let originalMenu = picker.menu!
    let originalItem = picker.item(at: 1)!
    let originalParent = picker.superview
    for loading in [true, false, true, false] {
        viewApp.loading = loading
        viewApp.updateView(force: true)
    }
    let refreshButton = viewApp.controller.refreshButton
    check(refreshButton.title.isEmpty && refreshButton.iconView.image != nil)
    check(refreshButton.isEnabled && !refreshButton.refreshing && !refreshButton.isAnimating)
    refreshButton.setRefreshing(true)
    check(!refreshButton.isEnabled && refreshButton.refreshing && !refreshButton.isAnimating)
    refreshButton.animationVisible = true
    if #available(macOS 15.0, *) { check(refreshButton.isAnimating == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
    refreshButton.animationVisible = false
    check(!refreshButton.isAnimating && refreshButton.refreshing)
    refreshButton.setRefreshing(false)
    check(refreshButton.isEnabled && !refreshButton.isAnimating)
    check(picker.superview === originalParent && picker.menu === originalMenu)
    check(picker.item(at: 1) === originalItem)
    check(viewApp.controller.stack.arrangedSubviews.contains { $0 === picker })
    check(picker.acceptsFirstMouse(for: nil))
    viewApp.controller.menuWillOpen(originalMenu)
    viewApp.controller.accounts.append(NativeAccountChoice(name: "another", authIndex: "another-account"))
    viewApp.controller.selectedAuthIndex = "another-account"
    viewApp.updateView(force: true)
    check(viewApp.pendingViewUpdate && picker.numberOfItems == 2)
    check(picker.item(at: 1) === originalItem)
    viewApp.controller.menuTrackingEnded = { [weak viewApp] in viewApp?.updateView(force: true) }
    viewApp.controller.menuDidClose(originalMenu)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(!viewApp.pendingViewUpdate && !viewApp.controller.menuTracking)
    check(picker.numberOfItems == 3 && picker.selectedItem?.representedObject as? String == "another-account")
    check(picker.superview === originalParent && picker.menu === originalMenu)
    check(snapshot.account?.name == "fixture" && !snapshot.stale)
    let windows = snapshot.account!.usage!.windows!
    check(windows[0].label == "5 小时额度" && windows[1].label == "1 周额度")
    check(windows[0].percentage == 47 && windows[1].percentage == 82)
    check(windows[0].remainingPercentage == 53 && windows[1].remainingPercentage == 18)
    check(viewApp.controller.details.arrangedSubviews.compactMap { ($0 as? QuotaProgress)?.percentage } == [53, 18])
    check(snapshot.statusTitle == "53%")
    let retainedData = Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "recent-request", with: "last-official-request").utf8)
    let retained = try JSONDecoder().decode(QuotaSnapshot.self, from: retainedData)
    check(retained.statusTitle == "53%" && retained.account?.name == "fixture")
    check(retained.hint.contains("不是 GLM"))
    check(decodeQuota(data: retainedData, status: 200, failed: false)?.statusTitle == "53%")
    check(staleSnapshot(retained).statusTitle == "53%*")
    let capsuleSamples: [(String, Double?)] = [("0%", 0), ("53%", 53), ("18%", 18), ("5%", 5), ("100%", 100), ("100%*", nil), ("--%", nil)]
    for (title, percentage) in capsuleSamples {
        let image = quotaCapsuleImage(title: title, percentage: percentage)
        check(!image.isTemplate && image.size == NSSize(width: 46, height: 18))
        check(image.tiffRepresentation != nil)
    }
    let tones: [(Double, QuotaTone)] = [(0, .low), (10, .low), (10.1, .medium), (30, .medium), (30.1, .high), (100, .high)]
    for (percentage, expected) in tones { check(QuotaTone(remaining: percentage) == expected) }
    for percentage in [nil, -1, 101, Double.nan, Double.infinity] as [Double?] { check(QuotaTone(remaining: percentage) == .unknown) }
    check(QuotaTone(remaining: 53, stale: true) == .unknown)
    let palette: [(QuotaTone, UInt32, UInt32)] = [(.high, 0x2F6B3F, 0x34D399), (.medium, 0x8B5B21, 0xFCD34D), (.low, 0x9F2D20, 0xFCA5A5), (.unknown, 0x566259, 0xB0BDCF)]
    for (tone, light, dark) in palette {
        for (isDark, expected) in [(false, light), (true, dark)] {
            let color = tone.color(dark: isDark).usingColorSpace(.sRGB)!
            let rgb = (UInt32((color.redComponent * 255).rounded()) << 16) | (UInt32((color.greenComponent * 255).rounded()) << 8) | UInt32((color.blueComponent * 255).rounded())
            check(rgb == expected)
        }
    }
    let weeklyOnly = QuotaSnapshot(resolution: "single-account", sourceLabel: nil, observedAt: nil, error: nil,
        accounts: [QuotaAccount(name: "fixture", current: true,
            usage: QuotaUsage(status: "ok", plan_type: nil, windows: [windows[1]], message: nil), refreshedAt: nil)])
    check(weeklyOnly.statusTitle == "18%" && weeklyOnly.primaryWindow?.label == "1 周额度")
    let reversed = QuotaSnapshot(resolution: "recent-request", sourceLabel: nil, observedAt: nil, error: nil,
        accounts: [QuotaAccount(name: "fixture", current: true,
            usage: QuotaUsage(status: "ok", plan_type: nil, windows: windows.reversed(), message: nil), refreshedAt: nil)])
    check(reversed.statusTitle == "53%")
    let referenceTime = Date(timeIntervalSince1970: 1790740000)
    check(windows[0].resetText(refreshedAt: snapshot.account?.refreshedAt, now: referenceTime) == "重置时间：" + dateText(milliseconds: 1790740300000) + "（5分钟后）")
    check(windows[1].resetText(refreshedAt: nil, now: referenceTime) == "重置时间：未知")
    for (seconds, expected) in [(0.0, "0秒"), (59, "59秒"), (60, "1分钟"), (3599, "59分钟"), (3600, "1小时"), (86399, "23小时"), (86400, "1天"), (172800, "2天")] {
        check(relativeDuration(seconds: seconds) == expected)
        let fetched = (referenceTime.timeIntervalSince1970 - seconds) * 1000
        for label in ["获取时间", "观察时间"] {
            check(pastTimeText(label: label, milliseconds: fetched, now: referenceTime) == label + "：" + dateText(milliseconds: fetched) + "（" + expected + "前）")
        }
        if seconds > 0 {
            let window = QuotaWindow(used_percent: 0, limit_window_seconds: nil, reset_at: referenceTime.timeIntervalSince1970 + seconds, reset_after_seconds: nil)
            check(window.resetText(refreshedAt: nil, now: referenceTime).hasSuffix("（" + expected + "后）"))
        }
    }
    check(windows[0].resetText(refreshedAt: snapshot.account?.refreshedAt, now: referenceTime.addingTimeInterval(300)).hasSuffix("（已到重置时间）"))
    check(pastTimeText(label: "获取时间", milliseconds: nil, now: referenceTime) == "获取时间：未知")
    viewApp.controller.updateRelativeTimes(now: referenceTime.addingTimeInterval(61))
    check(viewApp.controller.details.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.hasPrefix("获取时间：") && $0.hasSuffix("（1分钟前）") })
    check(viewApp.controller.details.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.hasPrefix("观察时间：") && $0.hasSuffix("（1分钟前）") })
    check(picker.menu === originalMenu && picker.superview === originalParent)
    for percentage in [-1.0, 101, Double.infinity, Double.nan] {
        check(QuotaWindow(used_percent: percentage, limit_window_seconds: nil, reset_at: nil, reset_after_seconds: nil).remainingPercentage == nil)
    }
    for (used, remaining) in [(0.0, 100.0), (100.0, 0.0)] {
        check(QuotaWindow(used_percent: used, limit_window_seconds: nil, reset_at: nil, reset_after_seconds: nil).remainingPercentage == remaining)
    }
    check(QuotaWindow(used_percent: nil, limit_window_seconds: nil, reset_at: nil, reset_after_seconds: nil).remainingPercentage == nil)
    check(QuotaWindow(used_percent: nil, limit_window_seconds: nil, reset_at: nil, reset_after_seconds: nil).label == "周期未知")
    check(QuotaWindow(used_percent: 0, limit_window_seconds: 2592000, reset_at: nil, reset_after_seconds: nil).label == "30 天额度")
    check(dateText(milliseconds: .infinity) == "未知" && dateText(milliseconds: -1) == "未知")
    for resolution in ["third-party", "ambiguous", "unavailable", "unsupported"] {
        let changed = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "recent-request", with: resolution)
        let changedSnapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(changed.utf8))
        check(changedSnapshot.account == nil)
        check(changedSnapshot.statusTitle == "--%")
    }
    let stale = String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "\"status\":\"ok\"", with: "\"status\":\"stale\"")
    let staleSnapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(stale.utf8))
    check(staleSnapshot.stale)
    check(staleSnapshot.statusTitle == "53%*")
    check(decodeQuota(data: fixture, status: 200, failed: false)?.account?.name == "fixture")
    check(decodeQuota(data: fixture, status: 401, failed: false) == nil)
    check(decodeQuota(data: fixture, status: 200, failed: true) == nil)
    check(decodeQuota(data: Data("{}".utf8), status: 200, failed: false) == nil)
    check(decodeQuota(data: Data(repeating: 32, count: 1024 * 1024 + 1), status: 200, failed: false) == nil)
    let unresolved = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("{\"resolution\":\"desktop-auth\",\"accounts\":[{\"name\":\"one\",\"current\":true},{\"name\":\"two\",\"current\":true}]}".utf8))
    check(unresolved.account == nil)
    check(unresolved.statusTitle == "--%")
    nativePopoverSelfTest(check: check)
    nativeStatusContextMenuSelfTest(check: check)
    try nativeSelfTest(check: check)
    try nativeIPCSelfTest(check: check)
    print("{\"ok\":true,\"checks\":\(checks)}")
}

if let preview = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > preview + 1 {
    do { try renderPreview(to: CommandLine.arguments[preview + 1]) }
    catch { fputs("Fixture preview rendering failed\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    do { try selfTest() }
    catch { fputs("Native quota self-test failed\n", stderr); exit(1) }
} else {
    let application = NSApplication.shared
    let delegate = QuotaApp()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    application.run()
}

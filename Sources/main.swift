import AppKit
import ServiceManagement

private enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let colorPreset: UInt8 = 0x14
    static let redGain: UInt8 = 0x16
    static let greenGain: UInt8 = 0x18
    static let blueGain: UInt8 = 0x1A
    static let input: UInt8 = 0x60
    static let sharpness: UInt8 = 0x87
    static let power: UInt8 = 0xD6
    static let pictureMode: UInt8 = 0xDC
    static let factoryReset: UInt8 = 0x04
    static let resetBrightnessContrast: UInt8 = 0x05
    static let resetColor: UInt8 = 0x08
}

/// Option lists come from the U2725QE capabilities string; names from the MCCS 2.1 spec.
private let choiceOptions: [UInt8: [(title: String, value: UInt16)]] = [
    VCP.colorPreset: [("sRGB", 0x01), ("5000K", 0x04), ("6500K", 0x05), ("7500K", 0x06),
                      ("9300K", 0x08), ("10000K", 0x09), ("User 1", 0x0B), ("User 2", 0x0C)],
    VCP.pictureMode: [("Standard", 0x00), ("Movie", 0x03), ("Game", 0x05)],
    VCP.input: [("USB-C / Thunderbolt", 0x19), ("DisplayPort", 0x0F), ("HDMI", 0x11)],
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let ddcQueue = DispatchQueue(label: "ddc")
    private var display: DDCDisplay?
    private var pendingWrites: [UInt8: UInt16] = [:]
    private var sliders: [UInt8: (slider: NSSlider, label: NSTextField)] = [:]
    private var choiceMenus: [UInt8: NSMenu] = [:]
    private let syncItem = NSMenuItem(title: "Sync with Built-in Display", action: nil, keyEquivalent: "")
    private var syncTimer: Timer?
    private let keysItem = NSMenuItem(title: "Enable Brightness Keys…", action: nil, keyEquivalent: "")
    private var keyTap: BrightnessKeyTap?
    private var permissionTimer: Timer?
    private var brightnessTarget: UInt16 = 0
    private var isAnimating = false
    private let hud = BrightnessHUD()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private var monitorPollTimer: Timer?
    private var lastLocalChange = Date.distantPast
    private var lastBuiltIn: Float?
    private var syncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "syncWithBuiltIn") }
        set { UserDefaults.standard.set(newValue, forKey: "syncWithBuiltIn") }
    }

    private var brightnessSlider: NSSlider { sliders[VCP.brightness]!.slider }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "External brightness")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "External Display", action: nil, keyEquivalent: ""))
        menu.addItem(sliderItem("Brightness", code: VCP.brightness))
        menu.addItem(sliderItem("Contrast", code: VCP.contrast))
        menu.addItem(.separator())
        menu.addItem(presetsItem())
        menu.addItem(choiceItem("Colour Preset", code: VCP.colorPreset))
        menu.addItem(choiceItem("Picture Mode", code: VCP.pictureMode))
        menu.addItem(choiceItem("Input Source", code: VCP.input))
        menu.addItem(submenuItem("Colour & Sharpness", items: [
            sliderItem("Red", code: VCP.redGain),
            sliderItem("Green", code: VCP.greenGain),
            sliderItem("Blue", code: VCP.blueGain),
            .separator(),
            sliderItem("Sharpness", code: VCP.sharpness),
        ]))
        menu.addItem(.separator())
        syncItem.target = self
        syncItem.action = #selector(toggleSync)
        menu.addItem(syncItem)
        keysItem.target = self
        keysItem.action = #selector(openAccessibilitySettings)
        menu.addItem(keysItem)
        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)
        menu.addItem(actionItem("Sleep Display", #selector(sleepDisplay)))
        menu.addItem(submenuItem("Reset", items: [
            actionItem("Reset Brightness & Contrast…", #selector(reset(_:)), tag: Int(VCP.resetBrightnessContrast)),
            actionItem("Reset Colour…", #selector(reset(_:)), tag: Int(VCP.resetColor)),
            actionItem("Factory Reset…", #selector(reset(_:)), tag: Int(VCP.factoryReset)),
        ]))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refresh()
        updateSync()
        setUpBrightnessKeys()
        updateLoginItem()
        startMonitorPolling()
    }

    // MARK: - Launch at login

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        updateLoginItem()
    }

    private func updateLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Monitor button changes

    private func startMonitorPolling() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.pollMonitorBrightness() }
        RunLoop.main.add(timer, forMode: .common)
        monitorPollTimer = timer
    }

    /// Picks up brightness changes made with the monitor's own buttons.
    private func pollMonitorBrightness() {
        ddcQueue.async { [weak self] in
            guard let self else { return }
            if self.display == nil { self.display = DDCDisplay.externalDisplays().first }
            guard let reading = self.display?.read(VCP.brightness) else { return }
            DispatchQueue.main.async { self.applyMonitorBrightness(reading.current) }
        }
    }

    private func applyMonitorBrightness(_ value: UInt16) {
        // Skip readings that could predate a change made here.
        guard !isAnimating, pendingWrites[VCP.brightness] == nil, Date().timeIntervalSince(lastLocalChange) > 2,
              Int(value) != brightnessSlider.integerValue else { return }
        brightnessSlider.integerValue = Int(value)
        sliders[VCP.brightness]?.label.stringValue = "\(value)"
        guard syncEnabled, BuiltInBrightness.set(Float(value) / Float(brightnessSlider.maxValue)) else { return }
        lastBuiltIn = BuiltInBrightness.current()
    }

    // MARK: - Brightness keys

    private func setUpBrightnessKeys() {
        keyTap = BrightnessKeyTap(
            // With the built-in display on, leave the keys to macOS (sync, if enabled, carries the change over).
            // With the lid closed macOS ignores them, so they drive the external display instead.
            shouldIntercept: { BuiltInBrightness.current() == nil },
            onPress: { [weak self] direction, fine in self?.stepBrightness(up: direction == .up, fine: fine) }
        )
        if BrightnessKeyTap.isTrusted {
            startKeyTap()
            return
        }
        BrightnessKeyTap.promptForAccess()
        // macOS doesn't notify when access is granted, so poll until it is.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard BrightnessKeyTap.isTrusted else { return }
            self?.startKeyTap()
        }
    }

    private func startKeyTap() {
        guard keyTap?.start() == true else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        keysItem.isHidden = true
    }

    @objc private func openAccessibilitySettings() {
        BrightnessKeyTap.promptForAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func stepBrightness(up: Bool, fine: Bool) {
        let maxValue = brightnessSlider.maxValue
        let step = maxValue / (fine ? 64 : 16)
        let value = Int(min(max(brightnessSlider.doubleValue + (up ? step : -step), 0), maxValue).rounded())
        animateBrightness(to: UInt16(value))
        hud.show(Double(value) / maxValue)
    }

    /// Walks the external display to `target` one unit at a time so the change looks smooth.
    /// Calling again mid-animation just moves the target; the running walk picks it up.
    private func animateBrightness(to target: UInt16) {
        lastLocalChange = Date()
        let start = UInt16(brightnessSlider.integerValue)
        brightnessSlider.integerValue = Int(target)
        sliders[VCP.brightness]?.label.stringValue = "\(target)"
        brightnessTarget = target
        guard !isAnimating else { return }
        isAnimating = true

        ddcQueue.async { [weak self] in
            guard let self else { return }
            if self.display == nil { self.display = DDCDisplay.externalDisplays().first }
            var current = start
            while true {
                // Check and clear in one main-thread hop so a new target can't slip in between.
                let target: UInt16? = DispatchQueue.main.sync {
                    if self.brightnessTarget == current { self.isAnimating = false; return nil }
                    return self.brightnessTarget
                }
                guard let target else { return }
                current = current < target ? current + 1 : current - 1
                // Intermediate steps are sent once to keep the walk quick; the final value gets the usual retry.
                if self.display?.write(VCP.brightness, value: current, attempts: current == target ? 2 : 1) != true {
                    self.display = nil
                    DispatchQueue.main.sync { self.isAnimating = false }
                    return
                }
            }
        }
    }

    // MARK: - Menu construction

    private func sliderItem(_ title: String, code: UInt8) -> NSMenuItem {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.frame = NSRect(x: 18, y: 9, width: 74, height: 18)
        titleLabel.font = .systemFont(ofSize: 12)

        let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sliderChanged(_:)))
        slider.tag = Int(code)
        slider.isContinuous = true
        slider.frame = NSRect(x: 94, y: 6, width: 150, height: 24)

        let valueLabel = NSTextField(labelWithString: "–")
        valueLabel.frame = NSRect(x: 248, y: 9, width: 40, height: 18)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        [titleLabel, slider, valueLabel].forEach(view.addSubview)
        sliders[code] = (slider, valueLabel)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func choiceItem(_ title: String, code: UInt8) -> NSMenuItem {
        let items = choiceOptions[code]!.map { option in
            actionItem(option.title, #selector(choose(_:)), tag: Int(code) << 16 | Int(option.value))
        }
        let item = submenuItem(title, items: items)
        choiceMenus[code] = item.submenu
        return item
    }

    private func presetsItem() -> NSMenuItem {
        submenuItem("Brightness Presets", items: [0, 25, 50, 75, 100].map {
            actionItem("\($0)%", #selector(applyPreset(_:)), tag: $0)
        })
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let submenu = NSMenu()
        items.forEach(submenu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        let code = UInt8(sender.tag)
        let value = UInt16(sender.integerValue)
        sliders[code]?.label.stringValue = "\(value)"
        if code == VCP.brightness { userSetBrightness(value) } else { write(code, value) }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        brightnessSlider.integerValue = sender.tag
        sliders[VCP.brightness]?.label.stringValue = "\(sender.tag)"
        userSetBrightness(UInt16(sender.tag))
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let code = UInt8(sender.tag >> 16)
        let value = UInt16(sender.tag & 0xFFFF)
        showChoice(code, value)
        write(code, value)
    }

    @objc private func sleepDisplay() {
        write(VCP.power, 0x04)
    }

    @objc private func reset(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(sender.title.replacingOccurrences(of: "…", with: ""))?"
        alert.informativeText = "This changes the monitor's own settings and can't be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        write(UInt8(sender.tag), 1)
        ddcQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // MARK: - Built-in display sync

    @objc private func toggleSync() {
        syncEnabled.toggle()
        updateSync()
    }

    private func updateSync() {
        syncItem.state = syncEnabled ? .on : .off
        syncTimer?.invalidate()
        syncTimer = nil
        lastBuiltIn = nil
        guard syncEnabled else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.syncFromBuiltIn() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
        syncFromBuiltIn()
    }

    /// Mirrors the built-in display onto the external one whenever the built-in value changes.
    /// The other direction is handled in userSetBrightness.
    private func syncFromBuiltIn() {
        guard let builtIn = BuiltInBrightness.current() else { return }
        if let last = lastBuiltIn, abs(last - builtIn) < 0.005 { return }
        lastBuiltIn = builtIn
        let value = Int((Double(builtIn) * brightnessSlider.maxValue).rounded())
        animateBrightness(to: UInt16(value))
    }

    /// A brightness change made in this app: apply to the external display and, when syncing, the built-in one too.
    private func userSetBrightness(_ value: UInt16) {
        write(VCP.brightness, value)
        guard syncEnabled, BuiltInBrightness.set(Float(value) / Float(brightnessSlider.maxValue)) else { return }
        // Record what we just wrote so the sync timer doesn't echo it back.
        lastBuiltIn = BuiltInBrightness.current()
    }

    // MARK: - DDC

    private func write(_ code: UInt8, _ value: UInt16) {
        lastLocalChange = Date()
        // Coalesce per code: DDC writes are slow, so only the latest value for each setting gets sent.
        let alreadyQueued = pendingWrites[code] != nil
        pendingWrites[code] = value
        guard !alreadyQueued else { return }
        ddcQueue.async { [weak self] in
            guard let self else { return }
            let latest = DispatchQueue.main.sync { self.pendingWrites.removeValue(forKey: code) }
            guard let latest else { return }
            if self.display == nil { self.display = DDCDisplay.externalDisplays().first }
            if self.display?.write(code, value: latest) != true { self.display = nil }
        }
    }

    private func showChoice(_ code: UInt8, _ value: UInt16) {
        choiceMenus[code]?.items.forEach { $0.state = UInt16($0.tag & 0xFFFF) == value ? .on : .off }
    }

    private func refresh() {
        let codes = Array(sliders.keys) + Array(choiceMenus.keys)
        ddcQueue.async { [weak self] in
            guard let self else { return }
            // Re-discover each time so hot-plugging the monitor just works.
            self.display = DDCDisplay.externalDisplays().first
            var readings: [UInt8: (current: UInt16, max: UInt16)] = [:]
            for code in codes { readings[code] = self.display?.read(code) }
            let found = self.display != nil
            DispatchQueue.main.async { self.apply(readings, displayFound: found) }
        }
    }

    private func apply(_ readings: [UInt8: (current: UInt16, max: UInt16)], displayFound: Bool) {
        for (code, control) in sliders where pendingWrites[code] == nil && !(code == VCP.brightness && isAnimating) {
            control.slider.isEnabled = displayFound
            guard let reading = readings[code] else {
                control.label.stringValue = displayFound ? "?" : "N/A"
                continue
            }
            control.slider.maxValue = Double(reading.max)
            control.slider.integerValue = Int(reading.current)
            control.label.stringValue = "\(reading.current)"
        }
        for code in choiceMenus.keys where pendingWrites[code] == nil {
            guard let reading = readings[code] else { continue }
            // Dell reports the input in both bytes (e.g. 0x1919); the low byte is the input.
            showChoice(code, code == VCP.input ? reading.current & 0xFF : reading.current)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

import AppKit
import CryptoKit
import Foundation
import IOKit.hid
import MultipeerConnectivity
import ServiceManagement

private let nearcastGroupKey = "nearcastGroupID"

private typealias PowerSourceID = UnsafeMutableRawPointer
@_silgen_name("IOPSCreatePowerSource") private func IOPSCreatePowerSource(_ source: UnsafeMutablePointer<PowerSourceID?>) -> IOReturn
@_silgen_name("IOPSSetPowerSourceDetails") private func IOPSSetPowerSourceDetails(_ source: PowerSourceID, _ details: CFDictionary) -> IOReturn
@_silgen_name("IOPSReleasePowerSource") private func IOPSReleasePowerSource(_ source: PowerSourceID) -> IOReturn

private struct BatteryReading: Equatable {
    let percent: Int
    let isCharging: Bool
}

// MARK: - Device adapter
// To support another mouse, start here. The rest of the app only consumes
// BatteryReading and does not know the device's private HID protocol.
private enum DeviceAdapter {
    static let displayName = "京东京造 JZM5"
    static let appName = "京东京造 JZM5 电量"
    static let accessoryIdentifier = "JZM5-2.4G"
    static let deviceType = "Mouse"

    static let receiverVendorID = 0x362D
    static let receiverProductID = 0xD107
    static let accessoryProductID = 0xD20F
    static let usagePage = 0x008C
    static let usage = 0x0001

    static let outputReportID: CFIndex = 0xB3
    static let inputReportID: UInt32 = 0xB4
    static let reportLength = 64
    static let timeout: TimeInterval = 3

    // IOKit expects this device's Report ID at byte 0 as well as in the
    // IOHIDDeviceSetReport reportID argument. The WebHID payload begins at byte 1.
    static func makeQueryReport() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = UInt8(outputReportID)
        report[1] = 0x06
        return report
    }

    static func parse(reportID: UInt32, bytes: [UInt8]) -> BatteryReading? {
        guard reportID == inputReportID else { return nil }
        var payload = bytes
        if payload.first == UInt8(inputReportID) { payload.removeFirst() }
        guard payload.count > 19, payload[0] == 0x06 else { return nil }
        return BatteryReading(
            percent: Int(payload[19] & 0x7F),
            isCharging: (payload[19] & 0x80) != 0
        )
    }
}

private enum BridgeError: Error, CustomStringConvertible {
    case noReceiver, open(IOReturn), send(IOReturn), noResponse, powerSource(IOReturn)

    var description: String {
        switch self {
        case .noReceiver: return "未找到 \(DeviceAdapter.displayName) 接收器"
        case .open(let result): return "打开 HID 接收器失败：0x\(String(UInt32(bitPattern: result), radix: 16, uppercase: true))"
        case .send(let result): return "发送查询失败：0x\(String(UInt32(bitPattern: result), radix: 16, uppercase: true))"
        case .noResponse: return "\(Int(DeviceAdapter.timeout)) 秒内未收到有效电量回包"
        case .powerSource(let result): return "发布系统电源项失败：0x\(String(UInt32(bitPattern: result), radix: 16, uppercase: true))"
        }
    }
}

private final class PowerSource {
    private var source: PowerSourceID?

    init() throws {
        let result = IOPSCreatePowerSource(&source)
        guard result == kIOReturnSuccess, source != nil else { throw BridgeError.powerSource(result) }
    }

    deinit {
        if let source { _ = IOPSReleasePowerSource(source) }
    }

    func publish(_ reading: BatteryReading?) throws {
        let details: [String: Any] = [
            "Name": DeviceAdapter.displayName,
            "Type": "Accessory Source",
            "Power Source State": "Battery Power",
            "Transport Type": "USB",
            "Accessory Category": DeviceAdapter.deviceType,
            "Accessory Identifier": DeviceAdapter.accessoryIdentifier,
            "Vendor ID": DeviceAdapter.receiverVendorID,
            "Product ID": DeviceAdapter.accessoryProductID,
            "Is Charging": reading?.isCharging ?? false,
            "Is Present": reading != nil,
            "Current Capacity": reading?.percent ?? 0,
            "Max Capacity": 100
        ]
        guard let source else { throw BridgeError.powerSource(kIOReturnNoDevice) }
        let result = IOPSSetPowerSourceDetails(source, details as CFDictionary)
        guard result == kIOReturnSuccess else { throw BridgeError.powerSource(result) }
    }
}

private struct AirBatteryDevice: Encodable {
    let hasBattery: Bool
    let deviceID = DeviceAdapter.accessoryIdentifier
    let deviceType = DeviceAdapter.deviceType
    let deviceName = DeviceAdapter.displayName
    let deviceModel = DeviceAdapter.displayName
    let batteryLevel: Int
    let isCharging: Int
    let isCharged = false
    let isPaused = false
    let acPowered = false
    let isHidden = false
    let lowPower = false
    let parentName = ""
    let lastUpdate: Double
    let realUpdate = 0.0
}

private struct NearcastMessage: Encodable {
    let id: String
    let sender: String
    let command: String
    let content: String
}

private struct MultipeerEnvelope: Encodable {
    let type = "Data"
    let payload: Data
}

private final class NearcastSender: NSObject, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    private let groupID: String
    private let peer = MCPeerID(displayName: DeviceAdapter.displayName)
    private lazy var session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .none)
    private lazy var browser = MCNearbyServiceBrowser(peer: peer, serviceType: "airbattery-nc")
    private lazy var advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "airbattery-nc")
    private let requestRefresh: () -> Void
    private var latestReading: BatteryReading?
    private var lastSentReading: BatteryReading?

    init?(groupID: String, requestRefresh: @escaping () -> Void) {
        guard groupID.hasPrefix("nc-"), groupID.count >= 23 else { return nil }
        self.groupID = groupID
        self.requestRefresh = requestRefresh
        super.init()
        session.delegate = self
        browser.delegate = self
        advertiser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func update(_ reading: BatteryReading) {
        latestReading = reading
        _ = send(reading: reading, hasBattery: true, refresh: lastSentReading != reading)
    }

    @discardableResult
    func sendOffline() -> Bool {
        guard let reading = latestReading ?? lastSentReading else { return false }
        return send(reading: reading, hasBattery: false, refresh: false)
    }

    private func send(reading: BatteryReading, hasBattery: Bool, refresh: Bool) -> Bool {
        guard !session.connectedPeers.isEmpty else { return false }
        do {
            let device = AirBatteryDevice(hasBattery: hasBattery, batteryLevel: reading.percent, isCharging: reading.isCharging ? 1 : 0, lastUpdate: Date().timeIntervalSince1970)
            let devices = try JSONEncoder().encode([device])
            guard let json = String(data: devices, encoding: .utf8) else { return false }
            let key = Self.key(for: groupID)
            let sealed = try AES.GCM.seal(Data(json.utf8), using: key)
            guard let encrypted = sealed.combined?.base64EncodedString() else { return false }
            let message = NearcastMessage(id: String(groupID.prefix(15)), sender: DeviceAdapter.accessoryIdentifier, command: "", content: encrypted)
            let payload = try JSONEncoder().encode(message)
            let envelope = try JSONEncoder().encode(MultipeerEnvelope(payload: payload))
            try session.send(envelope, toPeers: session.connectedPeers, with: .reliable)
            if hasBattery { lastSentReading = reading }
            if refresh { requestRefresh() }
            return true
        } catch {
            NSLog("Nearcast 发送失败：\(error)")
            return false
        }
    }

    private static func key(for groupID: String) -> SymmetricKey {
        let password = String(groupID.dropFirst(15).prefix(8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
            salt: Data(groupID.prefix(15).utf8),
            info: Data(),
            outputByteCount: 32
        )
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) { NSLog("Nearcast 浏览失败：\(error)") }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) { NSLog("Nearcast 广播失败：\(error)") }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard state == .connected else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let reading = self.latestReading else { return }
            _ = self.send(reading: reading, hasBattery: true, refresh: true)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private final class QueryState {
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    var reading: BatteryReading?

    init() { buffer.initialize(repeating: 0, count: 256) }
    deinit { buffer.deinitialize(count: 256); buffer.deallocate() }
}

private func number(_ device: IOHIDDevice, _ key: CFString) -> Int? {
    guard let value = IOHIDDeviceGetProperty(device, key), CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
    return (value as! NSNumber).intValue
}

private let inputCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
    guard let context else { return }
    let state = Unmanaged<QueryState>.fromOpaque(context).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    guard let reading = DeviceAdapter.parse(reportID: reportID, bytes: bytes) else { return }
    state.reading = reading
}

private func readBattery() throws -> BatteryReading {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [
        kIOHIDVendorIDKey as String: DeviceAdapter.receiverVendorID,
        kIOHIDProductIDKey as String: DeviceAdapter.receiverProductID
    ] as CFDictionary)
    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard managerResult == kIOReturnSuccess else { throw BridgeError.open(managerResult) }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let receiver = devices.first(where: {
        number($0, kIOHIDPrimaryUsagePageKey as CFString) == DeviceAdapter.usagePage &&
        number($0, kIOHIDPrimaryUsageKey as CFString) == DeviceAdapter.usage
    }) else { throw BridgeError.noReceiver }
    let openResult = IOHIDDeviceOpen(receiver, IOOptionBits(kIOHIDOptionsTypeNone))
    guard openResult == kIOReturnSuccess else { throw BridgeError.open(openResult) }
    defer { IOHIDDeviceClose(receiver, IOOptionBits(kIOHIDOptionsTypeNone)) }

    let state = QueryState()
    let retained = Unmanaged.passRetained(state)
    defer { retained.release() }
    IOHIDDeviceRegisterInputReportCallback(receiver, state.buffer, 256, inputCallback, retained.toOpaque())
    IOHIDDeviceScheduleWithRunLoop(receiver, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    defer { IOHIDDeviceUnscheduleFromRunLoop(receiver, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }

    let request = DeviceAdapter.makeQueryReport()
    let result = request.withUnsafeBytes {
        IOHIDDeviceSetReport(receiver, kIOHIDReportTypeOutput, DeviceAdapter.outputReportID, $0.bindMemory(to: UInt8.self).baseAddress!, request.count)
    }
    guard result == kIOReturnSuccess else { throw BridgeError.send(result) }

    let deadline = Date().addingTimeInterval(DeviceAdapter.timeout)
    while state.reading == nil && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let reading = state.reading else { throw BridgeError.noResponse }
    return reading
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var powerSource: PowerSource?
    private var nearcast: NearcastSender?
    private var lastReading: BatteryReading?
    private var launchItem: NSMenuItem?
    private var permissionItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        menu.delegate = self
        let permission = NSMenuItem(title: permissionTitle, action: #selector(requestInputMonitoring), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        permissionItem = permission
        let launch = NSMenuItem(title: "开机启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)
        launchItem = launch
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: DeviceAdapter.appName)
        statusItem.button?.image?.isTemplate = true

        startNearcastIfConfigured()
        DispatchQueue.main.async { [weak self] in self?.updateBattery() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.lastReading == nil else { return }
            self.updateBattery()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateBattery() }
    }

    private var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    private var inputMonitoringGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    private var permissionTitle: String { inputMonitoringGranted ? "输入监控授权（已授权）" : "输入监控授权…" }

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = permissionTitle
        permissionItem?.isEnabled = !inputMonitoringGranted
        launchItem?.state = launchAtLoginEnabled ? .on : .off
    }

    @objc private func requestInputMonitoring() {
        guard !inputMonitoringGranted else { return }
        if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) { return }

        let alert = NSAlert()
        alert.messageText = "需要输入监控权限"
        alert.informativeText = "请在系统设置的“隐私与安全性 → 输入监控”中允许 \(DeviceAdapter.appName)。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后处理")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            launchItem?.state = launchAtLoginEnabled ? .on : .off
        } catch { present(error) }
    }

    private func updateBattery() {
        do {
            let reading = try readBattery()
            lastReading = reading
            if powerSource == nil { powerSource = try PowerSource() }
            try powerSource?.publish(reading)
            startNearcastIfConfigured()
            nearcast?.update(reading)
        } catch {
            NSLog("\(DeviceAdapter.appName): \(error)")
        }
    }

    private func startNearcastIfConfigured() {
        guard nearcast == nil,
              let groupID = UserDefaults.standard.string(forKey: nearcastGroupKey),
              let sender = NearcastSender(groupID: groupID, requestRefresh: refreshAirBattery) else { return }
        nearcast = sender
        sender.start()
        if let lastReading { sender.update(lastReading) }
    }

    private func refreshAirBattery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.openAirBatteryRefresh()
        }
    }

    private func openAirBatteryRefresh() {
        guard let url = URL(string: "airbattery://reloadwingets") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { NSLog("AirBattery 后台刷新失败：\(error)") }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard nearcast?.sendOffline() == true else { return }
        Thread.sleep(forTimeInterval: 0.3)
        openAirBatteryRefresh()
    }

    private func present(_ error: Error) {
        NSLog("\(DeviceAdapter.appName): \(error)")
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

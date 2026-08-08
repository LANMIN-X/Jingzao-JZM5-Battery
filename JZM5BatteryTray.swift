import AppKit
import CryptoKit
import Foundation
import IOKit.hid
import MultipeerConnectivity
import ServiceManagement

private let vendorID = 0x362D
private let productID = 0xD107
private let productDisplayName = "京东京造 JZM5"
private let appName = "京东京造 JZM5 电量"
private let lastBatteryKey = "lastBattery"
private let lastChargingKey = "lastCharging"
private let nearcastGroupKey = "nearcastGroupID"

private typealias PowerSourceID = UnsafeMutableRawPointer
@_silgen_name("IOPSCreatePowerSource") private func IOPSCreatePowerSource(_ source: UnsafeMutablePointer<PowerSourceID?>) -> IOReturn
@_silgen_name("IOPSSetPowerSourceDetails") private func IOPSSetPowerSourceDetails(_ source: PowerSourceID, _ details: CFDictionary) -> IOReturn
@_silgen_name("IOPSReleasePowerSource") private func IOPSReleasePowerSource(_ source: PowerSourceID) -> IOReturn

private struct BatteryReading: Equatable {
    let percent: Int
    let isCharging: Bool
}

private enum BridgeError: Error, CustomStringConvertible {
    case noReceiver, open(IOReturn), send(IOReturn), noResponse, powerSource(IOReturn)

    var description: String {
        switch self {
        case .noReceiver: return "未找到 JZ M5 2.4G 接收器"
        case .open(let result): return "打开 HID 接收器失败：0x\(String(UInt32(bitPattern: result), radix: 16, uppercase: true))"
        case .send(let result): return "发送查询失败：0x\(String(UInt32(bitPattern: result), radix: 16, uppercase: true))"
        case .noResponse: return "3 秒内未收到 B4/06 电量回包"
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
            "Name": productDisplayName,
            "Type": "Accessory Source",
            "Power Source State": "Battery Power",
            "Transport Type": "USB",
            "Accessory Category": "Mouse",
            "Accessory Identifier": "JZM5-2.4G",
            "Vendor ID": vendorID,
            "Product ID": 0xD20F,
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
    let deviceID = "JZM5-2.4G"
    let deviceType = "Mouse"
    let deviceName = productDisplayName
    let deviceModel = productDisplayName
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
    private let peer = MCPeerID(displayName: "京东京造 JZM5")
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
            let message = NearcastMessage(id: String(groupID.prefix(15)), sender: "JZM5-2.4G", command: "", content: encrypted)
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
    guard let context, reportID == 0xB4 else { return }
    let state = Unmanaged<QueryState>.fromOpaque(context).takeUnretainedValue()
    var bytes = Array(UnsafeBufferPointer(start: report, count: length))
    if bytes.first == 0xB4 { bytes.removeFirst() }
    guard bytes.count > 19, bytes[0] == 0x06 else { return }
    state.reading = BatteryReading(percent: Int(bytes[19] & 0x7F), isCharging: (bytes[19] & 0x80) != 0)
}

private func readJZM5Battery() throws -> BatteryReading {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey as String: vendorID, kIOHIDProductIDKey as String: productID] as CFDictionary)
    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard managerResult == kIOReturnSuccess else { throw BridgeError.open(managerResult) }
    defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let receiver = devices.first(where: {
        number($0, kIOHIDPrimaryUsagePageKey as CFString) == 0x008C && number($0, kIOHIDPrimaryUsageKey as CFString) == 0x0001
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

    var request = [UInt8](repeating: 0, count: 64)
    request[0] = 0xB3
    request[1] = 0x06
    let result = request.withUnsafeBytes {
        IOHIDDeviceSetReport(receiver, kIOHIDReportTypeOutput, 0xB3, $0.bindMemory(to: UInt8.self).baseAddress!, request.count)
    }
    guard result == kIOReturnSuccess else { throw BridgeError.send(result) }

    let deadline = Date().addingTimeInterval(3)
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
        statusItem.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: appName)
        statusItem.button?.image?.isTemplate = true

        do {
            powerSource = try PowerSource()
            if let battery = UserDefaults.standard.object(forKey: lastBatteryKey) as? Int {
                lastReading = BatteryReading(percent: battery, isCharging: UserDefaults.standard.integer(forKey: lastChargingKey) == 1)
                try powerSource?.publish(lastReading)
            }
        } catch { present(error) }
        startNearcastIfConfigured()
        DispatchQueue.main.async { [weak self] in self?.updateBattery() }
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
        alert.informativeText = "请在系统设置的“隐私与安全性 → 输入监控”中允许 JZ M5 电量。"
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
            let reading = try readJZM5Battery()
            lastReading = reading
            UserDefaults.standard.set(reading.percent, forKey: lastBatteryKey)
            UserDefaults.standard.set(reading.isCharging ? 1 : 0, forKey: lastChargingKey)
            try powerSource?.publish(reading)
            startNearcastIfConfigured()
            nearcast?.update(reading)
        } catch {
            NSLog("\(appName): \(error)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.open(URL(string: "airbattery://reloadwingets")!)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard nearcast?.sendOffline() == true else { return }
        Thread.sleep(forTimeInterval: 0.3)
        NSWorkspace.shared.open(URL(string: "airbattery://reloadwingets")!)
    }

    private func present(_ error: Error) {
        NSLog("\(appName): \(error)")
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

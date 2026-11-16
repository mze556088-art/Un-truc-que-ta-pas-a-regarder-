//  DeviceInfo.swift — infos appareil en temps réel + pont vers le widget
import UIKit
import WidgetKit

enum WidgetBridge {
    static let suite = "group.com.aura.personal"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }
    private static var lastReload = Date.distantPast

    static func nowPlaying(title: String?, artist: String?, playing: Bool) {
        defaults?.set(title, forKey: "title"); defaults?.set(artist, forKey: "artist"); defaults?.set(playing, forKey: "playing")
        reload(force: true)
    }
    static func device(battery: Double, charging: Bool) {
        defaults?.set(battery, forKey: "battery"); defaults?.set(charging, forKey: "charging")
        reload(force: false)
    }
    private static func reload(force: Bool) {
        guard force || Date().timeIntervalSince(lastReload) > 300 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor
final class DeviceInfoModel: ObservableObject {
    struct Snapshot {
        var modelName = "", identifier = "", systemVersion = "", build = "", deviceName = "", vendorID = ""
        var totalDisk: Int64 = 0, freeDisk: Int64 = 0
        var battery: Float = -1
        var batteryState: UIDevice.BatteryState = .unknown
        var lowPower = false
        var ramTotal: UInt64 = 0, ramApp: UInt64 = 0, ramSystem: UInt64 = 0
    }
    @Published private(set) var snap = Snapshot()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let d = UIDevice.current
        var s = Snapshot()
        s.identifier = Self.machine()
        s.modelName = Self.marketingName(s.identifier)
        s.systemVersion = "\(d.systemName) \(d.systemVersion)"
        s.build = Self.sysctlString("kern.osversion")
        s.deviceName = d.name
        s.vendorID = d.identifierForVendor?.uuidString ?? "—"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.totalDisk = Int64(v.volumeTotalCapacity ?? 0)
            s.freeDisk = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        s.battery = d.batteryLevel
        s.batteryState = d.batteryState
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.ramTotal = ProcessInfo.processInfo.physicalMemory
        s.ramApp = Self.appFootprint()
        s.ramSystem = Self.systemUsed()
        snap = s
        if s.battery >= 0 { WidgetBridge.device(battery: Double(s.battery), charging: s.batteryState == .charging || s.batteryState == .full) }
    }

    // MARK: Helpers système
    private static func machine() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname(); uname(&u)
        return withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "—" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func appFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func systemUsed() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * UInt64(pageSize)
    }

    private static func marketingName(_ id: String) -> String {
        let table: [String: String] = [
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
            "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2e gén.)", "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3e gén.)", "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air"
        ]
        return table[id] ?? id   // identifiant brut si le modèle est plus récent que cette table
    }
}

import CoreFoundation
import IOKit.ps

/// The internal battery from IOPowerSources (the same source as the menu bar battery item).
enum PowerSource {
    /// nil when there is no internal battery, or it is not present (desktop Macs, a removed
    /// battery), or powerd does not answer.
    static func internalBattery() -> HostSample.Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let source = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() else { continue }
            guard string(description, kIOPSTypeKey) == kIOPSInternalBatteryType,
                  bool(description, kIOPSIsPresentKey) ?? true else { continue }
            guard let current = int(description, kIOPSCurrentCapacityKey) else { continue }
            // Apple Silicon reports percent with max 100; older models report mAh-like units.
            let maximum = int(description, kIOPSMaxCapacityKey) ?? 100
            let percent = maximum > 0 ? Int((Double(current) * 100 / Double(maximum)).rounded()) : current
            return HostSample.Battery(
                percent: min(100, max(0, percent)),
                charging: bool(description, kIOPSIsChargingKey) ?? false,
                onAC: string(description, kIOPSPowerSourceStateKey) == kIOPSACPowerValue)
        }
        return nil
    }

    // CFDictionary lookups without bridging the whole description to a Swift dictionary.

    private static func value(_ dictionary: CFDictionary, _ key: String) -> CFTypeRef? {
        let cfKey = key as CFString
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(cfKey).toOpaque()) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func string(_ dictionary: CFDictionary, _ key: String) -> String? {
        guard let v = value(dictionary, key), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }

    private static func bool(_ dictionary: CFDictionary, _ key: String) -> Bool? {
        guard let v = value(dictionary, key), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    private static func int(_ dictionary: CFDictionary, _ key: String) -> Int? {
        guard let v = value(dictionary, key), CFGetTypeID(v) == CFNumberGetTypeID() else { return nil }
        var result: Int64 = 0
        guard CFNumberGetValue((v as! CFNumber), .sInt64Type, &result) else { return nil }
        return Int(result)
    }
}

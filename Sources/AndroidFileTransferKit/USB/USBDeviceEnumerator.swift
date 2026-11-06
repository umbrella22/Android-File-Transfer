import Foundation
import IOKit
import IOUSBHost

/// One-shot enumeration of MTP/PTP interfaces in the IORegistry.
///
/// The `service` field is a retained IOKit object handle. `IOUSBHostTransport`
/// consumes it when opening; if a caller enumerates without opening, it should
/// call `IOObjectRelease(service)` when done.
public enum USBDeviceEnumerator {
    public static func findMTPInterfaces() -> [USBMTPInterface] {
        var results: [USBMTPInterface] = []
        var seen = Set<UInt32>()

        // Most Android devices expose the Still Image class with the PTP
        // protocol. Some devices leave the subclass/protocol unspecified, so
        // fall back progressively instead of relying on a single match.
        let filters: [(Int?, Int?, Int?)] = [
            (6, 1, 1),
            (6, 1, nil),
            (6, nil, nil),
        ]

        for (interfaceClass, subclass, proto) in filters {
            for service in matchingServices(
                interfaceClass: interfaceClass,
                interfaceSubclass: subclass,
                interfaceProtocol: proto
            ) {
                guard seen.insert(service).inserted else {
                    IOObjectRelease(service)
                    continue
                }
                if let info = describe(service: service) {
                    results.append(info)
                } else {
                    IOObjectRelease(service)
                }
            }
        }

        return results
    }

    /// Debug helper: every USB interface visible to IOUSBHost, regardless of
    /// class. Useful when a device does not match the MTP filters.
    public static func findAllInterfaces() -> [USBMTPInterface] {
        var results: [USBMTPInterface] = []
        for service in matchingServices(
            interfaceClass: nil,
            interfaceSubclass: nil,
            interfaceProtocol: nil
        ) {
            if let info = describe(service: service) {
                results.append(info)
            } else {
                IOObjectRelease(service)
            }
        }
        return results
    }

    public static func describe(service: io_service_t) -> USBMTPInterface? {
        guard let vendorID = numberProperty(service, "idVendor"),
              let productID = numberProperty(service, "idProduct")
        else {
            return nil
        }

        return USBMTPInterface(
            service: service,
            vendorID: vendorID,
            productID: productID,
            manufacturer: stringProperty(service, "USB Vendor Name"),
            product: stringProperty(service, "USB Product Name"),
            serialNumber: stringProperty(service, "USB Serial Number"),
            interfaceNumber: numberProperty(service, "bInterfaceNumber") ?? -1,
            configurationValue: numberProperty(service, "bConfigurationValue") ?? -1,
            interfaceClass: numberProperty(service, "bInterfaceClass") ?? -1,
            interfaceSubclass: numberProperty(service, "bInterfaceSubClass") ?? -1,
            interfaceProtocol: numberProperty(service, "bInterfaceProtocol") ?? -1,
            locationID: numberProperty(service, "locationID").map(UInt32.init)
        )
    }

    private static func matchingServices(
        interfaceClass: Int?,
        interfaceSubclass: Int?,
        interfaceProtocol: Int?
    ) -> [UInt32] {
        let dictionary = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: interfaceClass.map(NSNumber.init(value:)),
            interfaceSubclass: interfaceSubclass.map(NSNumber.init(value:)),
            interfaceProtocol: interfaceProtocol.map(NSNumber.init(value:)),
            speed: nil,
            productIDArray: nil
        ).takeRetainedValue()

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator)
        guard result == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [UInt32] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    private static func numberProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let value = property(service, key) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = property(service, key) else { return nil }
        return value as? String
    }

    private static func property(_ service: io_service_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}

//
//  DiskStore.swift
//  eul
//
//  Created by Gao Sun on 2020/11/1.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import IOKit
import SharedLibrary
import SwiftUI

class DiskStore: ObservableObject, Refreshable {
    private var activeCancellable: AnyCancellable?

    @ObservedObject var componentsStore = SharedStore.components
    @ObservedObject var menuComponentsStore = SharedStore.menuComponents
    var config: EulComponentConfig {
        SharedStore.componentConfig[EulComponent.Disk]
    }

    @Published var list: DiskList?

    var selectedDisk: DiskList.Disk? {
        guard config.diskSelection != "" else {
            return nil
        }
        return list?.disks.filter { $0.name == config.diskSelection }.first
    }

    var ceilingBytes: UInt64? {
        selectedDisk?.size ?? list?.disks.reduce(0) { $0 + $1.size }
    }

    var freeBytes: UInt64? {
        selectedDisk?.freeSize ?? list?.disks.reduce(0) { $0 + $1.freeSize }
    }

    var usageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling - free, kilo: 1000).readable
    }

    var usagePercentageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return (Double(ceiling - free) / Double(ceiling)).percentageString
    }

    var freeString: String {
        guard let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(free, kilo: 1000).readable
    }

    var totalString: String {
        guard let ceiling = ceilingBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling, kilo: 1000).readable
    }

    // MARK: - NVMe Temperature Query

    /// Get NVMe disk temperature using IOKit
    /// - Returns: Temperature in Celsius, or nil if unavailable
    func getNVMeTemperature() -> Double? {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IONVMeController")
        guard let matching = matchDict else { return nil }

        // Use compatible port for macOS 10.15+
        var mainPort: mach_port_t = 0
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        }

        guard IOServiceGetMatchingServices(mainPort, matching, &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let props = properties?.takeRetainedValue() as? [String: Any] {
                // Try to get temperature from properties
                // NVMe SMART data often contains temperature in "Temperature" key
                if let temp = props["Temperature"] as? Double, temp > 0 && temp < 150 {
                    IOObjectRelease(service)
                    return temp
                }
                // Check for nested properties
                if let smartData = props["SMARTData"] as? [String: Any],
                   let temp = smartData["Temperature"] as? Double, temp > 0 && temp < 150 {
                    IOObjectRelease(service)
                    return temp
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return nil
    }

    @objc func refresh() {
        guard
            componentsStore.activeComponents.contains(.Disk)
            || menuComponentsStore.activeComponents.contains(.Disk)
        else {
            return
        }

        // Get NVMe temperature once per refresh
        let nvmeTemperature = getNVMeTemperature()

        guard let volumes = (try? FileManager.default.contentsOfDirectory(atPath: DiskList.volumesPath)) else {
            list = nil
            return
        }

        list = DiskList(disks: volumes.compactMap {
            if $0.starts(with: ".") || $0.contains("com.apple") { return nil }

            let path = DiskList.pathForName($0)
            let url = URL(fileURLWithPath: path)

            guard
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
                let size = attributes[FileAttributeKey.systemSize] as? UInt64,
                let freeSize = attributes[FileAttributeKey.systemFreeSize] as? UInt64
            else {
                return nil
            }

            let isEjectable = !((try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? false)

            return DiskList.Disk(
                name: $0,
                size: size,
                freeSize: freeSize,
                isEjectable: isEjectable,
                temperature: nvmeTemperature
            )
        })
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        // refresh immediately to prevent "N/A"
        activeCancellable = Publishers
            .CombineLatest(componentsStore.$activeComponents, menuComponentsStore.$activeComponents)
            .sink { _ in
                DispatchQueue.main.async {
                    self.refresh()
                }
            }
    }
}

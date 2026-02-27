//
//  GPU.swift
//  eul
//
//  Created by Gao Sun on 2021/1/23.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

struct GPU: Identifiable {
    var deviceId: String
    var model: String?
    var vendor: String?
    var cores: Int?

    var id: String {
        deviceId
    }
}

extension GPU {
    struct Statistic {
        var pciMatch: String
        var usagePercentage: Int
        var temperature: Double?
        var coreClock: Int?
        var memoryClock: Int?
    }
}

extension GPU {
    static func getGPUs() -> [GPU]? {
        guard let data = shellData(["system_profiler SPDisplaysDataType -xml"]) else {
            return nil
        }

        let pListDecoder = PropertyListDecoder()
        guard let plistArray = try? pListDecoder.decode(SystemProfilerPlistArray.self, from: data) else {
            return nil
        }

        return plistArray.first?.items.compactMap { item -> GPU? in
            guard item.isGPU, let deviceId = item.resolvedDeviceId else {
                return nil
            }
            return GPU(
                deviceId: deviceId,
                model: item.model,
                vendor: item.vendor,
                cores: Int(item.cores ?? "")
            )
        }
    }

    static func getInfo() -> [Statistic]? {
        guard let propertyList = IOHelper.getPropertyList(for: kIOAcceleratorClassName) else {
            return nil
        }

        var results: [Statistic] = []
        
        for props in propertyList {
            guard let statistics = props["PerformanceStatistics"] as? [String: Any] else {
                continue
            }
            
            let usagePercentage = statistics["Device Utilization %"] as? Int 
                ?? statistics["GPU Activity(%)"] as? Int 
                ?? 0
            
            let pciMatch = props["IOPCIMatch"] as? String 
                ?? props["IOPCIPrimaryMatch"] as? String 
                ?? "apple-silicon-gpu"
            
            let temp = statistics["Temperature(C)"] as? Double ?? SmcControl.shared.gpuProximityTemperature
            
            results.append(Statistic(
                pciMatch: pciMatch,
                usagePercentage: usagePercentage,
                temperature: temp,
                coreClock: statistics["Core Clock(MHz)"] as? Int,
                memoryClock: statistics["Memory Clock(MHz)"] as? Int
            ))
        }
        
        return results.isEmpty ? nil : results
    }
}

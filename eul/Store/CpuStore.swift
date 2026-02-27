//
//  CpuStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SystemKit
import WidgetKit

class CpuStore: ObservableObject, Refreshable {
    @Published var temp: Double?
    @Published var usageCPU: (system: Double, user: Double, idle: Double, nice: Double)?
    @Published var loadAverage: [Double]?
    @Published var physicalCores = 0
    @Published var logicalCores = 0
    @Published var upTime: (days: Int, hrs: Int, mins: Int, secs: Int)?
    @Published var thermalLevel: System.ThermalLevel = .Unknown
    @Published var usageHistory: [Double] = []
    
    // Per-core data
    @Published var coreUsages: [Double] = []
    @Published var coreTemps: [Double] = []
    @Published var coreLabels: [String] = []  // e.g., "E0", "P0", "P1"
    
    // Previous CPU tick values for calculating per-core usage
    private var prevCoreTicks: [[Int]] = []
    
    // P-core and E-core counts
    private var pCoreCount = 0
    private var eCoreCount = 0

    var loadAverage1MinString: String {
        formatDouble(loadAverage?[safe: 0])
    }

    var loadAverage5MinString: String {
        formatDouble(loadAverage?[safe: 1])
    }

    var loadAverage15MinString: String {
        formatDouble(loadAverage?[safe: 2])
    }

    var usageString: String {
        guard let usage = usageCPU else {
            return "N/A"
        }
        return String(format: "%.0f%%", usage.system + usage.user)
    }

    var usage: Double? {
        guard let usageCPU = usageCPU else {
            return nil
        }
        return usageCPU.system + usageCPU.user
    }

    private func formatDouble(_ value: Double?) -> String {
        guard let value = value else {
            return "N/A"
        }
        return String(format: "%.2f", value)
    }

    private func getInfo() {
        physicalCores = System.physicalCores()
        logicalCores = System.logicalCores()
        upTime = System.uptime()
        thermalLevel = System.thermalLevel()
        
        // Get P-core and E-core counts (Apple Silicon only)
        #if arch(arm64)
        pCoreCount = getSysctlInt("hw.perflevel0.physicalcpu")
        eCoreCount = getSysctlInt("hw.perflevel1.physicalcpu")
        #endif
    }
    
    private func getSysctlInt(_ name: String) -> Int {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private func getUsage() {
        let usage = Info.system.usageCPU()
        usageCPU = usage
        loadAverage = System.loadAverage()
        usageHistory = (usageHistory + [usage.system + usage.user]).suffix(LineChart.defaultMaxPointCount)
        coreUsages = getPerCoreUsage()
    }
    
    private func getPerCoreUsage() -> [Double] {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUsU: natural_t = 0
        
        let err = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &numCpuInfo
        )
        
        guard err == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return []
        }
        
        var currentTicks: [[Int]] = []
        var usages: [Double] = []
        var labels: [String] = []
        
        let totalCores = Int(numCPUsU)
        
        for i in 0..<totalCores {
            let offset = Int32(CPU_STATE_MAX) * Int32(i)
            
            let user = Int(cpuInfo[Int(offset + Int32(CPU_STATE_USER))])
            let system = Int(cpuInfo[Int(offset + Int32(CPU_STATE_SYSTEM))])
            let idle = Int(cpuInfo[Int(offset + Int32(CPU_STATE_IDLE))])
            let nice = Int(cpuInfo[Int(offset + Int32(CPU_STATE_NICE))])
            
            currentTicks.append([user, system, idle, nice])
            
            // Generate core label (E-cores first, then P-cores on Apple Silicon)
            #if arch(arm64)
            if i < eCoreCount {
                labels.append("E\(i)")
            } else {
                labels.append("P\(i - eCoreCount)")
            }
            #else
            labels.append("C\(i)")
            #endif
            
            // Calculate usage from delta if we have previous data
            if i < prevCoreTicks.count {
                let prev = prevCoreTicks[i]
                let dUser = user - prev[0]
                let dSystem = system - prev[1]
                let dIdle = idle - prev[2]
                let dNice = nice - prev[3]
                
                let dTotal = dUser + dSystem + dIdle + dNice
                if dTotal > 0 {
                    let usage = Double(dUser + dSystem + dNice) / Double(dTotal) * 100
                    usages.append(usage)
                } else {
                    usages.append(0)
                }
            } else {
                // First call, no previous data - show 0
                usages.append(0)
            }
        }
        
        // Save current ticks and labels for next calculation
        prevCoreTicks = currentTicks
        coreLabels = labels
        
        let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        
        return usages
    }

    private func getTemp() {
        temp = (SmcControl.shared.cpuDieTemperature ?? 0) > 0
            ? SmcControl.shared.cpuDieTemperature
            : SmcControl.shared.cpuProximityTemperature
        
        #if arch(arm64)
        coreTemps = getPerCoreTemps()
        #endif
    }
    
    #if arch(arm64)
    private func getPerCoreTemps() -> [Double] {
        guard let sensors = AppleSiliconSensors.shared?.getAllTemperatures() else {
            return []
        }
        let tdieSensors = sensors.filter { $0.name.hasPrefix("PMU tdie") || $0.name.hasPrefix("PMU2 tdie") }
        return tdieSensors.map { $0.temperature }
    }
    #endif

    @objc func refresh() {
        getInfo()
        getUsage()
        getTemp()
        writeToContainer()
    }

    func writeToContainer() {
        Container.set(CpuEntry(
            temp: temp,
            usageSystem: usageCPU?.system,
            usageUser: usageCPU?.user,
            usageNice: usageCPU?.nice
        ))
        if #available(OSX 11, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: CpuEntry.kind)
        }
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
    }
}

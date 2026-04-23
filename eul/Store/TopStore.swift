//
//  TopStore.swift
//  eul
//
//  Created by Jevon Mao on 1/22/21.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Combine
import SwiftUI
import SystemKit

// TO-DO: extract store logic

// MARK: Instance

class TopStore: ObservableObject {
    private var memorySizeMB = System.physicalMemory() * 1000
    private var ramTask: Process?
    private var cpuTask: Process?
    private var cpuActiveCancellable: AnyCancellable?
    private var ramActiveCancellable: AnyCancellable?
    private var ramFirstLoaded = false
    private var cpuFirstLoaded = false

    @ObservedObject var preferenceStore = SharedStore.preference
    @Published var cpuDataAvailable = false
    @Published var ramDataAvailable = false
    @Published var cpuTopProcesses: [ProcessCpuUsage] = []
    @Published var ramTopProcesses: [RamUsage] = []

    private func terminateProcess(_ process: Process?, completion: @escaping () -> Void) {
        guard let process = process else {
            completion()
            return
        }
        
        process.terminate()
        
        // Wait for process to exit in background, then call completion on main queue
        DispatchQueue.global(qos: .background).async {
            // Wait up to 1 second for process to terminate
            let timeout = 1.0
            let startTime = Date()
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    print("⚠️ Process did not terminate in time")
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func updateRAM(shouldStart: Bool) {
        guard shouldStart else {
            if let task = ramTask {
                ramTask = nil  // Prevent re-entrant call
                terminateProcess(task) { [weak self] in
                    self?.ramTask = nil
                }
            }
            return
        }

        if ramTask != nil {
            Print("ram task already started")
            return
        }

        let refreshRate = preferenceStore.smcRefreshRate
        ramFirstLoaded = false
        ramDataAvailable = false
        ramTopProcesses = []

        // MARK: Parsing command for RAM top processes

        parseTerminalCommand(taskType: .ram, commandString: "top -l 0 -n 6 -stats pid,command,rsize -s \(refreshRate) -orsize") { separatorIndex, rows, titleRow in
            if titleRow.contains("pid"), titleRow.contains("mem"), titleRow.contains("command") {
                let runningApps = NSWorkspace.shared.runningApplications
                let result: [RamUsage] = ((separatorIndex + 2)..<rows.count).compactMap { index in
                    let row = rows[index].split(separator: " ").map { String($0) }
                    guard row.count >= 2, let pid = Int(row[0]), let rawRamString = row.last, let ram = Double(rawRamString.filter("0123456789.".contains)), pid != 0 else {
                        return nil
                    }

                    let usage = 100 * (ram / self.memorySizeMB)

                    return RamUsage(
                        pid: pid,
                        command: Info.getProcessCommand(pid: pid)!,
                        value: usage,
                        usageAmount: ram,
                        runningApp: runningApps.first(where: { $0.processIdentifier == pid })
                    )
                }
                DispatchQueue.main.async { [self] in
                    ramTopProcesses = result.count <= 5 ? result.dropLast(0) : result.dropLast(1)
                    if !ramFirstLoaded {
                        ramFirstLoaded = true
                    } else if !ramDataAvailable {
                        ramDataAvailable = true
                    }
                }
            }
        }
    }

    func updateCPU(shouldStart: Bool) {
        guard shouldStart else {
            if let task = cpuTask {
                cpuTask = nil  // Prevent re-entrant call
                terminateProcess(task) { [weak self] in
                    self?.cpuTask = nil
                }
            }
            return
        }

        if cpuTask != nil {
            Print("cpu task already started")
            return
        }

        let refreshRate = preferenceStore.smcRefreshRate
        cpuFirstLoaded = false
        cpuDataAvailable = false
        cpuTopProcesses = []

        // MARK: Parsing command for CPU top processes

        parseTerminalCommand(taskType: .cpu, commandString: "top -l 0 -u -n 5 -stats pid,cpu,command -s \(refreshRate)") { separatorIndex, rows, titleRow in
            if titleRow.contains("pid"), titleRow.contains("cpu"), titleRow.contains("command") {
                let runningApps = NSWorkspace.shared.runningApplications
                let result: [ProcessCpuUsage] = ((separatorIndex + 2)..<rows.count).compactMap { index in
                    let row = rows[index].split(separator: " ").map { String($0) }
                    guard row.count >= 3, let pid = Int(row[0]), let cpu = Double(row[1]), cpu >= 0.1 else {
                        return nil
                    }
                    return ProcessCpuUsage(
                        pid: pid,
                        command: Info.getProcessCommand(pid: pid) ?? row[2],
                        value: cpu,
                        runningApp: runningApps.first(where: { $0.processIdentifier == pid })
                    )
                }

                Print("CPU top is updating")
                DispatchQueue.main.async { [self] in
                    cpuTopProcesses = result
                    if !cpuFirstLoaded {
                        cpuFirstLoaded = true
                    } else if !cpuDataAvailable {
                        cpuDataAvailable = true
                    }
                }
            }
        }
    }

    init() {
        cpuActiveCancellable = Publishers
            .CombineLatest3(
                preferenceStore.$showCPUTopActivities,
                SharedStore.menuComponents.$activeComponents,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 && $1.contains(.CPU) && $2
            }
            .sink { [self] shouldStart in
                DispatchQueue.main.async {
                    updateCPU(shouldStart: shouldStart)
                }
            }

        ramActiveCancellable = Publishers
            .CombineLatest3(
                preferenceStore.$showRAMTopActivities,
                SharedStore.menuComponents.$activeComponents,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 && $1.contains(.Memory) && $2
            }
            .sink { [self] shouldStart in
                DispatchQueue.main.async {
                    updateRAM(shouldStart: shouldStart)
                }
            }
    }
}

// MARK: Private Methods

extension TopStore {
    private func parseTerminalCommand(taskType: TaskType, commandString: String, completion: @escaping (Int, [String], String) -> Void) {
        let task = shellPipe(commandString) { string in
            let rows = string.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

            guard let separatorIndex = rows.firstIndex(of: "") else {
                return
            }

            if rows.indices.contains(separatorIndex + 1) {
                let titleRow = rows[separatorIndex + 1].lowercased()
                completion(separatorIndex, rows, titleRow)
            }
        }
        switch taskType {
        case .cpu:
            cpuTask = task
        case .ram:
            ramTask = task
        }
    }
}

// MARK: Types

extension TopStore {
    enum TaskType {
        case cpu
        case ram
    }
}

//
//  NetworkTopStore.swift
//  eul
//
//  Created by Gao Sun on 2020/10/17.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

class NetworkTopStore: ObservableObject {
    struct NetworkSpeed: CustomStringConvertible {
        var inSpeedInByte: Double = 0
        var outSpeedInByte: Double = 0

        var totalSpeedInByte: Double {
            inSpeedInByte + outSpeedInByte
        }

        var description: String {
            fatalError("not implemented")
        }
    }

    struct ProcessNetworkUsage: ProcessUsage {
        typealias T = NetworkSpeed
        let pid: Int
        let command: String
        let value: NetworkSpeed
        let runningApp: NSRunningApplication?
    }

    private var timer: Timer?
    private var activeCancellable: AnyCancellable?
    private var lastTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var lastInBytes: [Int: Double] = [:]
    private var lastOutBytes: [Int: Double] = [:]
    @ObservedObject var preferenceStore = SharedStore.preference
    @Published var processes: [ProcessNetworkUsage] = []

    private var interval: Int {
        preferenceStore.networkRefreshRate
    }

    var totalSpeed: NetworkSpeed {
        processes.reduce(into: NetworkSpeed()) { result, usage in
            result.inSpeedInByte += usage.value.inSpeedInByte
            result.outSpeedInByte += usage.value.outSpeedInByte
        }
    }

    private func run() {
        guard let string = shell("nettop -L 1 -P -x -J bytes_in,bytes_out") else {
            print("unable to fetch network activity, please make sure nettop is available")
            return
        }

        let rows = string.split(separator: "\n").map { String($0) }
        let headers = rows[0]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0.lowercased()) }
        let processIndex = 0

        guard
            let inBytesIndex = headers.firstIndex(of: "bytes_in"),
            let outBytesIndex = headers.firstIndex(of: "bytes_out")
        else {
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let time = Date().timeIntervalSince1970
        let timeElapsed = time - lastTimestamp
        lastTimestamp = time

        Print("network top is updating")
        processes = rows.dropFirst().compactMap { row in
            let cols = row.split(separator: ",").map { String($0) }

            guard
                cols.indices.contains(processIndex),
                cols.indices.contains(inBytesIndex),
                cols.indices.contains(outBytesIndex)
            else {
                return nil
            }

            let processCol = cols[processIndex]
            let splitted = processCol.split(separator: ".").map { String($0) }

            guard
                let last = splitted.last,
                let pid = Int(last),
                let inBytes = Double(cols[inBytesIndex]),
                let outBytes = Double(cols[outBytesIndex])
            else {
                return nil
            }

            let lastIn = lastInBytes[pid]
            let lastOut = lastOutBytes[pid]

            lastInBytes[pid] = inBytes
            lastOutBytes[pid] = outBytes

            if lastIn == nil, lastOut == nil {
                return nil
            }

            let speed = NetworkSpeed(
                inSpeedInByte: lastIn.map { $0 > inBytes ? 0 : (inBytes - $0) / timeElapsed } ?? 0,
                outSpeedInByte: lastOut.map { $0 > outBytes ? 0 : (outBytes - $0) / timeElapsed } ?? 0
            )

            guard speed.totalSpeedInByte >= 100 else {
                return nil
            }

            return ProcessNetworkUsage(
                pid: pid,
                command: Info.getProcessCommand(pid: pid) ?? splitted[0],
                value: speed,
                runningApp: runningApps.first(where: { $0.processIdentifier == pid })
            )
        }
        .sorted(by: { $0.value.totalSpeedInByte > $1.value.totalSpeedInByte })
        
        // MARK: - Cleanup stale PIDs
        // Get current active PIDs from the results
        let currentPids = Set(processes.map { $0.pid })
        // Remove PIDs that are no longer active
        lastInBytes = lastInBytes.filter { currentPids.contains($0.key) }
        lastOutBytes = lastOutBytes.filter { currentPids.contains($0.key) }
        
        // Clear old data periodically to prevent memory buildup
        if lastInBytes.count > 1000 {
            // If dictionary gets too large, clear stale entries
            lastInBytes.removeAll()
            lastOutBytes.removeAll()
            print("⚠️ Cleared stale network PID data to prevent memory leak")
        }
    }

    func update(shouldStart: Bool) {
        guard shouldStart else {
            // Properly invalidate timer
            if let timer = timer {
                timer.invalidate()
                self.timer = nil
            }
            
            // Clear dictionaries to prevent memory buildup
            lastInBytes.removeAll()
            lastOutBytes.removeAll()
            processes = []
            return
        }

        if timer != nil {
            Print("network task already started")
            return
        }

        lastInBytes.removeAll()
        lastOutBytes.removeAll()
        lastTimestamp = Date().timeIntervalSince1970
        processes = []

        let timer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true) { _ in
            self.run()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    init() {
        activeCancellable = Publishers
            .CombineLatest3(
                preferenceStore.$showNetworkTopActivities,
                SharedStore.menuComponents.$activeComponents,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 && $1.contains(.Network) && $2
            }
            .sink { [self] shouldStart in
                DispatchQueue.main.async {
                    update(shouldStart: shouldStart)
                }
            }
    }
}

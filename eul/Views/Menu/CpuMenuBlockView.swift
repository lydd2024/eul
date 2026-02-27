//
//  CpuMenuBlockView.swift
//  eul
//
//  Created by Gao Sun on 2020/9/20.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

struct CpuMenuBlockView: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var cpuTopStore: TopStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Text("component.cpu".localized())
                    .menuSection()
                Spacer()
                if preferenceStore.cpuMenuDisplay == .usagePercentage {
                    Text(cpuStore.usageString)
                        .displayText()
                }
                LineChart(points: cpuStore.usageHistory, frame: CGSize(width: 35, height: 20))
            }
            cpuStore.usageCPU.map { usageCPU in
                Group {
                    SeparatorView()
                    HStack {
                        if preferenceStore.cpuMenuDisplay == .usagePercentage {
                            MiniSectionView(title: "cpu.system", value: String(format: "%.1f%%", usageCPU.system))
                            Spacer()
                            MiniSectionView(title: "cpu.user", value: String(format: "%.1f%%", usageCPU.user))
                            Spacer()
                            MiniSectionView(title: "cpu.nice", value: String(format: "%.1f%%", usageCPU.nice))
                        }
                        if preferenceStore.cpuMenuDisplay == .loadAverage {
                            MiniSectionView(title: "1 min", value: cpuStore.loadAverage1MinString)
                            Spacer()
                            MiniSectionView(title: "5 min", value: cpuStore.loadAverage5MinString)
                            Spacer()
                            MiniSectionView(title: "15 min", value: cpuStore.loadAverage15MinString)
                        }
                        cpuStore.temp.map { temp in
                            Group {
                                Spacer()
                                MiniSectionView(title: "cpu.temperature", value: SmcControl.shared.formatTemp(temp))
                            }
                        }
                    }
                }
            }
            
            // Per-core display
            if !cpuStore.coreUsages.isEmpty {
                SeparatorView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("cpu.cores".localized())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(cpuStore.coreUsages.enumerated()), id: \.offset) { index, usage in
                        HStack {
                            // Core label with P/E indicator
                            Text(cpuStore.coreLabels.indices.contains(index) ? cpuStore.coreLabels[index] : "C\(index)")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 30, alignment: .leading)
                                .foregroundColor(coreLabelColor(index: index))
                            
                            // Usage bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(height: 8)
                                    
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(usageColor(usage))
                                        .frame(width: geometry.size.width * CGFloat(usage / 100), height: 8)
                                }
                            }
                            .frame(height: 8)
                            
                            Text(String(format: "%.0f%%", usage))
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 40, alignment: .trailing)
                            
                            // Temperature for this core (if available)
                            if index < cpuStore.coreTemps.count {
                                let temp = cpuStore.coreTemps[index]
                                Text(String(format: "%.0f°C", temp))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(minWidth: 280)
            }
            
            if preferenceStore.showCPUTopActivities {
                SeparatorView()
                VStack(spacing: 8) {
                    ForEach(cpuTopStore.cpuTopProcesses) {
                        ProcessRowView(section: "cpu", process: $0)
                    }
                    if !cpuTopStore.cpuDataAvailable {
                        Spacer()
                        Text("cpu.waiting_status_report".localized())
                            .secondaryDisplayText()
                        Spacer()
                    }
                }
                .frame(minWidth: 311)
                .frame(height: 102) // fix size to avoid jitter in menu view
            }
        }
        .menuBlock()
    }
    
    private func usageColor(_ usage: Double) -> Color {
        if usage > 80 {
            return .red
        } else if usage > 50 {
            return .orange
        } else {
            return .green
        }
    }
    
    private func coreLabelColor(index: Int) -> Color {
        guard cpuStore.coreLabels.indices.contains(index) else {
            return .primary
        }
        let label = cpuStore.coreLabels[index]
        if label.hasPrefix("P") {
            return .blue  // P-cores in blue
        } else if label.hasPrefix("E") {
            return .green  // E-cores in green
        }
        return .primary
    }
}

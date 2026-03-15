//
//  DiskMenuBlockView.swift
//  eul
//
//  Created by Gao Sun on 2021/1/23.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

struct DiskRowView: View {
    @EnvironmentObject var diskStore: DiskStore
    @State private var isEjecting = false

    var disk: DiskList.Disk

    var usagePercentage: Double {
        guard disk.size > 0 else { return 0 }
        return Double(disk.size - disk.freeSize) / Double(disk.size) * 100
    }

    private func usageColor(_ usage: Double) -> Color {
        if usage > 90 {
            return .red
        } else if usage > 70 {
            return .orange
        } else {
            return .green
        }
    }

    private func ejectDisk() {
        isEjecting = true
        DispatchQueue.global().async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: disk.path, isDirectory: true))
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = error.localizedDescription
                    alert.alertStyle = .informational
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
            DispatchQueue.main.async {
                self.isEjecting = false
                self.diskStore.refresh()
            }
        }
    }

    var body: some View {
        HStack {
            Text(disk.name)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 50, alignment: .leading)
                .lineLimit(1)

            if disk.isEjectable {
                if isEjecting {
                    ActivityIndicatorView {
                        $0.style = .spinning
                        $0.controlSize = .mini
                        $0.startAnimation(nil)
                    }
                } else {
                    MenuActionButtonView(
                        id: "disk-\(disk.name)-eject",
                        imageName: "Eject",
                        toolTip: "disk.eject"
                    ) {
                        ejectDisk()
                    }
                }
            }

            // Usage bar (CPU core style)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(usageColor(usagePercentage))
                        .frame(width: geometry.size.width * CGFloat(usagePercentage / 100), height: 8)
                }
            }
            .frame(height: 8)
            .frame(maxWidth: 100)

            Text(String(format: "%.0f%%", usagePercentage))
                .font(.system(size: 10, weight: .medium))
                .frame(width: 40, alignment: .trailing)

            // Temperature
            if let temp = disk.temperature {
                Text(SmcControl.shared.formatTemp(temp))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            } else {
                Text("N/A")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}

struct DiskMenuBlockView: View {
    @EnvironmentObject var diskStore: DiskStore

    var body: some View {
        VStack(spacing: 8) {
            Text("component.disk".localized())
                .menuSection()
            if let list = diskStore.list {
                ForEach(list.disks) {
                    DiskRowView(disk: $0)
                }
            } else {
                Text("N/A".localized())
                    .placeholder()
                    .padding(.bottom, 4)
            }
        }
        .padding(.top, 2)
        .menuBlock()
    }
}

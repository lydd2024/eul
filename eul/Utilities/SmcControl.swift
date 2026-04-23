//
//  SmcControl.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SwiftyJSON

class SmcControl: Refreshable {
    static var shared = SmcControl()

    var sensors: [TemperatureData] = []
    var fans: [FanData] = []
    var tempUnit: TemperatureUnit = .celius

    var cpuDieTemperature: Double? {
        #if arch(arm64)
        // Apple Silicon: Use IOHID sensors
        return AppleSiliconSensors.shared?.cpuTemperature
        #else
        // Intel: Use SMC
        return sensors.first(where: { $0.sensor.name == "CPU_0_DIE" })?.temp
        #endif
    }

    var cpuProximityTemperature: Double? {
        #if arch(arm64)
        // Apple Silicon: Fallback to CPU temperature
        return AppleSiliconSensors.shared?.cpuTemperature
        #else
        // Intel: Use SMC
        return sensors.first(where: { $0.sensor.name == "CPU_0_PROXIMITY" })?.temp
        #endif
    }

    var gpuProximityTemperature: Double? {
        #if arch(arm64)
        // Apple Silicon: Use IOHID GPU sensors
        return AppleSiliconSensors.shared?.gpuTemperature
        #else
        // Intel: Use SMC
        return sensors.first(where: { $0.sensor.name == "GPU_0_PROXIMITY" })?.temp
        #endif
    }

    var memoryProximityTemperature: Double? {
        #if arch(arm64)
        // Apple Silicon: Use SOC temperature as approximation
        return AppleSiliconSensors.shared?.socTemperature
        #else
        // Intel: Use SMC
        return sensors.first(where: { $0.sensor.name == "MEM_SLOTS_PROXIMITY" })?.temp
        #endif
    }

    var isFanValid: Bool {
        fans.count > 0
    }

    func formatTemp(_ value: Double) -> String {
        String(format: "%.0f°\(tempUnit == .celius ? "C" : "F")", value)
    }

    init() {
        #if arch(arm64)
        // Apple Silicon: Use IOHID sensors only, no SMC
        print("Apple Silicon detected - using IOHID sensors")
		AppleSiliconSensors.initialize()
        #else
        // Intel: Use SMC for everything
        do {
            try SMCKit.open()
            sensors = try SMCKit.allKnownTemperatureSensors().map { .init(sensor: $0) }
            fans = try (0..<SMCKit.fanCount()).map { FanData(
                id: $0,
                minSpeed: try? SMCKit.fanMinSpeed($0),
                maxSpeed: try? SMCKit.fanMaxSpeed($0)
            ) }
        } catch {
            print("SMC init error", error)
        }
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func subscribe() {
        initObserver(for: .SMCShouldRefresh)
    }

    func close() {
        #if arch(arm64)
        // No SMC to close on Apple Silicon
        #else
        SMCKit.close()
        #endif
    }

    @objc func refresh() {
        #if arch(arm64)
        // Apple Silicon: Temperature is fetched on-demand from AppleSiliconSensors
        #else
        // Intel: Use SMC
        for sensor in sensors {
            do {
                sensor.temp = try SMCKit.temperature(sensor.sensor.code, unit: tempUnit)
            } catch {
                sensor.temp = 0
                print("error while getting temperature", error)
            }
        }
        fans = fans.map {
            FanData(
                id: $0.id,
                currentSpeed: try? SMCKit.fanCurrentSpeed($0.id),
                minSpeed: $0.minSpeed,
                maxSpeed: $0.maxSpeed
            )
        }
        #endif
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .StoreShouldRefresh, object: nil)
        }
    }
}

extension TemperatureUnit {
    var description: String {
        switch self {
        case .celius:
            return "temp.celsius".localized()
        case .fahrenheit:
            return "temp.fahrenheit".localized()
        case .kelvin:
            return "temp.kelvin".localized()
        }
    }
}

extension Fan: JSONCodabble {
    init?(json: JSON) {
        guard
            let id = json["id"].int,
            let name = json["name"].string,
            let minSpeed = json["id"].int,
            let maxSpeed = json["id"].int
        else {
            return nil
        }
        self.id = id
        self.name = name
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
    }

    var json: JSON {
        JSON([
            "id": id,
            "name": name,
            "minSpeed": minSpeed,
            "maxSpeed": maxSpeed,
        ])
    }
}

extension Double {
    var temperatureString: String {
        SmcControl.shared.formatTemp(self)
    }
}

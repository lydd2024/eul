//
//  AppleSiliconSensors.swift
//  eul
//
//  Created for Apple Silicon temperature monitoring
//

import Foundation
import Darwin

// MARK: - IOHID Type Aliases
typealias IOHIDEventSystemClient = UnsafeMutableRawPointer
typealias IOHIDServiceClient = UnsafeMutableRawPointer
typealias IOHIDEvent = UnsafeMutableRawPointer

typealias IOHIDEventSystemClientCreateFunc = @convention(c) (CFAllocator?) -> IOHIDEventSystemClient?
typealias IOHIDEventSystemClientSetMatchingFunc = @convention(c) (IOHIDEventSystemClient?, CFDictionary?) -> Void
typealias IOHIDEventSystemClientCopyServicesFunc = @convention(c) (IOHIDEventSystemClient) -> CFArray?
typealias IOHIDServiceClientCopyEventFunc = @convention(c) (IOHIDServiceClient, Int64, Int32, Int64) -> IOHIDEvent?
typealias IOHIDEventGetFloatValueFunc = @convention(c) (IOHIDEvent, UInt32) -> Double
typealias IOHIDServiceClientCopyPropertyFunc = @convention(c) (IOHIDServiceClient, CFString) -> CFString?

// MARK: - Apple Silicon Temperature Sensor
struct AppleSiliconSensorReading {
    let name: String
    let temperature: Double
}

// MARK: - Apple Silicon Sensors Manager
class AppleSiliconSensors {
    static var shared: AppleSiliconSensors?
    
    // HID Constants
    private let kIOHIDEventTypeTemperature: Int32 = 15
    private let kHIDPage_AppleVendor: Int32 = 0xff00
    private let kHIDUsage_AppleVendor_TemperatureSensor: Int32 = 0x0005
    
    // Dynamically loaded functions
    private let eventSystemClientCreate: IOHIDEventSystemClientCreateFunc
    private let eventSystemClientSetMatching: IOHIDEventSystemClientSetMatchingFunc
    private let eventSystemClientCopyServices: IOHIDEventSystemClientCopyServicesFunc
    private let serviceClientCopyEvent: IOHIDServiceClientCopyEventFunc
    private let eventGetFloatValue: IOHIDEventGetFloatValueFunc
    private let serviceClientCopyProperty: IOHIDServiceClientCopyPropertyFunc
    
    // Cached client and services to avoid memory leaks
    private var systemClient: IOHIDEventSystemClient?
    private var cachedServices: [IOHIDServiceClient] = []
    private var dlopenHandle: UnsafeMutableRawPointer?
    
    private init?() {
        // Load IOKit framework
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            print("AppleSiliconSensors: Failed to load IOKit framework")
            return nil
        }
        self.dlopenHandle = handle
        
        // Load required functions
        guard let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(handle, "IOHIDEventGetFloatValue"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty") else {
            print("AppleSiliconSensors: Failed to load required functions")
            dlclose(handle)
            return nil
        }
        
        self.eventSystemClientCreate = unsafeBitCast(create, to: IOHIDEventSystemClientCreateFunc.self)
        self.eventSystemClientSetMatching = unsafeBitCast(setMatching, to: IOHIDEventSystemClientSetMatchingFunc.self)
        self.eventSystemClientCopyServices = unsafeBitCast(copyServices, to: IOHIDEventSystemClientCopyServicesFunc.self)
        self.serviceClientCopyEvent = unsafeBitCast(copyEvent, to: IOHIDServiceClientCopyEventFunc.self)
        self.eventGetFloatValue = unsafeBitCast(getFloat, to: IOHIDEventGetFloatValueFunc.self)
        self.serviceClientCopyProperty = unsafeBitCast(copyProperty, to: IOHIDServiceClientCopyPropertyFunc.self)
        
        // Initialize client and cache services
        initializeClient()
    }
    
    private func initializeClient() {
        let dict: NSMutableDictionary = [
            "PrimaryUsagePage": kHIDPage_AppleVendor,
            "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor
        ]
        
        guard let client = eventSystemClientCreate(kCFAllocatorDefault) else {
            print("AppleSiliconSensors: Failed to create event system client")
            return
        }
        self.systemClient = client
        eventSystemClientSetMatching(client, dict as CFDictionary)
        
        guard let services = eventSystemClientCopyServices(client) else {
            print("AppleSiliconSensors: Failed to copy services")
            return
        }
        
        // Cache service clients
        let count = CFArrayGetCount(services)
        for i in 0..<count {
            let servicePtr = CFArrayGetValueAtIndex(services, i)
            let service = unsafeBitCast(servicePtr, to: IOHIDServiceClient.self)
            cachedServices.append(service)
        }
        
        print("AppleSiliconSensors: Cached \(cachedServices.count) sensor services")
    }
    
    // Initialize shared instance
    static func initialize() {
        shared = AppleSiliconSensors()
        if let sensors = shared?.getAllTemperatures(), !sensors.isEmpty {
            print("AppleSiliconSensors: Ready - found \(sensors.count) sensors")
        } else {
            print("AppleSiliconSensors: Warning - no sensors found")
        }
    }
    
    // MARK: - Public API
    
    /// Get all temperature sensor readings
    func getAllTemperatures() -> [AppleSiliconSensorReading] {
        var results: [AppleSiliconSensorReading] = []
        
        for service in cachedServices {
            guard let event = serviceClientCopyEvent(service, Int64(kIOHIDEventTypeTemperature), 0, 0),
                  let nameCF = serviceClientCopyProperty(service, "Product" as CFString),
                  let name = nameCF as String? else {
                continue
            }
            
            let value = eventGetFloatValue(event, UInt32(kIOHIDEventTypeTemperature << 16))
            
            // Filter invalid values (temperature should be between 0 and 150°C)
            if value > 0 && value < 150 {
                results.append(AppleSiliconSensorReading(name: name, temperature: value))
            }
        }
        
        return results.sorted { $0.name < $1.name }
    }
    
    /// Get CPU temperature (average of PMU tdie sensors)
    var cpuTemperature: Double? {
        let sensors = getAllTemperatures()
        
        // Apple Silicon uses PMU tdie sensors for CPU/GPU temperature
        // PMU tdie1-14 are the main temperature sensors
        let cpuSensors = sensors.filter { sensor in
            sensor.name.hasPrefix("PMU tdie")
        }
        
        if cpuSensors.isEmpty {
            // Fallback: use PMU2 tdie sensors
            let pmu2Sensors = sensors.filter { $0.name.hasPrefix("PMU2 tdie") }
            if !pmu2Sensors.isEmpty {
                let avg = pmu2Sensors.map { $0.temperature }.reduce(0, +) / Double(pmu2Sensors.count)
                return avg
            }
            return nil
        }
        
        let avgTemp = cpuSensors.map { $0.temperature }.reduce(0, +) / Double(cpuSensors.count)
        return avgTemp
    }
    
    /// Get GPU temperature (same as CPU on Apple Silicon, shared die)
    var gpuTemperature: Double? {
        return cpuTemperature
    }
    
    /// Get SOC (System on Chip) temperature - same as CPU on Apple Silicon
    var socTemperature: Double? {
        return cpuTemperature
    }
    
    /// Check if running on Apple Silicon
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    
    deinit {
        // Clean up dlopen handle
        if let handle = dlopenHandle {
            dlclose(handle)
        }
    }
}

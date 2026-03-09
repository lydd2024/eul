import Foundation
import Darwin

// Use CoreFoundation's CFRelease directly (available via Foundation)

// MARK: - HID 类型

typealias IOHIDEventSystemClient = UnsafeMutableRawPointer
typealias IOHIDServiceClient = UnsafeMutableRawPointer
typealias IOHIDEvent = UnsafeMutableRawPointer

typealias IOHIDEventSystemClientCreateFunc =
@convention(c) (CFAllocator?) -> IOHIDEventSystemClient?

typealias IOHIDEventSystemClientSetMatchingFunc =
@convention(c) (IOHIDEventSystemClient?, CFDictionary?) -> Void

typealias IOHIDEventSystemClientCopyServicesFunc =
@convention(c) (IOHIDEventSystemClient) -> Unmanaged<CFArray>?

typealias IOHIDServiceClientCopyEventFunc =
@convention(c) (IOHIDServiceClient, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?

typealias IOHIDEventGetFloatValueFunc =
@convention(c) (IOHIDEvent, UInt32) -> Double

typealias IOHIDServiceClientCopyPropertyFunc =
@convention(c) (IOHIDServiceClient, CFString) -> Unmanaged<CFTypeRef>?

// Event-driven APIs
typealias IOHIDEventSystemClientScheduleWithRunLoopFunc = @convention(c) (IOHIDEventSystemClient, CFRunLoop?, CFString?) -> Void
typealias IOHIDEventSystemClientEventCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
typealias IOHIDEventSystemClientRegisterEventCallbackFunc = @convention(c) (IOHIDEventSystemClient, IOHIDEventSystemClientEventCallback?, UnsafeMutableRawPointer?) -> Void

// MARK: - 数据模型

struct AppleSiliconSensorReading {
    let name: String
    let temperature: Double
}

private struct SensorService {
    let service: IOHIDServiceClient
    let name: String
}

// MARK: - Apple Silicon Sensors Manager

final class AppleSiliconSensors {

    // Keep shared optional so callers can use optional chaining without changing many call sites
    // Use a failable factory so missing symbols or dlopen failures don't crash the app.
    static let shared: AppleSiliconSensors? = AppleSiliconSensors.createIfAvailable()

    // Allow explicit initialization from other modules
    static func initialize() {
        _ = AppleSiliconSensors.shared
    }

    // Factory that attempts to create an instance and returns nil on any failure.
    private static func createIfAvailable() -> AppleSiliconSensors? {
        return AppleSiliconSensors()
    }

    // HID 常量
    private let temperatureEventType: Int32 = 15
    private let vendorPage: Int32 = 0xff00
    private let temperatureUsage: Int32 = 0x0005

    // 动态加载函数 (optional so we can fail gracefully)
    private let createClient: IOHIDEventSystemClientCreateFunc?
    private let setMatching: IOHIDEventSystemClientSetMatchingFunc?
    private let copyServices: IOHIDEventSystemClientCopyServicesFunc?
    private let copyEvent: IOHIDServiceClientCopyEventFunc?
    private let getFloat: IOHIDEventGetFloatValueFunc?
    private let copyProperty: IOHIDServiceClientCopyPropertyFunc?
    private let scheduleWithRunLoop: IOHIDEventSystemClientScheduleWithRunLoopFunc?
    private let registerEventCallback: IOHIDEventSystemClientRegisterEventCallbackFunc?

    private var client: IOHIDEventSystemClient?
    private var sensors: [SensorService] = []
    private var dlHandle: UnsafeMutableRawPointer?
    // Cached latest readings and synchronization
    private let readingsQueue = DispatchQueue(label: "com.eul.applesilicon.readings")
    private var cachedReadings: [AppleSiliconSensorReading] = []
    private var lastReadTimestamp: TimeInterval = 0
    private let minReadInterval: TimeInterval = 1.0 // seconds
    // Event-driven buffering and runloop thread
    private var eventBuffer: [(service: IOHIDServiceClient, temperature: Double)] = []
    private let eventBufferCapacity: Int = 256
    private var runLoopThread: Thread?

    // MARK: 初始化

    // Failable initializer (returns nil on any dlopen/dlsym failure)
    private init?() {

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        dlHandle = handle

        func load<T>(_ name: String, _ type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(sym, to: type)
        }

        // Attempt to load all required symbols. If any are missing, bail out safely.
        guard let c = load("IOHIDEventSystemClientCreate", IOHIDEventSystemClientCreateFunc.self),
              let s = load("IOHIDEventSystemClientSetMatching", IOHIDEventSystemClientSetMatchingFunc.self),
              let cs = load("IOHIDEventSystemClientCopyServices", IOHIDEventSystemClientCopyServicesFunc.self),
              let ce = load("IOHIDServiceClientCopyEvent", IOHIDServiceClientCopyEventFunc.self),
              let gf = load("IOHIDEventGetFloatValue", IOHIDEventGetFloatValueFunc.self),
              let cp = load("IOHIDServiceClientCopyProperty", IOHIDServiceClientCopyPropertyFunc.self)
        else {
            // Close handle if we couldn't load all symbols
            if let h = dlHandle { dlclose(h) }
            dlHandle = nil
            return nil
        }

        // Assign loaded symbols
        createClient = c
        setMatching = s
        copyServices = cs
        copyEvent = ce
        getFloat = gf
        copyProperty = cp

        // Optional event-driven symbols. If missing we'll continue using polling.
        scheduleWithRunLoop = load("IOHIDEventSystemClientScheduleWithRunLoop", IOHIDEventSystemClientScheduleWithRunLoopFunc.self)
        registerEventCallback = load("IOHIDEventSystemClientRegisterEventCallback", IOHIDEventSystemClientRegisterEventCallbackFunc.self)

        initializeSensors()
        // If event APIs are available, we intentionally do NOT register the callback
        // automatically here because the callback ABI for private IOHID APIs can vary
        // between OS versions and may cause crashes if the signature does not match.
        // Keep the function pointers available so callers or future changes can opt-in
        // to event-driven mode safely. For now we continue using the polling fallback.
        // Successful init
    }

    // MARK: 初始化传感器

    private func initializeSensors() {

        guard let createClient = createClient,
              let setMatching = setMatching,
              let copyServices = copyServices else { return }

        guard let client = createClient(kCFAllocatorDefault) else { return }
        self.client = client

        let match: NSDictionary = [
            "PrimaryUsagePage": vendorPage,
            "PrimaryUsage": temperatureUsage
        ]
        setMatching(client, match)

        guard let servicesUn = copyServices(client) else { return }
        let services = servicesUn.takeRetainedValue()
        let count = CFArrayGetCount(services)

        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: ptr)

            // 获取传感器名字
            guard let copyProperty = copyProperty,
                  let nameUn = copyProperty(service, "Product" as CFString) else { continue }

            // takeRetainedValue to claim ownership and bridge to CFTypeRef
            let nameCF = nameUn.takeRetainedValue()

            // CFTypeRef -> CFString -> String 桥接
            let name: String
            if CFGetTypeID(nameCF) == CFStringGetTypeID(), let str = nameCF as? String {
                name = str
            } else {
                name = "Unknown"
            }
            sensors.append(SensorService(service: service, name: name))
        }

        // services is a CFArray returned by copyServices; ownership transferred via takeRetainedValue
        print("AppleSiliconSensors: detected \(sensors.count) sensors")
    }

    // MARK: 读取所有温度

    func readAll() -> [AppleSiliconSensorReading] {
        // Throttle reads to at most once per minReadInterval to avoid frequent allocations
        let now = Date().timeIntervalSince1970
        var snapshot: [AppleSiliconSensorReading] = []

        readingsQueue.sync {
            if now - lastReadTimestamp < minReadInterval {
                snapshot = cachedReadings
                return
            }
        }

        var results: [AppleSiliconSensorReading] = []

        for sensor in sensors {
            autoreleasepool {
                // Ensure copyEvent function pointer exists before calling
                guard let copyEvent = copyEvent else { return }
                guard let eventUn = copyEvent(sensor.service,
                                              Int64(temperatureEventType),
                                              0,
                                              0) else { return }

                // copyEvent follows 'Copy' semantics -> takeRetainedValue to claim ownership
                let eventCF = eventUn.takeRetainedValue()
                // Bridge CFTypeRef -> opaque pointer without changing ownership
                let eventPtr = Unmanaged.passUnretained(eventCF as AnyObject).toOpaque()

                guard let getFloat = getFloat else { return }
                let value = getFloat(eventPtr, UInt32(temperatureEventType << 16))
                // eventCF is now managed by ARC after takeRetainedValue()
                if value > 0 && value < 150 {
                    results.append(AppleSiliconSensorReading(name: sensor.name, temperature: value))
                }
            }
        }

        readingsQueue.sync {
            cachedReadings = results
            lastReadTimestamp = now
            snapshot = cachedReadings
        }

        return snapshot
    }

    // Backwards-compatible API used by existing call sites
    // Kept as instance method to match usage: AppleSiliconSensors.shared?.getAllTemperatures()
    func getAllTemperatures() -> [AppleSiliconSensorReading] {
        return readAll()
    }

    // MARK: CPU 平均温度

    // CPU average temperature (computed property for compatibility with callers)
    var cpuTemperature: Double? {
        let temps = readAll()
        let cpuSensors = temps.filter { $0.name.hasPrefix("PMU tdie") || $0.name.lowercased().contains("cpu") }
        guard !cpuSensors.isEmpty else { return nil }
        return cpuSensors.map { $0.temperature }.reduce(0, +) / Double(cpuSensors.count)
    }

    // GPU temperature if available
    var gpuTemperature: Double? {
        let temps = readAll()
        let gpuSensors = temps.filter { $0.name.lowercased().contains("gpu") || $0.name.hasPrefix("GPU") }
        guard !gpuSensors.isEmpty else { return nil }
        return gpuSensors.map { $0.temperature }.reduce(0, +) / Double(gpuSensors.count)
    }

    // SOC temperature approximation
    var socTemperature: Double? {
        let temps = readAll()
        let socSensors = temps.filter { $0.name.lowercased().contains("soc") || $0.name.lowercased().contains("tdie") || $0.name.lowercased().contains("die") }
        guard !socSensors.isEmpty else { return nil }
        return socSensors.map { $0.temperature }.reduce(0, +) / Double(socSensors.count)
    }

    deinit {
        if let handle = dlHandle {
            dlclose(handle)
        }
    }

    // MARK: - Event callback and runloop

    // The event callback is a C-convention closure matching IOHIDEventSystemClientEventCallback.
    // It uses the provided context pointer to recover the `AppleSiliconSensors` instance
    // and then extracts the temperature value using the instance's `getFloat` function
    // pointer (if available). We keep the callback minimal: validate the value and
    // push it into a bounded in-memory buffer under `readingsQueue` synchronization.
    private static let eventCallback: IOHIDEventSystemClientEventCallback = { (clientRaw, serviceRaw, eventRaw, contextRaw) in
        guard let ctx = contextRaw else { return }
        let myself = Unmanaged<AppleSiliconSensors>.fromOpaque(ctx).takeUnretainedValue()

        // Extract service and event pointers
        guard let servicePtr = serviceRaw else { return }
        let service = servicePtr
        guard let eventPtrRaw = eventRaw else { return }
        let event = eventPtrRaw

        guard let getFloat = myself.getFloat else { return }
        let value = getFloat(event, UInt32(myself.temperatureEventType << 16))

        // Basic validation
        guard value > 0 && value < 150 else { return }

        // Update buffer and cached readings under synchronization
        myself.readingsQueue.sync {
            // Maintain bounded event buffer
            myself.eventBuffer.append((service: service, temperature: value))
            if myself.eventBuffer.count > myself.eventBufferCapacity {
                myself.eventBuffer.removeFirst(myself.eventBuffer.count - myself.eventBufferCapacity)
            }

            // Update cachedReadings by mapping service -> sensor name if known
            if let idx = myself.sensors.firstIndex(where: { $0.service == service }) {
                let name = myself.sensors[idx].name
                // Replace existing reading for the sensor or append
                if let existing = myself.cachedReadings.firstIndex(where: { $0.name == name }) {
                    myself.cachedReadings[existing] = AppleSiliconSensorReading(name: name, temperature: value)
                } else {
                    myself.cachedReadings.append(AppleSiliconSensorReading(name: name, temperature: value))
                }
                myself.lastReadTimestamp = Date().timeIntervalSince1970
            }
        }
    }

    // Start a dedicated thread and schedule the IOHID client on its runloop.
    // This keeps event callbacks off the main thread and provides a stable runloop
    // for IOHID to deliver events. The method is intentionally small and
    // non-blocking (it starts a Thread which calls CFRunLoopRun()).
    private func startEventRunLoopThread() {
        // Start a dedicated thread with a runloop and schedule the IOHID client on it
        guard let schedule = scheduleWithRunLoop, let client = client else { return }

        let thread = Thread {
            schedule(client, CFRunLoopGetCurrent(), nil)
            CFRunLoopRun()
        }
        thread.name = "com.eul.applesilicon.hid"
        thread.start()
        runLoopThread = thread
    }
}

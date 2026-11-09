import Foundation
import IOKit.hid

/// Serial queue for all blocking device I/O.
let io = DispatchQueue(label: "logibar.io")

private let logLock = NSLock()

/// Appends a diagnostic line to ~/Library/Logs/LogiBar.log (local only; rotated at 512 KB).
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = "\(Date()) \(s)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LogiBar.log")
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

/// Dedicated thread whose run loop delivers HID callbacks, so io-queue waits never deadlock.
final class HIDThread: Thread {
    private(set) var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)
    static let shared: HIDThread = { let t = HIDThread(); t.name = "logibar.hid"; t.start(); t.ready.wait(); return t }()
    override func main() {
        runLoop = CFRunLoopGetCurrent()
        var ctx = CFRunLoopSourceContext()
        CFRunLoopAddSource(runLoop, CFRunLoopSourceCreate(nil, 0, &ctx), .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }
}

/// A HID device speaking HID++ style 20-byte long reports (report id 0x11).
final class HIDPPDevice {
    let dev: IOHIDDevice
    let name: String
    let productID: Int
    private let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = NSLock()
    private var pending: (idx: UInt8, fn: UInt8, sem: DispatchSemaphore)?
    private var reply: [UInt8]?
    private var featureCache: [UInt16: UInt8] = [:]
    private(set) var isOpen = false

    init(_ dev: IOHIDDevice) {
        self.dev = dev
        name = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
        productID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0
    }
    deinit {
        if isOpen {
            // Unregister first so no callback can fire with a dangling context pointer.
            IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, nil, nil)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        buf.deallocate()
    }

    @discardableResult
    func open() -> IOReturn {
        if isOpen { return kIOReturnSuccess }
        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { return r }
        isOpen = true
        IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { ctx, _, _, _, _, report, len in
            let me = Unmanaged<HIDPPDevice>.fromOpaque(ctx!).takeUnretainedValue()
            me.received(Array(UnsafeBufferPointer(start: report, count: len)))
        }, Unmanaged.passUnretained(self).toOpaque())
        return r
    }

    private func received(_ r: [UInt8]) {
        // Only HID++ long reports (id 0x11) are examined. Ordinary input (pointer motion,
        // clicks) is ignored immediately and never stored or logged.
        guard r.count >= 4, r[0] == 0x11 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let p = pending else { return }
        let isReply = r[2] == p.idx && r[3] == p.fn
        let isError = (r[2] == 0xff || r[2] == 0x8f) && r.count >= 5 && r[3] == p.idx && r[4] == p.fn
        if isReply || isError { reply = isError ? [] : r; pending = nil; p.sem.signal() }
    }

    /// Raw request: sends [0x11, 0xff, idx, fnByte, params…]; returns the full reply, [] on HID++ error, nil on timeout.
    /// Call on the `io` queue only.
    func raw(_ idx: UInt8, _ fnByte: UInt8, _ params: [UInt8] = [], wait: Bool = true, timeout: Double = 0.6) -> [UInt8]? {
        var msg: [UInt8] = [0x11, 0xff, idx, fnByte] + params
        msg += Array(repeating: 0, count: max(0, 20 - msg.count))
        let sem = DispatchSemaphore(value: 0)
        lock.lock(); reply = nil; pending = wait ? (idx, fnByte, sem) : nil; lock.unlock()
        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
        guard res == kIOReturnSuccess else { log("\(name): setReport \(hex(msg)) failed \(res)"); return nil }
        guard wait else { return [] }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending = nil; lock.unlock()
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return reply
    }

    /// HID++ 2.0 call: function number 0…15, software id 0xA.
    func call(_ idx: UInt8, fn: UInt8, _ params: [UInt8] = []) -> [UInt8]? {
        guard let r = raw(idx, (fn << 4) | 0x0a, params), r.count >= 4 else { return nil }
        return Array(r.dropFirst(4))
    }

    /// Root.getFeature – returns the feature index, or nil when unsupported.
    func featureIndex(_ id: UInt16) -> UInt8? {
        if let c = featureCache[id] { return c == 0 ? nil : c }
        guard let r = call(0x00, fn: 0, [UInt8(id >> 8), UInt8(id & 0xff)]), let i = r.first else { return nil }
        featureCache[id] = i
        return i == 0 ? nil : i
    }
}

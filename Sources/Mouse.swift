import Foundation
import IOKit.hid

final class MouseDevice: ObservableObject, Identifiable {
    let id = UUID()
    let hid: HIDPPDevice
    var name: String { hid.name.replacingOccurrences(of: " M", with: "", options: .anchored.union(.backwards)) }

    @Published var status = "Connecting…"
    @Published var ready = false
    @Published var battery: Int?
    @Published var charging = false
    @Published var dpi: Double = 1000
    @Published var dpiRange: ClosedRange<Double> = 200...8000
    @Published var dpiStep: Double = 50
    @Published var hasDPI = false
    @Published var hasSmartShift = false
    @Published var ratchet = true          // false = free spin
    @Published var smartShift: Double = 10 // auto-disengage threshold, 1…50

    private var fBattery: (idx: UInt8, unified: Bool)?
    private var fDPI: (idx: UInt8, extended: Bool)?
    private var fSS: (idx: UInt8, enhanced: Bool)?
    private var lod: UInt8 = 0
    private var deviceDPI = 0

    init(_ hid: HIDPPDevice) { self.hid = hid }

    private var pendingDPI: DispatchWorkItem?, pendingWheel: DispatchWorkItem?
    /// Debounced writes, so dragging a slider sends one command after it settles.
    func scheduleDPI(_ v: Double) {
        pendingDPI?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.setDPI(v) }
        pendingDPI = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
    func scheduleWheel() {
        pendingWheel?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.setWheel() }
        pendingWheel = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func setup() {
        io.async { [self] in
            let r = hid.open()
            guard r == kIOReturnSuccess else {
                log("\(hid.name): open failed \(r)")
                ui { $0.status = r == kIOReturnNotPermitted ? "Needs Input Monitoring permission" : "Can't open (error \(r))" }
                return
            }
            guard hid.featureIndex(0x0001) != nil || hid.call(0x00, fn: 0, [0x00, 0x01]) != nil else {
                log("\(hid.name): no HID++ reply"); ui { $0.status = "Not responding" }; return
            }
            if let i = hid.featureIndex(0x1004) { fBattery = (i, true) } else if let i = hid.featureIndex(0x1000) { fBattery = (i, false) }
            if let i = hid.featureIndex(0x2201) { fDPI = (i, false) } else if let i = hid.featureIndex(0x2202) { fDPI = (i, true) }
            if let i = hid.featureIndex(0x2111) { fSS = (i, true) } else if let i = hid.featureIndex(0x2110) { fSS = (i, false) }
            log("\(hid.name): battery=\(String(describing: fBattery)) dpi=\(String(describing: fDPI)) smartshift=\(String(describing: fSS))")
            readDPIRange()
            readAll()
            ui { $0.ready = true; $0.status = "" }
        }
    }

    func refresh() { io.async { [self] in if hid.isOpen { readAll() } else { setup() } } }

    private func ui(_ f: @escaping (MouseDevice) -> Void) { DispatchQueue.main.async { f(self) } }

    // MARK: reads (io queue)

    private func readAll() {
        if let f = fBattery, let r = hid.call(f.idx, fn: f.unified ? 1 : 0), r.count >= 3 {
            log("\(hid.name): battery \(hex(r))")
            let pct = Int(r[0]); let chg = f.unified ? (1...3).contains(r[2]) : (1...4).contains(r[2])
            ui { $0.battery = pct > 0 ? pct : nil; $0.charging = chg }
        }
        if let f = fDPI {
            let r = hid.call(f.idx, fn: f.extended ? 5 : 2, [0])
            log("\(hid.name): dpi \(r.map(hex) ?? "nil")")
            if let r, r.count >= 3 {
                let v = Double(Int(r[1]) << 8 | Int(r[2]))
                if f.extended, r.count >= 10 { lod = r[9] }
                ui { $0.deviceDPI = Int(v); $0.hasDPI = v > 0; if v > 0 { $0.dpi = v } }
            }
        }
        if let f = fSS, let r = hid.call(f.idx, fn: f.enhanced ? 1 : 0), r.count >= 2 {
            log("\(hid.name): smartshift \(hex(r))")
            ui { $0.hasSmartShift = true; $0.ratchet = r[0] == 2; if r[1] > 0 && r[1] < 255 { $0.smartShift = Double(min(r[1], 50)) } }
        }
    }

    private func readDPIRange() {
        guard let f = fDPI else { return }
        let r = f.extended ? hid.call(f.idx, fn: 2, [0, 0, 0]) : hid.call(f.idx, fn: 1, [0])
        log("\(hid.name): dpi list \(r.map(hex) ?? "nil")")
        guard let r else { return }
        var vals: [Int] = []; var step = 0
        var i = f.extended ? 3 : 1
        while i + 1 < r.count {
            let v = Int(r[i]) << 8 | Int(r[i + 1]); i += 2
            if v == 0 { break }
            if v >= 0xe000 { step = v - 0xe000 } else { vals.append(v) }
        }
        if let lo = vals.min(), let hi = vals.max(), hi > lo {
            ui { $0.dpiRange = Double(lo)...Double(hi); if step > 0 { $0.dpiStep = Double(step) } }
        }
    }

    // MARK: writes

    func setDPI(_ v: Double) {
        guard let f = fDPI else { return }
        let d = Int(v); guard d != deviceDPI else { return }; deviceDPI = d
        let hi = UInt8(d >> 8), lo = UInt8(d & 0xff)
        io.async { [self] in
            let r = f.extended ? hid.call(f.idx, fn: 6, [0, hi, lo, hi, lo, lod]) : hid.call(f.idx, fn: 3, [0, hi, lo])
            log("\(hid.name): set dpi \(d) -> \(r.map(hex) ?? "nil")")
        }
    }

    func setWheel() {
        guard let f = fSS else { return }
        let mode: UInt8 = ratchet ? 2 : 1, thr = UInt8(smartShift)
        io.async { [self] in
            let r = f.enhanced ? hid.call(f.idx, fn: 2, [mode, thr, 0]) : hid.call(f.idx, fn: 1, [mode, thr])
            log("\(hid.name): set wheel mode=\(mode) thr=\(thr) -> \(r.map(hex) ?? "nil")")
        }
    }
}

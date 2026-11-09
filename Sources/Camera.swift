import Foundation

struct UVCDef {
    enum Unit { case ct, pu }
    let key: String, label: String, unit: Unit, sel: UInt8, size: Int, signed: Bool
    var toggle: (on: Int, off: Int)? = nil
    var autoKey: String? = nil   // slider disabled while this toggle is on
}

let uvcDefs: [UVCDef] = [
    .init(key: "zoom", label: "Zoom", unit: .ct, sel: 0x0b, size: 2, signed: false),
    .init(key: "focusAuto", label: "Auto focus", unit: .ct, sel: 0x08, size: 1, signed: false, toggle: (1, 0)),
    .init(key: "focus", label: "Focus", unit: .ct, sel: 0x06, size: 2, signed: false, autoKey: "focusAuto"),
    .init(key: "aeMode", label: "Auto exposure", unit: .ct, sel: 0x02, size: 1, signed: false, toggle: (8, 1)),
    .init(key: "exposure", label: "Exposure", unit: .ct, sel: 0x04, size: 4, signed: false, autoKey: "aeMode"),
    .init(key: "wbAuto", label: "Auto white balance", unit: .pu, sel: 0x0b, size: 1, signed: false, toggle: (1, 0)),
    .init(key: "wbTemp", label: "White balance", unit: .pu, sel: 0x0a, size: 2, signed: false, autoKey: "wbAuto"),
    .init(key: "brightness", label: "Brightness", unit: .pu, sel: 0x02, size: 2, signed: true),
    .init(key: "contrast", label: "Contrast", unit: .pu, sel: 0x03, size: 2, signed: false),
    .init(key: "saturation", label: "Saturation", unit: .pu, sel: 0x07, size: 2, signed: false),
    .init(key: "sharpness", label: "Sharpness", unit: .pu, sel: 0x08, size: 2, signed: false),
    .init(key: "gain", label: "Gain", unit: .pu, sel: 0x04, size: 2, signed: false),
    .init(key: "backlight", label: "Backlight compensation", unit: .pu, sel: 0x01, size: 2, signed: false),
]

final class UVCControl: ObservableObject, Identifiable {
    let def: UVCDef
    var id: String { def.key }
    let min: Int, max: Int, dflt: Int
    @Published var value: Double
    init(def: UVCDef, min: Int, max: Int, dflt: Int, value: Int) {
        self.def = def; self.min = min; self.max = max; self.dflt = dflt; self.value = Double(value)
    }
    var isOn: Bool { Int(value) == def.toggle?.on }
}

final class CameraDevice: ObservableObject, Identifiable {
    let id = UUID()
    let cam: uvc_cam
    let name: String
    @Published var controls: [UVCControl] = []

    init(_ cam: uvc_cam) {
        self.cam = cam
        var c = cam
        name = withUnsafeBytes(of: &c.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private var defaultsKey: String { "camera." + name }

    private func unitID(_ d: UVCDef) -> UInt8 { d.unit == .ct ? cam.ctID : cam.puID }

    private func get(_ d: UVCDef, _ req: UInt8) -> Int? {
        let unit = unitID(d); guard unit != 0 else { return nil }
        var b = [UInt8](repeating: 0, count: d.size)
        guard uvc_ctrl(cam.location, 0, req, unit, cam.ifnum, d.sel, &b, UInt16(d.size)) == 0 else { return nil }
        var v = 0
        for (i, x) in b.enumerated() { v |= Int(x) << (8 * i) }
        if d.signed && d.size == 2 && v >= 0x8000 { v -= 0x10000 }
        return v
    }

    private func put(_ d: UVCDef, _ v: Int) -> Bool {
        let unit = unitID(d); guard unit != 0 else { return false }
        var b = (0..<d.size).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
        return uvc_ctrl(cam.location, 1, 0x01, unit, cam.ifnum, d.sel, &b, UInt16(d.size)) == 0
    }

    /// Load controls; re-apply saved settings when `restore` is true (e.g. after plug-in).
    func load(restore: Bool) {
        io.async { [self] in
            let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
            if restore {
                for d in uvcDefs where saved[d.key] != nil && d.toggle != nil { _ = put(d, saved[d.key]!) }
                for d in uvcDefs where saved[d.key] != nil && d.toggle == nil { _ = put(d, saved[d.key]!) }
            }
            var list: [UVCControl] = []
            for d in uvcDefs {
                guard let cur = get(d, 0x81) else { continue }
                if let t = d.toggle {
                    list.append(UVCControl(def: d, min: t.off, max: t.on, dflt: get(d, 0x87) ?? cur, value: cur))
                } else if let lo = get(d, 0x82), let hi = get(d, 0x83), hi > lo {
                    list.append(UVCControl(def: d, min: lo, max: hi, dflt: get(d, 0x87) ?? cur, value: cur))
                }
            }
            log("\(name): \(list.count) controls (ct=\(cam.ctID) pu=\(cam.puID) if=\(cam.ifnum))")
            DispatchQueue.main.async { self.controls = list }
        }
    }

    func set(_ c: UVCControl, _ v: Int, save: Bool = true) {
        let d = c.def
        io.async { [self] in
            if !put(d, v) { log("\(name): set \(d.key)=\(v) failed") }
            guard save else { return }
            var saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
            saved[d.key] = v
            UserDefaults.standard.set(saved, forKey: defaultsKey)
        }
    }

    func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        for c in controls where c.def.toggle != nil { set(c, c.dflt, save: false) }
        for c in controls where c.def.toggle == nil { set(c, c.dflt, save: false) }
        load(restore: false)
    }

    func isLocked(_ c: UVCControl) -> Bool {
        guard let k = c.def.autoKey, let a = controls.first(where: { $0.def.key == k }) else { return false }
        return a.isOn
    }
}

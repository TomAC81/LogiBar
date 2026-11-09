import Foundation

final class LitraDevice: ObservableObject, Identifiable {
    let id = UUID()
    let hid: HIDPPDevice
    let name: String
    let lumens: ClosedRange<Double>
    let kelvin: ClosedRange<Double> = 2700...6500
    private let fx: UInt8

    @Published var on = false
    @Published var brightness: Double = 100   // lumens
    @Published var temperature: Double = 4000 // kelvin

    static let productIDs: Set<Int> = [0xc900, 0xc901, 0xb901, 0xc903]

    init(_ hid: HIDPPDevice) {
        self.hid = hid
        switch hid.productID {
        case 0xc900: name = "Litra Glow"; lumens = 20...250; fx = 0x04
        case 0xc903: name = "Litra Beam LX"; lumens = 30...400; fx = 0x06
        default: name = "Litra Beam"; lumens = 30...400; fx = 0x04
        }
    }

    var percent: Int { Int(((brightness - lumens.lowerBound) / (lumens.upperBound - lumens.lowerBound) * 100).rounded()) }

    func refresh() {
        io.async { [self] in
            let r = hid.open()
            guard r == kIOReturnSuccess else { log("\(name): open failed \(r)"); return }
            let o = hid.raw(fx, 0x01), b = hid.raw(fx, 0x31), t = hid.raw(fx, 0x81)
            DispatchQueue.main.async { [self] in
                if let o, o.count > 4 { on = o[4] == 1 }
                if let b, b.count > 5 { brightness = Double(Int(b[4]) << 8 | Int(b[5])).clamped(lumens) }
                if let t, t.count > 5 { temperature = Double(Int(t[4]) << 8 | Int(t[5])).clamped(kelvin) }
            }
        }
    }

    func setOn(_ v: Bool) {
        on = v
        io.async { [self] in _ = hid.raw(fx, 0x1c, [v ? 1 : 0]) }
    }

    func setBrightness(_ lm: Double) {
        let v = Int(lm.rounded())
        io.async { [self] in _ = hid.raw(fx, 0x4c, [UInt8(v >> 8), UInt8(v & 0xff)]) }
    }

    func setTemperature(_ k: Double) {
        let v = Int((k / 100).rounded()) * 100
        io.async { [self] in _ = hid.raw(fx, 0x9c, [UInt8(v >> 8), UInt8(v & 0xff)]) }
    }
}

extension Double {
    func clamped(_ r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}

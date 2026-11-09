import Foundation
import IOKit.hid

final class DeviceHub: ObservableObject {
    static let shared = DeviceHub()
    @Published var lights: [LitraDevice] = []
    @Published var mice: [MouseDevice] = []
    @Published var cameras: [CameraDevice] = []

    private var manager: IOHIDManager!
    private var timer: Timer?

    /// Turn the Litra on while any camera is in use, and back off afterwards.
    @Published var lightWithCamera = UserDefaults.standard.bool(forKey: "lightWithCamera") {
        didSet { UserDefaults.standard.set(lightWithCamera, forKey: "lightWithCamera"); if lightWithCamera { cameraActive = false; checkCamera() } }
    }
    @Published private(set) var cameraActive = false
    private var turnedOnByUs: Set<UUID> = []
    private var cameraTimer: Timer?

    private func checkCamera() {
        let active = anyCameraInUse()
        guard active != cameraActive else { return }
        cameraActive = active
        log("camera in use: \(active)")
        guard lightWithCamera else { return }
        if active {
            for l in lights where !l.on { l.setOn(true); turnedOnByUs.insert(l.id) }
        } else {
            for l in lights where turnedOnByUs.contains(l.id) { l.setOn(false) }
            turnedOnByUs.removeAll()
        }
    }

    func start() {
        let before = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log("input monitoring: check=\(before.rawValue) (0 granted, 1 denied, 2 unknown) request=\(granted)")
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x046d] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<DeviceHub>.fromOpaque(ctx!).takeUnretainedValue().added(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<DeviceHub>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, HIDThread.shared.runLoop, CFRunLoopMode.defaultMode.rawValue)
        CFRunLoopWakeUp(HIDThread.shared.runLoop)

        scanCameras()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scanCameras() }
        cameraTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkCamera() }
    }

    // Called on the HID thread.
    private func added(_ dev: IOHIDDevice) {
        let hid = HIDPPDevice(dev)
        let page = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        let maxOut = IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? 0
        log("found \(hid.name) pid=\(String(format: "%04x", hid.productID)) page=\(page) usage=\(usage) maxOut=\(maxOut)")
        DispatchQueue.main.async { [self] in
            if LitraDevice.productIDs.contains(hid.productID) {
                guard !lights.contains(where: { $0.hid.dev == dev }) else { return }
                let l = LitraDevice(hid); lights.append(l); l.refresh()
            } else if page == 1 && usage == 2 && maxOut >= 20 {
                guard !mice.contains(where: { $0.hid.dev == dev }) else { return }
                let m = MouseDevice(hid); mice.append(m); m.setup()
            }
        }
    }

    private func removed(_ dev: IOHIDDevice) {
        DispatchQueue.main.async { [self] in
            lights.removeAll { $0.hid.dev == dev }
            mice.removeAll { $0.hid.dev == dev }
        }
    }

    func scanCameras() {
        io.async { [self] in
            var locs = [UInt32](repeating: 0, count: 8)
            let n = Int(uvc_locations(&locs, 8))
            let current = Set(locs.prefix(n))
            let known = DispatchQueue.main.sync { Set(cameras.map { $0.cam.location }) }
            var fresh: [CameraDevice] = []
            for loc in current.subtracting(known) {
                var c = uvc_cam()
                let r = uvc_probe(loc, &c)
                if r == 0 { fresh.append(CameraDevice(c)) } else { log("camera probe \(String(format: "%08x", loc)) failed \(r)") }
            }
            DispatchQueue.main.async { [self] in
                cameras.removeAll { !current.contains($0.cam.location) }
                for c in fresh { cameras.append(c); c.load(restore: true) }
            }
        }
    }

    func refreshAll() {
        lights.forEach { $0.refresh() }
        mice.forEach { $0.refresh() }
        cameras.forEach { $0.load(restore: false) }
    }
}

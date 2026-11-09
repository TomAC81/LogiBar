import Foundation
import CoreMediaIO

/// True when any camera on the system is streaming to some app (FaceTime, Zoom, Meet, Photo Booth…).
/// Reading this does not need camera permission and does not open the camera.
func anyCameraInUse() -> Bool {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
    var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
    addr.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
    for id in ids {
        var running: UInt32 = 0
        var got: UInt32 = 0
        if CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0, running != 0 {
            return true
        }
    }
    return false
}

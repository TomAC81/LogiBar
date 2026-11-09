import SwiftUI
import ServiceManagement
import IOKit.hid

@main
struct LogiBarApp: App {
    @StateObject private var hub = DeviceHub.shared
    init() { DeviceHub.shared.start() }
    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(hub)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @EnvironmentObject var hub: DeviceHub
    @StateObject private var login = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hub.lights.isEmpty && hub.mice.isEmpty && hub.cameras.isEmpty {
                Text("No Logitech devices found").foregroundStyle(.secondary)
            }
            ForEach(hub.lights) { LightCard(light: $0) }
            ForEach(hub.cameras) { CameraCard(camera: $0) }
            ForEach(hub.mice) { MouseCard(mouse: $0) }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { hub.refreshAll() }
    }
}

struct Card<Content: View, Accessory: View>: View {
    let icon: String, title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct LabeledSlider: View {
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var disabled = false
    var onEnd: ((Double) -> Void)? = nil
    var onChange: ((Double) -> Void)? = nil

    private func snap(_ v: Double) -> Double {
        guard let step, step > 0 else { return v }
        return (range.lowerBound + ((v - range.lowerBound) / step).rounded() * step).clamped(range)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label); Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            // Continuous native slider (a `step:` slider draws tick marks), snapped to the step in code.
            Slider(value: Binding(get: { value }, set: { value = snap($0) }), in: range) { editing in
                if !editing { onEnd?(value) }
            }
            .controlSize(.small)
            .onChange(of: value) { _, v in onChange?(v) }
        }
        .disabled(disabled)
    }
}

struct LightCard: View {
    @ObservedObject var light: LitraDevice
    @EnvironmentObject var hub: DeviceHub
    var body: some View {
        Card(icon: light.on ? "lightbulb.fill" : "lightbulb", title: light.name) {
            Toggle("", isOn: Binding(get: { light.on }, set: { light.setOn($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        } content: {
            LabeledSlider(label: "Brightness", valueText: "\(light.percent)%", value: $light.brightness,
                          range: light.lumens, onChange: { light.setBrightness($0) })
            LabeledSlider(label: "Temperature", valueText: "\(Int(light.temperature)) K", value: $light.temperature,
                          range: light.kelvin, step: 100, onChange: { light.setTemperature($0) })
            Toggle("Turn on when the camera is in use", isOn: $hub.lightWithCamera)
                .font(.caption).toggleStyle(.checkbox)
        }
    }
}

struct MouseCard: View {
    @ObservedObject var mouse: MouseDevice
    var body: some View {
        Card(icon: "computermouse", title: mouse.name) {
            if let b = mouse.battery {
                Label("\(b)%", systemImage: mouse.charging ? "battery.100.bolt" : batteryIcon(b))
                    .font(.caption).foregroundStyle(b <= 15 ? .red : .secondary)
            }
        } content: {
            if !mouse.ready {
                Text(mouse.status).font(.caption).foregroundStyle(.secondary)
                if mouse.status.contains("Input Monitoring") {
                    Button("Open Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                    }.controlSize(.small)
                    Text("Enable LogiBar there, then quit and reopen it.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if mouse.hasDPI {
                LabeledSlider(label: "Pointer speed", valueText: "\(Int(mouse.dpi)) DPI", value: $mouse.dpi,
                              range: mouse.dpiRange, step: mouse.dpiStep, onChange: { mouse.scheduleDPI($0) })
            }
            if mouse.hasSmartShift {
                Toggle("Ratchet scrolling (SmartShift)", isOn: Binding(get: { mouse.ratchet }, set: { mouse.ratchet = $0; mouse.setWheel() }))
                    .font(.caption).toggleStyle(.checkbox)
                LabeledSlider(label: "SmartShift sensitivity", valueText: "\(Int(mouse.smartShift))", value: $mouse.smartShift,
                              range: 1...50, step: 1, disabled: !mouse.ratchet, onChange: { _ in mouse.scheduleWheel() })
            }
        }
    }
    func batteryIcon(_ b: Int) -> String { b > 85 ? "battery.100" : b > 60 ? "battery.75" : b > 35 ? "battery.50" : b > 15 ? "battery.25" : "battery.0" }
}

struct CameraCard: View {
    @ObservedObject var camera: CameraDevice
    @StateObject private var ui = Expander()
    var expanded: Bool { ui.expanded }
    var body: some View {
        Card(icon: "web.camera", title: camera.name) {
            Button(expanded ? "Less" : "More") { withAnimation { ui.expanded.toggle() } }
                .buttonStyle(.link).font(.caption)
        } content: {
            if camera.controls.isEmpty { Text("Reading camera…").font(.caption).foregroundStyle(.secondary) }
            let basic: Set<String> = ["zoom", "brightness", "focusAuto", "focus", "wbAuto", "wbTemp"]
            ForEach(camera.controls.filter { expanded || basic.contains($0.def.key) }) { c in
                ControlRow(camera: camera, control: c)
            }
            if expanded {
                Button("Reset to defaults") { camera.resetDefaults() }.controlSize(.small)
            }
        }
    }
}

struct ControlRow: View {
    @ObservedObject var camera: CameraDevice
    @ObservedObject var control: UVCControl
    var body: some View {
        if let t = control.def.toggle {
            Toggle(control.def.label, isOn: Binding(get: { control.isOn }, set: { on in
                control.value = Double(on ? t.on : t.off)
                camera.set(control, on ? t.on : t.off)
                camera.objectWillChange.send()
                if !on { camera.load(restore: false) }  // pick up the value the camera settled on
            }))
            .font(.caption).toggleStyle(.checkbox)
        } else {
            LabeledSlider(label: control.def.label, valueText: "\(Int(control.value))", value: $control.value,
                          range: Double(control.min)...Double(control.max), step: 1,
                          disabled: camera.isLocked(control), onChange: { camera.set(control, Int($0)) })
        }
    }
}

final class Expander: ObservableObject { @Published var expanded = false }

final class LoginItem: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    func set(_ v: Bool) {
        do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { log("login item: \(error)") }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

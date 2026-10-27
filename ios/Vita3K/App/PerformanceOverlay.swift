import Darwin
import Metal
import UIKit

/// Average guest frame interval over the sampling window, not input latency
/// or GPU execution time. A stopped frame counter must produce 0 FPS.
struct GuestFrameSampler {
    struct Reading {
        let fps: Double
        let frameMilliseconds: Double?
    }

    private var previous: (frames: UInt64, time: TimeInterval)?

    mutating func reset() { previous = nil }

    mutating func sample(frames: UInt64, time: TimeInterval, paused: Bool) -> Reading? {
        guard !paused else {
            reset()
            return nil
        }
        defer { previous = (frames, time) }
        guard let previous, time > previous.time, frames >= previous.frames else { return nil }
        let elapsed = time - previous.time
        let count = Double(frames - previous.frames)
        return Reading(fps: count / elapsed, frameMilliseconds: count > 0 ? elapsed * 1000 / count : nil)
    }
}

struct PerformanceMemory {
    let footprintBytes: UInt64?
    let gpuAllocatedBytes: UInt64?

    static func read(device: (any MTLDevice)?) -> Self {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // Apple silicon uses unified memory: footprint already accounts for
        // charged GPU pages. Metal's allocated size is a separate allocation
        // metric, not extra physical VRAM to add to this footprint.
        #if targetEnvironment(simulator)
        // Simulator Metal reports zero even with live buffers; unavailable,
        // rather than a measured zero-byte GPU footprint.
        let gpuBytes: UInt64? = nil
        #else
        let gpuBytes = device.map { UInt64($0.currentAllocatedSize) }
        #endif
        return Self(footprintBytes: result == KERN_SUCCESS ? info.phys_footprint : nil,
                    gpuAllocatedBytes: gpuBytes)
    }
}

/// Compact, noninteractive frosted pill above the game surface and virtual controls:
/// FPS, memory, battery and device temperature.
@MainActor
final class PerformanceOverlayView: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let fpsValue = UILabel()
    private let memoryValue = UILabel()
    private let batteryValue = UILabel()
    private let tempValue = UILabel()
    private let tempDot = UIView()

    private func caption(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 8, weight: .medium)
        l.textColor = UIColor.white.withAlphaComponent(0.6)
        l.textAlignment = .center
        return l
    }

    private func style(_ l: UILabel) {
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.textColor = .white
        l.textAlignment = .center
        l.text = "—"
    }

    private func column(_ title: String, _ value: UIView) -> UIStackView {
        let c = UIStackView(arrangedSubviews: [caption(title), value])
        c.axis = .vertical
        c.alignment = .center
        c.spacing = 1
        return c
    }

    private func divider() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "performance-overlay"
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        [fpsValue, memoryValue, batteryValue, tempValue].forEach(style)

        tempDot.layer.cornerRadius = 3
        tempDot.translatesAutoresizingMaskIntoConstraints = false
        tempDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        tempDot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        tempValue.font = .systemFont(ofSize: 12, weight: .semibold)
        let tempRow = UIStackView(arrangedSubviews: [tempDot, tempValue])
        tempRow.spacing = 3
        tempRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [
            column("FPS", fpsValue), divider(),
            column("MB", memoryValue), divider(),
            column("BAT", batteryValue), divider(),
            column("TEMP", tempRow),
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor), blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor), blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frames: GuestFrameSampler.Reading?, memory: PerformanceMemory, paused: Bool) {
        fpsValue.text = paused ? "II" : (frames.map { String(format: "%.0f", $0.fps) } ?? "—")
        memoryValue.text = memory.footprintBytes.map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "—"

        let level = UIDevice.current.batteryLevel
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if level < 0 {
            batteryValue.text = "—"
        } else {
            batteryValue.text = "\(Int((level * 100).rounded()))%" + (charging ? "⚡︎" : "")
        }
        batteryValue.textColor = (!charging && level >= 0 && level <= 0.2) ? UIColor.systemRed : .white

        let thermal: (String, UIColor)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = ("Cool", .systemGreen)
        case .fair: thermal = ("Warm", .systemYellow)
        case .serious: thermal = ("Hot", .systemOrange)
        case .critical: thermal = ("Critical", .systemRed)
        @unknown default: thermal = ("—", .systemGray)
        }
        tempValue.text = L10n.text(thermal.0)
        tempDot.backgroundColor = thermal.1

        accessibilityLabel = "FPS \(fpsValue.text ?? ""), \(memoryValue.text ?? "") MB, \(L10n.text("Bateria")) \(batteryValue.text ?? ""), \(tempValue.text ?? "")"
    }
}

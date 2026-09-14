import SwiftUI
import AppKit

// Original particle geometry/projection implementation inspired by the user's screenshot.
// No MetalForge source, exported code, or paid assets are used.
enum ThinkingOrbMode: String, CaseIterable {
    case breathe, rings, vortex
    var title: String {
        switch self {
        case .breathe: "呼吸"
        case .rings: "环带"
        case .vortex: "涡旋"
        }
    }
}

final class ThinkingOrbClock: ObservableObject {
    @Published private var heldTime = 0.0
    private var runningSince: Date?
    func value(at date: Date) -> Double {
        heldTime + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }
    func setRunning(_ active: Bool, at now: Date = .now) {
        guard active != (runningSince != nil) else { return }
        if active { objectWillChange.send(); runningSince = now }
        else if let since = runningSince { heldTime += now.timeIntervalSince(since); runningSince = nil }
    }
}

struct ThinkingOrb: View {
    let mode: ThinkingOrbMode
    let level: Float
    let running: Bool
    let reducedMotion: Bool
    @ObservedObject var clock: ThinkingOrbClock
    private var animate: Bool { running && !reducedMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { timeline in
            ZStack {
                ParticleSphereFrame(mode: mode, time: clock.value(at: timeline.date), level: level)
                    .id(mode).transition(.opacity)
            }
            .animation(reducedMotion ? .none : .easeInOut(duration: 0.2), value: mode)
        }
        .onAppear { clock.setRunning(animate) }
        .onChange(of: animate) { _, active in clock.setRunning(active) }
        .accessibilityHidden(true)
    }
}

struct ParticleSphereFrame: View {
    let mode: ThinkingOrbMode
    let time: Double
    let level: Float

    var body: some View {
        Canvas { context, size in
            let diameter = min(size.width, size.height)
            let pulse = mode == .breathe ? 1 + sin(time * 1.65) * 0.045 : 1
            let radius = diameter * 0.40 * pulse * (1 + Double(level) * 0.045)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let count = mode == .rings ? 162 : 148
            let goldenAngle = Double.pi * (3 - sqrt(5))
            var dots: [(x: Double, y: Double, z: Double, size: Double, warm: Bool)] = []
            for index in 0..<count {
                var latitude = 1 - 2 * (Double(index) + 0.5) / Double(count)
                var longitude = Double(index) * goldenAngle
                if mode == .rings {
                    let ring = index / 18
                    latitude = -0.88 + Double(ring) * 0.22
                    longitude = Double(index % 18) / 18 * 2 * Double.pi + Double(ring % 2) * 0.17
                }
                let rim = sqrt(max(0, 1 - latitude * latitude))
                let spin = time * (mode == .vortex ? 0.58 : 0.24)
                longitude += spin
                if mode == .vortex { longitude += latitude * 1.8 + sin(time * 0.7 + latitude * 3) * 0.25 }
                var x = rim * cos(longitude)
                var y = latitude
                var z = rim * sin(longitude)
                let tilt = mode == .rings ? 0.25 : 0.19
                let tiltedY = y * cos(tilt) - z * sin(tilt)
                z = y * sin(tilt) + z * cos(tilt)
                y = tiltedY
                if mode == .vortex {
                    let angle = 0.25
                    let rotatedX = x * cos(angle) - y * sin(angle)
                    y = x * sin(angle) + y * cos(angle)
                    x = rotatedX
                }
                let perspective = 2.9 / (2.9 - z * 0.25)
                let front = (z + 1) * 0.5
                let dotSize = diameter * (0.009 + 0.014 * pow(front, 1.5))
                let sweep = sin(longitude - time * 0.9)
                let warm = mode == .vortex && sweep > 0.93 && z > 0.05
                dots.append((x * radius * perspective, y * radius * perspective, z, dotSize, warm))
            }
            for dot in dots.sorted(by: { $0.z < $1.z }) {
                let depth = (dot.z + 1) * 0.5
                let alpha = 0.10 + 0.80 * pow(depth, 1.55)
                let color = dot.warm ? Color(red: 0.77, green: 0.48, blue: 0.24) : Color(white: 0.88)
                let rect = CGRect(x: center.x + dot.x - dot.size / 2, y: center.y + dot.y - dot.size / 2, width: dot.size, height: dot.size)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            }
        }
    }
}

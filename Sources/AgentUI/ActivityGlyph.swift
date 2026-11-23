import AppKit
import QuartzCore

/// A small status glyph: a dot, a spinner or ring of ticks while work runs,
/// or a ring filled to a percentage. The dot and spinner are stroke icons; the
/// spinners turn with Core Animation rotations, so they cost no redraws.
final class ActivityGlyph: NSView {
    enum Style: Equatable {
        case none
        case dot(NSColor, diameter: CGFloat)
        case spinner(NSColor)
        /// Ticks round a circle, fading behind the brightest as it steps
        /// clockwise, like the system's spinning indicator.
        case ticks(NSColor)
        case dots(NSColor)
        case ring(fraction: CGFloat, NSColor)
    }

    var style: Style = .none {
        didSet { if style != oldValue { update() } }
    }

    private let shape = CAShapeLayer()
    private let icon = CALayer()
    private let track = CAShapeLayer()
    private var dots: [CAShapeLayer] = []
    private let ticks = CAReplicatorLayer()
    private let tick = CAShapeLayer()
    private static let tickCount = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(shape)
        layer?.addSublayer(icon)
        layer?.addSublayer(ticks)
        ticks.addSublayer(tick)
        tick.lineCap = .round
        track.fillColor = nil
        shape.fillColor = nil
        shape.lineCap = .round
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { update() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.frame = bounds
        track.frame = bounds
        icon.removeAnimation(forKey: "spin")
        icon.contents = nil
        ticks.removeAnimation(forKey: "spin")
        ticks.isHidden = true
        track.path = nil
        dots.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()

        switch style {
        case .none:
            shape.path = nil
        case let .dot(color, diameter):
            shape.path = nil
            // The dot icon's ring spans about half its canvas.
            show(.dot, size: ceil(diameter * 2), color: color, center: center)
        case .spinner(let color):
            shape.path = nil
            show(.spinner, size: side, color: color, center: center)
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            icon.add(spin, forKey: "spin")
        case .ticks(let color):
            shape.path = nil
            ticks.isHidden = false
            ticks.frame = bounds
            tick.frame = bounds
            let outer = side / 2 - 0.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x, y: center.y - outer * 0.45))
            path.addLine(to: CGPoint(x: center.x, y: center.y - outer + 0.75))
            tick.path = path
            tick.strokeColor = color.cgColor
            tick.lineWidth = max(side / 8, 1.25)
            // Each tick sits a step counterclockwise of the last and dimmer,
            // so the trail follows the brightest one round.
            let step = 2 * Double.pi / Double(Self.tickCount)
            ticks.instanceCount = Self.tickCount
            ticks.instanceTransform = CATransform3DMakeRotation(-step, 0, 0, 1)
            ticks.instanceAlphaOffset = -0.7 / Float(Self.tickCount - 1)
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            spin.values = (0..<Self.tickCount).map { Double($0) * step }
            spin.keyTimes = (0...Self.tickCount).map { NSNumber(value: Double($0) / Double(Self.tickCount)) }
            spin.calculationMode = .discrete
            spin.duration = 0.8
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ticks.add(spin, forKey: "spin")
        case .dots(let color):
            shape.path = nil
            let diameter: CGFloat = 2.5
            let gap: CGFloat = 3.5
            let start = center.x - gap
            for index in 0..<3 {
                let dot = CAShapeLayer()
                let x = start + CGFloat(index) * gap - diameter / 2
                dot.path = CGPath(ellipseIn: CGRect(x: x, y: center.y - diameter / 2, width: diameter, height: diameter), transform: nil)
                dot.fillColor = color.cgColor
                dot.opacity = index == 1 ? 0.65 : 0.35
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let pulse = CAKeyframeAnimation(keyPath: "opacity")
                    pulse.values = [0.28, 1.0, 0.28, 0.28]
                    pulse.keyTimes = [0, 0.25, 0.55, 1]
                    pulse.duration = 1.2
                    pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
                    pulse.repeatCount = .infinity
                    pulse.isRemovedOnCompletion = false
                    dot.add(pulse, forKey: "pulse")
                }
                layer?.addSublayer(dot)
                dots.append(dot)
            }
        case let .ring(fraction, color):
            let radius = side / 2 - 1.5
            let circle = CGMutablePath()
            circle.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2, clockwise: true)
            track.path = circle
            track.strokeColor = color.withAlphaComponent(0.22).cgColor
            track.lineWidth = 1.6
            shape.path = circle
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 1.6
            shape.strokeStart = 0
            shape.strokeEnd = min(max(fraction, 0), 1)
        }
    }

    private func show(_ glyph: AppIcon, size: CGFloat, color: NSColor, center: CGPoint) {
        icon.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        icon.contentsScale = window?.backingScaleFactor ?? 2
        icon.contents = glyph.image(size: size, color: color)
    }
}

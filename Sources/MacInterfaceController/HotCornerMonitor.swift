import AppKit
import Foundation

@MainActor
final class HotCornerMonitor {
    static let shared = HotCornerMonitor()

    private var rules: [HotCornerRule] = []
    private var timer: Timer?
    private var generation = UUID()
    private var enteredCorner: CornerPosition?
    private var enteredAt: Date?
    private var hasTriggered = false
    private let activationRadius: CGFloat = 4

    private init() {}

    func configure(_ rules: [HotCornerRule]) {
        self.rules = rules.filter(\.isEnabled)
        stopTimerOnly()
        resetEntry()
        guard !self.rules.isEmpty else { return }
        let currentGeneration = generation
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.generation == currentGeneration else { return }
                self?.samplePointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        rules = []
        stopTimerOnly()
        resetEntry()
    }

    private func stopTimerOnly() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
    }

    private func samplePointer() {
        let point = NSEvent.mouseLocation
        guard let position = detectedCorner(at: point),
              let rule = rules.first(where: { $0.position == position }) else {
            resetEntry()
            return
        }

        if enteredCorner != position {
            enteredCorner = position
            enteredAt = Date()
            hasTriggered = false
            return
        }

        guard !hasTriggered,
              let enteredAt,
              Date().timeIntervalSince(enteredAt) >= rule.dwellSeconds else { return }
        hasTriggered = true
        ActionRunner.run(rule.action)
    }

    private func detectedCorner(at point: CGPoint) -> CornerPosition? {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let nearLeft = abs(point.x - frame.minX) <= activationRadius
            let nearRight = abs(point.x - frame.maxX) <= activationRadius
            let nearBottom = abs(point.y - frame.minY) <= activationRadius
            let nearTop = abs(point.y - frame.maxY) <= activationRadius

            if nearLeft && nearTop { return .topLeft }
            if nearRight && nearTop { return .topRight }
            if nearLeft && nearBottom { return .bottomLeft }
            if nearRight && nearBottom { return .bottomRight }
        }
        return nil
    }

    private func resetEntry() {
        enteredCorner = nil
        enteredAt = nil
        hasTriggered = false
    }
}

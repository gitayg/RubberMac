import CoreGraphics
import Foundation

// Temporal smoothing of detected eyes across video frames, ported from camrelay's tracking.py: a One Euro filter on
// each eye's centre and radius (heavy smoothing while still, little lag while moving), eyes matched to tracks by
// position so detection order can't swap them, and fades for blinks and short dropouts instead of flicker.
extension EyeTracker {
    /// Casiez et al., "1€ Filter" (CHI 2012), for a small vector.
    struct OneEuroFilter {
        let minCutoff: Double, beta: Double, dCutoff: Double
        private var t: Double?
        private var x: [Double] = []
        private var dx: [Double] = []

        init(_ minCutoff: Double, _ beta: Double, _ dCutoff: Double) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.dCutoff = dCutoff
        }

        private static func alpha(_ dt: Double, _ cutoff: Double) -> Double {
            let tau = 1.0 / (2 * Double.pi * cutoff)
            return 1.0 / (1.0 + tau / dt)
        }

        mutating func callAsFunction(_ value: [Double], _ time: Double) -> [Double] {
            guard let last = t else {
                t = time
                x = value
                dx = value.map { _ in 0 }
                return value
            }
            let dt = max(time - last, 1e-6)
            let aD = Self.alpha(dt, dCutoff)
            var dxHat = [Double](repeating: 0, count: value.count)
            var norm = 0.0
            for i in value.indices {
                dxHat[i] = aD * (value[i] - x[i]) / dt + (1 - aD) * dx[i]
                norm += dxHat[i] * dxHat[i]
            }
            let a = Self.alpha(dt, minCutoff + beta * norm.squareRoot())
            var xHat = value
            for i in value.indices { xHat[i] = a * value[i] + (1 - a) * x[i] }
            t = time
            x = xHat
            dx = dxHat
            return xHat
        }
    }

    /// 0 when the eye is closed, 1 when open, smooth in between.
    static func blinkFactor(_ openness: CGFloat, closed: CGFloat = 0.10, open: CGFloat = 0.20) -> CGFloat {
        let t = min(max((openness - closed) / (open - closed), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private final class Track {
        var centerFilter: OneEuroFilter
        var radiusFilter: OneEuroFilter
        var eye: IrisEye
        var lastSeen: Double
        var openness: CGFloat
        var visibility: CGFloat = 0
        var seenNow = true

        init(_ eye: IrisEye, _ t: Double, _ cf: OneEuroFilter, _ rf: OneEuroFilter) {
            centerFilter = cf
            radiusFilter = rf
            self.eye = eye
            lastSeen = t
            openness = eye.openness
            _ = centerFilter([Double(eye.center.x), Double(eye.center.y)], t)
            _ = radiusFilter([Double(eye.radius)], t)
        }
    }

    /// camrelay's EyeTracker, fed per-frame detections; also driven directly by the self-test with synthetic eyes.
    final class Smoother {
        let fadeSeconds: Double
        let forgetSeconds: Double
        private let centerParams: (Double, Double, Double)
        private let radiusParams: (Double, Double, Double)
        private var tracks: [Track] = []
        private var lastTime: Double?

        init(fadeSeconds: Double = 0.1, forgetSeconds: Double = 0.4,
             centerFilter: (Double, Double, Double) = (0.3, 0.05, 0.3),
             radiusFilter: (Double, Double, Double) = (0.3, 0.02, 0.3)) {
            self.fadeSeconds = fadeSeconds
            self.forgetSeconds = forgetSeconds
            centerParams = centerFilter
            radiusParams = radiusFilter
        }

        private func newTrack(_ eye: IrisEye, _ t: Double) -> Track {
            Track(eye, t, OneEuroFilter(centerParams.0, centerParams.1, centerParams.2),
                  OneEuroFilter(radiusParams.0, radiusParams.1, radiusParams.2))
        }

        /// This frame's detections in; smoothed eyes out, with `alpha` set.
        func update(_ eyes: [IrisEye], at t: Double) -> [IrisEye] {
            let dt = lastTime.map { max(t - $0, 0) } ?? 0
            lastTime = t
            for tr in tracks { tr.seenNow = false }

            // Greedy nearest matching of detections to existing tracks, ties broken by detection then track order.
            var pairs: [(d: CGFloat, i: Int, j: Int)] = []
            for (i, e) in eyes.enumerated() {
                for (j, tr) in tracks.enumerated() {
                    pairs.append((hypot(e.center.x - tr.eye.center.x, e.center.y - tr.eye.center.y), i, j))
                }
            }
            pairs.sort { ($0.d, $0.i, $0.j) < ($1.d, $1.i, $1.j) }
            var usedE = Set<Int>(), usedT = Set<Int>()
            for (d, i, j) in pairs {
                if usedE.contains(i) || usedT.contains(j) || d > 2.5 * max(eyes[i].radius, 1) { continue }
                usedE.insert(i)
                usedT.insert(j)
                let tr = tracks[j], e = eyes[i]
                let c = tr.centerFilter([Double(e.center.x), Double(e.center.y)], t)
                let r = tr.radiusFilter([Double(e.radius)], t)[0]
                tr.openness = 0.5 * tr.openness + 0.5 * e.openness
                var smoothed = e
                smoothed.center = CGPoint(x: c[0], y: c[1])
                smoothed.radius = CGFloat(r)
                tr.eye = smoothed
                tr.lastSeen = t
                tr.seenNow = true
            }
            for (i, e) in eyes.enumerated() where !usedE.contains(i) { tracks.append(newTrack(e, t)) }

            let step = CGFloat(fadeSeconds > 0 ? dt / fadeSeconds : 1)
            for tr in tracks {
                let target: CGFloat = tr.seenNow ? 1 : 0
                if tr.visibility < target {
                    tr.visibility = dt > 0 ? min(target, tr.visibility + step) : target
                } else {
                    tr.visibility = max(target, tr.visibility - step)
                }
            }
            tracks = tracks.filter { $0.seenNow || (t - $0.lastSeen) < forgetSeconds && $0.visibility > 0 }
            return tracks.map { tr in
                var e = tr.eye
                e.alpha = tr.visibility * EyeTracker.blinkFactor(tr.openness)
                return e
            }
        }
    }
}

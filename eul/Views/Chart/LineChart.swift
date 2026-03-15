//
//  LineChart.swift
//  eul
//
//  Created by Gao Sun on 2020/11/8.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

struct LineChart: View {
    static var defaultMaxPointCount = 10
    static let minimumLineHeight: CGFloat = 0.5

    var points: [Double] = []
    var maxPointCount = defaultMaxPointCount
    var maximumPoint: Double = 100
    var minimumPoint: Double = 0
    var frame = CGSize(width: (AppDelegate.statusBarHeight - 4) * 1.75, height: AppDelegate.statusBarHeight - 4)

    var stepX: CGFloat {
        frame.width / (CGFloat(maxPointCount) - 1)
    }

    func getY(_ value: Double) -> CGFloat {
        CGFloat((value - minimumPoint) / (maximumPoint - minimumPoint)) * frame.height
    }

    @State private var cachedPath: Path?
    @State private var cachedPoints: [Double]?

    // Catmull-Rom spline implementation (pure Swift) to avoid SpriteKit allocations.
    // Produces interpolated points between consecutive samples with a configurable
    // pixel step to control density and allocations.
    private func computePath() -> Path {
        guard points.count > 1 else { return Path() }

        let n = points.count
        let yPoints = points.map { getY($0) }
        let maxX = stepX * CGFloat(n - 1)

        // Sampling resolution in pixels (increase to reduce allocations)
        let sampleStep: CGFloat = 1.0

        var path = Path()
        var didMove = false

        func catmullRom(_ p0: CGFloat, _ p1: CGFloat, _ p2: CGFloat, _ p3: CGFloat, _ t: CGFloat) -> CGFloat {
            // 0.5 tension for centripetal Catmull-Rom (standard)
            let t2 = t * t
            let t3 = t2 * t
            return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
        }

        for i in 0..<(n - 1) {
            let x1 = stepX * CGFloat(i)
            let x2 = stepX * CGFloat(i + 1)
            let segLen = x2 - x1

            // control points for Catmull-Rom
            let p0 = i - 1 >= 0 ? yPoints[i - 1] : yPoints[i]
            let p1 = yPoints[i]
            let p2 = yPoints[i + 1]
            let p3 = i + 2 < n ? yPoints[i + 2] : yPoints[i + 1]

            let samples = max(1, Int(ceil(segLen / sampleStep)))
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples)
                let y = max(LineChart.minimumLineHeight, catmullRom(p0, p1, p2, p3, t))
                let x = x1 + t * segLen
                let pt = CGPoint(x: x, y: y)
                if !didMove {
                    path.move(to: pt)
                    didMove = true
                } else {
                    path.addLine(to: pt)
                }
            }
        }

        // Ensure last point is appended
        let last = CGPoint(x: maxX, y: max(LineChart.minimumLineHeight, yPoints.last ?? 0))
        if !didMove {
            path.move(to: last)
        } else {
            path.addLine(to: last)
        }

        return path
    }

    func path() -> Path {
        if cachedPoints == points, let cached = cachedPath {
            return cached
        }
        let newPath = computePath()
        cachedPoints = points
        cachedPath = newPath
        return newPath
    }

    func closedPath() -> Path {
        guard points.count > 1 else {
            return Path()
        }

        var path = self.path()
        path.addLine(to: CGPoint(x: stepX * CGFloat(points.count - 1), y: 0))
        path.addLine(to: CGPoint.zero)
        path.closeSubpath()

        return path
    }

    var body: some View {
        ZStack {
            Group {
                closedPath()
                    .fill(Color.text)
                path()
                    .stroke(Color.text, style: StrokeStyle(lineWidth: LineChart.minimumLineHeight, lineJoin: .round))
            }
            .rotationEffect(.degrees(180), anchor: .center)
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: frame.width, height: frame.height, alignment: .center)
    }
}

struct LineChart_Preview: PreviewProvider {
    static var previews: LineChart {
        LineChart(points: [10, 10, 10, 20, 20, 20, 30, 30, 30, 80])
    }
}

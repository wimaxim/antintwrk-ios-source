// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct AntintwrkSignalArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let animated: Bool
    
    private let branches: [[CGPoint]] = [
        [.init(x: 800, y: 210), .init(x: 800, y: 134), .init(x: 706, y: 134), .init(x: 642, y: 107), .init(x: 448, y: 107), .init(x: 366, y: 58), .init(x: 176, y: 58), .init(x: 112, y: 30), .init(x: 0, y: 30)],
        [.init(x: 800, y: 210), .init(x: 800, y: 155), .init(x: 658, y: 155), .init(x: 578, y: 181), .init(x: 372, y: 181), .init(x: 274, y: 133), .init(x: 104, y: 133)],
        [.init(x: 800, y: 210), .init(x: 800, y: 142), .init(x: 744, y: 142), .init(x: 656, y: 178), .init(x: 500, y: 178), .init(x: 414, y: 148), .init(x: 288, y: 148)]
    ]
    
    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated || reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                for (index, points) in branches.enumerated() {
                    for mirrored in [false, true] {
                        let path = Path { path in
                            for (offset, point) in points.enumerated() {
                                let scaled = CGPoint(x: (mirrored ? 1600 - point.x : point.x) / 1600 * size.width,
                                                     y: point.y / 210 * size.height)
                                if offset == 0 {
                                    path.move(to: scaled)
                                } else {
                                    path.addLine(to: scaled)
                                }
                            }
                        }
                        let color = index == 2 ? Color(red: 0.941, green: 0.42, blue: 0.333) : Color(red: 0.41, green: 0.78, blue: 0.74)
                        context.stroke(path, with: .color(color.opacity(0.28)), style: .init(lineWidth: 1.2, lineCap: .round))
                        if animated, !reduceMotion, scenePhase == .active {
                            let phase = (timeline.date.timeIntervalSinceReferenceDate / 8 + Double(index) * 0.19 + (mirrored ? 0.12 : 0)).truncatingRemainder(dividingBy: 1)
                            var glowing = context
                            glowing.addFilter(.shadow(color: color, radius: 6))
                            glowing.stroke(path.trimmedPath(from: max(0, phase - 0.12), to: phase),
                                           with: .color(color.opacity(0.95)), style: .init(lineWidth: 2.2, lineCap: .round))
                        }
                    }
                }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.28),
                                     .init(color: .white, location: 0.88), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

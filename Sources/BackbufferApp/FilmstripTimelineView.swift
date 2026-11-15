import AppKit
import BackbufferCore
import SwiftUI

/// Interactive Medal-amber filmstrip timeline with dual start/end trim handles,
/// playhead scrubbing, and dimmed out-of-range masks.
struct FilmstripTimelineView: View {
    let durationSeconds: Double
    @Binding var trimRange: TrimRange
    @Binding var playheadSeconds: Double
    let thumbnails: [NSImage]
    let onScrub: (Double) -> Void

    @State private var activeDragStartOrigin: Double?
    @State private var activeDragEndOrigin: Double?

    private let handleWidth: CGFloat = 14
    private let trackHeight: CGFloat = 56

    private var safeDuration: Double {
        max(0.5, durationSeconds)
    }

    private var minimumSpan: Double {
        min(1.0, safeDuration * 0.2)
    }

    private var isTrimModified: Bool {
        trimRange.startSeconds > 0.05 || trimRange.endSeconds < (safeDuration - 0.05)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Top timing telemetry row
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("IN")
                        .font(Theme.mono(10, weight: .bold))
                        .foregroundColor(Theme.amber)
                    Text(Theme.formatPreciseTime(trimRange.startSeconds))
                        .font(Theme.mono(11.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )

                HStack(spacing: 5) {
                    Text("OUT")
                        .font(Theme.mono(10, weight: .bold))
                        .foregroundColor(Theme.amber)
                    Text(Theme.formatPreciseTime(trimRange.endSeconds))
                        .font(Theme.mono(11.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )

                Spacer()

                Text("Selection: \(String(format: "%.1fs", trimRange.durationSeconds)) / \(String(format: "%.1fs", safeDuration))")
                    .font(Theme.mono(11.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                if isTrimModified {
                    Button {
                        trimRange = TrimRange(startSeconds: 0, endSeconds: safeDuration)
                        playheadSeconds = 0
                        onScrub(0)
                    } label: {
                        Text("Reset")
                            .font(Theme.tabular(11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.surfaceElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Filmstrip track + handles
            GeometryReader { geo in
                let usableWidth = max(40, geo.size.width - handleWidth * 2)
                let startFraction = clampedFraction(trimRange.startSeconds / safeDuration)
                let endFraction = clampedFraction(trimRange.endSeconds / safeDuration)
                let playFraction = clampedFraction(playheadSeconds / safeDuration)

                let leftX = handleWidth + usableWidth * startFraction
                let rightX = handleWidth + usableWidth * endFraction
                let playX = handleWidth + usableWidth * playFraction

                ZStack(alignment: .leading) {
                    // Base thumbnail strip
                    HStack(spacing: 1) {
                        if thumbnails.isEmpty {
                            ForEach(0..<10, id: \.self) { index in
                                Rectangle()
                                    .fill(
                                        index.isMultiple(of: 2)
                                            ? Theme.surfaceElevated
                                            : Theme.surfaceSubtle
                                    )
                            }
                        } else {
                            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    )
                                    .clipped()
                            }
                        }
                    }
                    .frame(width: usableWidth, height: trackHeight)
                    .offset(x: handleWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                            .frame(width: usableWidth, height: trackHeight)
                            .offset(x: handleWidth)
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let rel = (value.location.x - handleWidth) / usableWidth
                                let t = clampedFraction(rel) * safeDuration
                                playheadSeconds = t
                                onScrub(t)
                            }
                    )

                    // Dimmed left mask (trimmed out)
                    if leftX > handleWidth {
                        Rectangle()
                            .fill(Color.black.opacity(0.62))
                            .frame(width: max(0, leftX - handleWidth), height: trackHeight)
                            .offset(x: handleWidth)
                            .allowsHitTesting(false)
                    }

                    // Dimmed right mask (trimmed out)
                    if rightX < handleWidth + usableWidth {
                        Rectangle()
                            .fill(Color.black.opacity(0.62))
                            .frame(width: max(0, (handleWidth + usableWidth) - rightX), height: trackHeight)
                            .offset(x: rightX)
                            .allowsHitTesting(false)
                    }

                    // Top & Bottom amber active selection rails
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Theme.amber)
                            .frame(height: 3)
                        Spacer()
                        Rectangle()
                            .fill(Theme.amber)
                            .frame(height: 3)
                    }
                    .frame(width: max(2, rightX - leftX), height: trackHeight)
                    .offset(x: leftX)
                    .allowsHitTesting(false)

                    // Playhead line
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 8, height: 5)
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .shadow(color: Color.black.opacity(0.75), radius: 2, x: 0, y: 0)
                    }
                    .frame(height: trackHeight + 8)
                    .position(x: playX, y: trackHeight / 2)
                    .allowsHitTesting(false)

                    // Left IN handle
                    trimHandleView(isLeading: true)
                        .frame(width: handleWidth, height: trackHeight + 4)
                        .position(x: leftX - handleWidth / 2, y: trackHeight / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if activeDragStartOrigin == nil {
                                        activeDragStartOrigin = trimRange.startSeconds
                                    }
                                    let origin = activeDragStartOrigin ?? trimRange.startSeconds
                                    let deltaSec = (value.translation.width / usableWidth) * safeDuration
                                    let maxStart = max(0, trimRange.endSeconds - minimumSpan)
                                    let nextStart = min(max(0, origin + deltaSec), maxStart)
                                    trimRange.startSeconds = nextStart
                                    if playheadSeconds < nextStart {
                                        playheadSeconds = nextStart
                                    }
                                    onScrub(nextStart)
                                }
                                .onEnded { _ in
                                    activeDragStartOrigin = nil
                                }
                        )

                    // Right OUT handle
                    trimHandleView(isLeading: false)
                        .frame(width: handleWidth, height: trackHeight + 4)
                        .position(x: rightX + handleWidth / 2, y: trackHeight / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if activeDragEndOrigin == nil {
                                        activeDragEndOrigin = trimRange.endSeconds
                                    }
                                    let origin = activeDragEndOrigin ?? trimRange.endSeconds
                                    let deltaSec = (value.translation.width / usableWidth) * safeDuration
                                    let minEnd = min(safeDuration, trimRange.startSeconds + minimumSpan)
                                    let nextEnd = max(min(safeDuration, origin + deltaSec), minEnd)
                                    trimRange.endSeconds = nextEnd
                                    if playheadSeconds > nextEnd {
                                        playheadSeconds = nextEnd
                                    }
                                    onScrub(nextEnd)
                                }
                                .onEnded { _ in
                                    activeDragEndOrigin = nil
                                }
                        )
                }
                .frame(height: trackHeight)
            }
            .frame(height: trackHeight + 6)
        }
    }

    private func trimHandleView(isLeading: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.amber)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.amberInk.opacity(0.78))
                .frame(width: 2, height: 18)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 3, x: isLeading ? -1 : 1, y: 0)
        .accessibilityLabel(isLeading ? "Trim Start Handle" : "Trim End Handle")
    }

    private func clampedFraction(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(1.0, max(0.0, value)))
    }
}

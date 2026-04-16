import SwiftUI

struct TransportBarView: View {
    @ObservedObject var vm: ViewerViewModel

    private var canScrub: Bool {
        // scrub имеет смысл только для файла + когда есть длительность
        vm.sourceMode == .file && vm.durationSeconds > 0.01
    }

    private var sliderUpperBound: Double {
        max(vm.durationSeconds, 0.01) // чтобы Slider не получал 0...0
    }

    var body: some View {
        VStack(spacing: 8) {

            // ───────── Top bar: fixed layout (no jumping) ─────────
            HStack(spacing: 10) {

                Text("TRANSPORT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 110, alignment: .leading)

                Spacer(minLength: 10)

                // center controls (fixed-width zone so it never shifts)
                HStack(spacing: 10) {
                    Button { vm.togglePlayPause() } label: {
                        Text(vm.isPlaying ? "Pause" : "Play")
                            .frame(width: 86)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.tint)

                    Toggle("Loop", isOn: $vm.isLooping)
                        .toggleStyle(.switch)
                        .tint(AppTheme.tint)
                }
                .frame(width: 220, alignment: .center)

                Spacer(minLength: 10)

                // right info (fixed width so Play/Loop never jumps)
                Text(vm.sourceInfoText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 360, alignment: .trailing)
            }

            // ───────── Scrubber (ALWAYS visible; disabled when not usable) ─────────
            HStack(spacing: 10) {

                Text(time(canScrub ? vm.scrubSeconds : 0))
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 60, alignment: .leading)

                Slider(
                    value: $vm.scrubSeconds,
                    in: 0...sliderUpperBound,
                    onEditingChanged: { editing in
                        guard canScrub else { return }
                        vm.isScrubbing = editing
                        if editing == false {
                            vm.scrubCommit()
                        }
                    }
                )
                .tint(AppTheme.tint)

                Text("-\(time(canScrub ? max(0, vm.durationSeconds - vm.scrubSeconds) : 0))")
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(width: 72, alignment: .trailing)
            }
            .disabled(!canScrub)
            .opacity(canScrub ? 1.0 : 0.45)
            .allowsHitTesting(canScrub)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.tint)
        .background(Color.black)
    }
}

// MARK: - Time formatting
private func time(_ s: Double) -> String {
    let total = max(0, Int(s.rounded()))
    let m = total / 60
    let sec = total % 60
    return String(format: "%02d:%02d", m, sec)
}

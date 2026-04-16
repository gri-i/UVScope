import SwiftUI

struct ContentView: View {
    @StateObject private var vm = ViewerViewModel()

    // ✅ notification for Cmd+L from menu
    private let lockNote = Notification.Name("uvscope.toggleCameraLock")

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if !vm.isSidebarCollapsed {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    vm.isSidebarCollapsed = true
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .padding(6)
                                    .background(
                                        Circle()
                                            .fill(AppTheme.barBackground.opacity(0.5))
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 10)
                            .padding(.top, 10)
                        }
                        
                        SourcePanelView(vm: vm)
                    }
                    .frame(width: 300) // фиксированная ширина панели
                } else {
                    VStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                vm.isSidebarCollapsed = false
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                                .padding(6)
                                .background(
                                    Circle()
                                        .fill(AppTheme.barBackground.opacity(0.5))
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                    }
                    .frame(width: 40)
                    .background(AppTheme.appBackground)
                }

                viewerPane
            }

            TransportBarView(vm: vm)
        }
        .background(AppTheme.appBackground)
        .ignoresSafeArea()
        .onAppear {
            vm.start()
        }
        .onDisappear {
            vm.stop()
        }
        // ✅ receives Cmd+L from App menu
        .onReceive(NotificationCenter.default.publisher(for: lockNote)) { _ in
            vm.isCameraLocked.toggle()
        }
        // ✅ kill macOS blue accent everywhere
        .tint(AppTheme.tint)
        .accentColor(AppTheme.tint)
        // Optional: make default buttons consistent (no "prominent blue" surprises)
        .buttonStyle(.bordered)
        .alert("Model import failed", isPresented: $vm.showValidationAlert) {
            Button("OK") {
                vm.showValidationAlert = false
            }
        } message: {
            Text(vm.validationErrors.joined(separator: "\n\n"))
        }
    }

    private var viewerPane: some View {
        ZStack {
            AppTheme.metalBackground
            MetalViewRepresentable(vm: vm)

            // ✅ TOP-LEFT watermark (always above everything)
            if vm.isCameraLocked {
                Text("Camera Locked")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.barBackground.opacity(0.85))
                    .cornerRadius(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(1000)
            }
        }
    }
}

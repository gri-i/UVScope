import SwiftUI

struct SourcePanelView: View {
    @ObservedObject var vm: ViewerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            // ✅ MODEL (OBJ / FBX)
            DisclosureGroup(isExpanded: $vm.isModelExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Model", selection: $vm.modelKind) {
                        ForEach(ModelKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Text(modelFilenameText)
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)

                        Spacer()

                        Button("Clean") { vm.cleanScene() }

                        Button("Fit") { vm.requestFit() }

                        Button("Choose…") {
                            if vm.modelKind == .obj {
                                vm.pickOBJFile()
                            } else {
                                vm.pickFBXFile()
                            }
                        }
                    }

                    // Status text (warning/info) — no alerts
                    Text(vm.modelStatusText)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)

                    // ✅ FBX cameras UI appears only in FBX mode
                    if vm.modelKind == .fbx {
                        header("FBX CAMERAS")

                        HStack(spacing: 10) {
                            Text(vm.fbxCameraStatus)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }

                        Picker("Camera", selection: $vm.selectedFBXCameraIndex) {
                            Text("Default").tag(-1)

                            // Use real names from FBX (already sanitized in vm.fbxCameraNames)
                            ForEach(Array(vm.fbxCameras.indices), id: \.self) { idx in
                                Text(vm.fbxCameraNames[idx]).tag(idx)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(vm.fbxCameras.isEmpty)
                        .opacity(vm.fbxCameras.isEmpty ? 0.5 : 1.0)
                    }

                    header("FACES")
                    Picker("Faces", selection: $vm.faceMode) {
                        ForEach(FaceMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.menu)

                    header("INACTIVE SIDE")
                    Picker("Inactive", selection: $vm.inactiveSideMode) {
                        ForEach(InactiveSideMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    header("CAMERA")
                    HStack {
                        Text("FOV").font(.caption).foregroundStyle(AppTheme.secondaryText)
                        Slider(value: $vm.fovDegrees, in: 5...120, step: 1)
                            // Keep your existing rule: when FBX camera selected, lock FOV
                            .disabled(vm.selectedFBXCameraIndex >= 0)
                        Text("\(Int(vm.fovDegrees))°")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Show UV Grid", isOn: $vm.showUVGrid)

                    HStack {
                        Text("UV Density").font(.caption).foregroundStyle(AppTheme.secondaryText)
                        Slider(value: $vm.uvGridDensity, in: 1...80, step: 1)
                        Text("\(Int(vm.uvGridDensity))")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 36, alignment: .trailing)
                    }
                    .disabled(!vm.showUVGrid)
                    .opacity(vm.showUVGrid ? 1 : 0.5)
                }
            } label: {
                header("MODEL")
            }

            Divider().overlay(AppTheme.divider).opacity(1)

            // ✅ VENUE (additional static meshes)
            DisclosureGroup(isExpanded: $vm.isVenueExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Add…") {
                            vm.pickVenueFiles()
                        }

                        Spacer()
                    }

                    if vm.venues.isEmpty {
                        Text("No venue geometry")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        ForEach(vm.venues) { venue in
                            HStack(spacing: 8) {
                                Text(venue.url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(1)

                                Spacer()

                                Toggle("Visible", isOn: Binding(
                                    get: { venue.visible },
                                    set: { vm.setVenueVisible(id: venue.id, visible: $0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(AppTheme.tint)

                                Button("Clear") {
                                    vm.clearVenue(id: venue.id)
                                }
                            }
                        }
                    }
                }
            } label: {
                header("VENUE")
            }

            Divider().overlay(AppTheme.divider).opacity(1)

            DisclosureGroup(isExpanded: $vm.isSourceExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Mode", selection: $vm.sourceMode) {
                        Text("NDI").tag(SourceMode.ndi)
                        Text("File").tag(SourceMode.file)
                        Text("Image").tag(SourceMode.image)
                    }
                    .pickerStyle(.segmented)

                    Group {
                        if vm.sourceMode == .ndi {
                            header("NDI SOURCES")

                            Picker("NDI", selection: Binding(
                                get: { vm.selectedNDIIndex },
                                set: { vm.selectedNDIIndex = $0 }
                            )) {
                                Text("—").tag(-1)
                                ForEach(Array(vm.ndiSourcesDisplay.enumerated()), id: \.offset) { idx, name in
                                    Text(name).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack {
                                Button("Refresh") { vm.refreshNDISources() }
                                Spacer()
                                Text(vm.receiver.lastFrameSize == .zero ? "—" : "\(Int(vm.receiver.lastFrameSize.width))×\(Int(vm.receiver.lastFrameSize.height))")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }

                        if vm.sourceMode == .file {
                            header("VIDEO FILE")
                            HStack {
                                Text(vm.fileURL?.lastPathComponent ?? "No file selected")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                                Button("Choose…") { vm.pickVideoFile() }
                            }
                        }

                        if vm.sourceMode == .image {
                            header("IMAGE")
                            HStack {
                                Text(vm.imageURL?.lastPathComponent ?? "No image selected")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                                Button("Choose…") { vm.pickImageFile() }
                            }
                        }
                    }
                }
            } label: {
                header("SOURCE")
            }

            Divider().overlay(AppTheme.divider).opacity(1)

            // ✅ CAPTURE
            DisclosureGroup(isExpanded: $vm.isCaptureExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(vm.captureFolderURL?.lastPathComponent ?? "No folder")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Button("Folder…") { vm.pickCaptureFolder() }
                    }

                    HStack(spacing: 10) {
                        Button("Screenshot") { vm.takeScreenshot() }

                        Button(vm.isRecording ? "Stop" : "Record H.264") {
                            vm.toggleRecording()
                        }
                        .tint(vm.isRecording ? .red : AppTheme.tint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke((vm.isRecording ? Color.red : AppTheme.tint).opacity(0.65), lineWidth: 1)
                        )
                        
                        Button {
                            vm.isMicEnabled.toggle()
                        } label: {
                            Image(systemName: vm.isMicEnabled ? "mic.fill" : "mic.slash")
                        }
                        .tint(vm.isMicEnabled ? .orange : AppTheme.secondaryText)
                        .help("Microphone on/off")
                        .disabled(vm.isRecording)
                    }

                    // Audio meters & gain controls
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Mic")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 36, alignment: .leading)
                            ProgressView(value: Double(vm.micLevel), total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                            Text("\(Int(vm.micGainDB)) dB")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 44, alignment: .trailing)
                        }
                        Slider(value: $vm.micGainDB, in: -6...12, step: 1)
                            .disabled(!vm.isMicEnabled)

                        HStack {
                            Text("Video")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 36, alignment: .leading)
                            ProgressView(value: Double(vm.videoLevel), total: 1.0)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: .infinity)
                            Text("\(Int(vm.videoGainDB)) dB")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 44, alignment: .trailing)
                        }
                        Slider(value: $vm.videoGainDB, in: -24...6, step: 1)
                            .disabled(!(vm.sourceMode == .file && vm.activeSource is FileTextureSource))
                    }

                    Text(vm.lastCaptureMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                }
            } label: {
                header("CAPTURE")
            }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .scrollIndicators(.never)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.tint)
        .accentColor(AppTheme.tint)
        .buttonStyle(.bordered)
    }

    private var modelFilenameText: String {
        switch vm.modelKind {
        case .obj:
            return vm.objURL?.lastPathComponent ?? "No OBJ selected"
        case .fbx:
            return vm.fbxURL?.lastPathComponent ?? "No FBX selected"
        }
    }

    private func header(_ t: String) -> some View {
        Text(t)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.top, 2)
    }
}

// ViewerViewModel.swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import simd
import AVFoundation

enum SourceMode: String {
    case ndi, file, image
}

enum FaceMode: String, CaseIterable, Identifiable {
    case both, front, back
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Both"
        case .front: return "Front"
        case .back: return "Back"
        }
    }
}

enum InactiveSideMode: String, CaseIterable, Identifiable {
    case gray
    case hide

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gray: return "Gray"
        case .hide: return "Hide"
        }
    }
}

/// ✅ New: scene model type selection (OBJ vs FBX)
enum ModelKind: String, CaseIterable, Identifiable {
    case obj
    case fbx
    var id: String { rawValue }

    var title: String {
        switch self {
        case .obj: return "OBJ"
        case .fbx: return "FBX"
        }
    }

    var persisted: PersistedModelKind {
        switch self {
        case .obj: return .obj
        case .fbx: return .fbx
        }
    }
}

/// Additional static geometry in the scene (e.g. venue/architecture).
struct VenueEntry: Identifiable {
    let id = UUID()
    let url: URL
    var mesh: Mesh
    var visible: Bool
}

@MainActor
final class ViewerViewModel: ObservableObject {
    // Existing receiver (your file)
    @Published var receiver = NDIReceiver()

    // ✅ Camera lock state for UI + controls
    @Published var isCameraLocked: Bool = false

    // UI state
    @Published var sourceMode: SourceMode = .ndi { didSet { rebuildSource() } }
    @Published var isPlaying: Bool = true { didSet { activeSource?.setPlaying(isPlaying) } }
    @Published var isLooping: Bool = true { didSet { activeSource?.setLooping(isLooping) } }

    @Published var showUVGrid: Bool = false
    @Published var uvGridDensity: Double = 20

    @Published var showFloorGrid: Bool = true

    @Published var faceMode: FaceMode = .both
    @Published var inactiveSideMode: InactiveSideMode = .gray

    // Keep vertical FOV (as you said)
    @Published var fovDegrees: Float = 50 { didSet { camera.fovDegrees = fovDegrees } }

    @Published var scrubSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var isScrubbing: Bool = false
    @Published var fitRequestID: Int = 0

    // ✅ New: model kind (OBJ/FBX) picked in UI
    @Published var modelKind: ModelKind = .obj

    // ✅ Model status (warning/info text in UI, NOT alert)
    @Published var modelStatusText: String = "Model: —"
    
    // ✅ Validation errors (shown in alert)
    @Published var validationErrors: [String] = []
    @Published var showValidationAlert: Bool = false

    // ✅ VENUE: additional static meshes (always gray shaded, independent of source)
    @Published var venues: [VenueEntry] = [] {
        didSet {
            // Whenever venue list or visibilities change, push combined meshes to renderer.
            let meshes = venues.filter { $0.visible }.map { $0.mesh }
            captureBridge?.setVenueMeshes(meshes)
            Persistence.saveVenues(venues.map { ($0.url, $0.visible) })
        }
    }

    // ✅ FBX Cameras
    @Published var fbxURL: URL? = nil
    @Published var fbxCameras: [FBXImportedCamera] = []
    @Published var selectedFBXCameraIndex: Int = -1 { didSet { applySelectedFBXCamera() } }

    // IMPORTANT: UI expects this name
    @Published var fbxCameraStatus: String = "FBX: —"

    var fbxCameraNames: [String] {
        fbxCameras.enumerated().map { idx, cam in
            let raw = (cam.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "Camera \(idx + 1)" : raw
        }
    }

    // ✅ CAPTURE
    @Published var captureFolderURL: URL? = nil
    @Published var captureFPS: Int = 30
    @Published var isRecording: Bool = false
    @Published var isMicEnabled: Bool = false {
        didSet {
            if isMicEnabled, !isRecording, #available(macOS 13.0, *) {
                prewarmMic()
            }
        }
    }
    @Published var lastCaptureMessage: String = "Renderer not ready yet."
    
    // Capture audio controls / meters
    @Published var micGainDB: Float = 6.0          // UI control, dB
    @Published var videoGainDB: Float = -8.0       // UI control, dB
    @Published var micLevel: Float = 0.0           // 0...1
    @Published var videoLevel: Float = 0.0         // 0...1
    
    // Collapsible sections state
    @Published var isSourceExpanded: Bool = true
    @Published var isModelExpanded: Bool = true
    @Published var isCaptureExpanded: Bool = true
    @Published var isVenueExpanded: Bool = false
    
    // Sidebar collapse state
    @Published var isSidebarCollapsed: Bool = false

    private weak var captureBridge: MetalRenderer?
    
    @available(macOS 13.0, *)
    private lazy var audioCapture: AudioCapture = AudioCapture()

    func setCaptureBridge(_ b: MetalRenderer?) {
        captureBridge = b
        lastCaptureMessage = (b == nil) ? "Renderer not ready yet." : "Ready."
    }

    func requestFit() { fitRequestID &+= 1 }

    private var uiTimer: Timer?
    private var gridObserver: NSObjectProtocol?

    // Files
    @Published var objURL: URL? { didSet { loadOBJ() } }
    @Published var fileURL: URL? { didSet { rebuildSource() } }
    @Published var imageURL: URL? { didSet { rebuildSource() } }

    // Renderer inputs
    @Published private(set) var mesh: Mesh?
    @Published private(set) var activeSource: (any TextureSource)?

    // ✅ Shared camera instance
    let camera = OrbitCamera()

    var ndiSourcesDisplay: [String] { receiver.sources }

    var selectedNDIIndex: Int {
        get { receiver.selectedIndex }
        set {
            receiver.connect(index: newValue)
            rebuildSource()
        }
    }

    var sourceInfoText: String {
        switch sourceMode {
        case .ndi:
            if receiver.selectedIndex >= 0, receiver.selectedIndex < receiver.sources.count {
                return "NDI: \(receiver.sources[receiver.selectedIndex])"
            }
            return "NDI: none"
        case .file:
            return fileURL?.lastPathComponent ?? "File: none"
        case .image:
            return imageURL?.lastPathComponent ?? "Image: none"
        }
    }

    // MARK: - Safe Mode / Watchdog

    private enum LaunchKeys {
        static let launchInProgress = "uvscope.launchInProgress"
    }

    private func isShiftPressedOnLaunch() -> Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func markLaunchStarted() {
        UserDefaults.standard.set(true, forKey: LaunchKeys.launchInProgress)
    }

    private func markLaunchFinishedOK() {
        UserDefaults.standard.set(false, forKey: LaunchKeys.launchInProgress)
    }

    private func wasPreviousLaunchInProgress() -> Bool {
        UserDefaults.standard.bool(forKey: LaunchKeys.launchInProgress)
    }

    private func startUITimerIfNeeded() {
        uiTimer?.invalidate()

        // Swift 6: Timer closure is @Sendable -> hop to MainActor explicitly
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isScrubbing else { return }
                guard self.sourceMode == .file else { return }
                guard let s = self.activeSource else { return }

                if let d = s.durationSeconds() { self.durationSeconds = d }
                if let t = s.currentTimeSeconds() { self.scrubSeconds = t }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        let prevBad = wasPreviousLaunchInProgress()
        markLaunchStarted()

        // Observe ⌘G (menu) -> toggle grid
        if gridObserver == nil {
            let note = Notification.Name("uvscope.toggleFloorGrid")
            gridObserver = NotificationCenter.default.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.showFloorGrid.toggle()
                }
            }
        }

        // Restore last camera
        if let cam = Persistence.restoreLastCameraState() {
            camera.apply(state: cam)
            fovDegrees = camera.fovDegrees
        } else {
            camera.fovDegrees = fovDegrees
        }

        if isShiftPressedOnLaunch() || prevBad {
            if prevBad {
                Persistence.clearLastModel()
            }

            receiver.startDiscovery()
            rebuildSource()
            startUITimerIfNeeded()

            lastCaptureMessage = prevBad
                ? "Safe Mode: last model cleared (previous launch did not finish)."
                : "Safe Mode: model loading skipped (Shift)."

            markLaunchFinishedOK()
            return
        }

        // ✅ Autoload last model of any kind
        if objURL == nil, fbxURL == nil, let last = Persistence.restoreLastModel() {
            switch last.kind {
            case .obj:
                modelKind = .obj
                objURL = last.url
            case .fbx:
                modelKind = .fbx
                fbxURL = last.url
                // FBX is now a scene source: load cameras now; mesh will be added next step
                loadFBXScene(from: last.url)
            }
        }

        // ✅ Restore capture folder if available
        if let captureDir = Persistence.restoreCaptureFolder() {
            captureFolderURL = captureDir
            lastCaptureMessage = "Folder: \(captureDir.lastPathComponent)"
        }

        // ✅ Restore VENUE geometry (best-effort; silently skips missing/bad files)
        let restoredVenues = Persistence.restoreVenues()
        if !restoredVenues.isEmpty {
            for entry in restoredVenues {
                importVenue(from: entry.url)
                if let lastId = venues.last?.id {
                    setVenueVisible(id: lastId, visible: entry.visible)
                }
            }
        }

        receiver.startDiscovery()
        rebuildSource()
        startUITimerIfNeeded()
        markLaunchFinishedOK()
    }

    func stop() {
        uiTimer?.invalidate()
        uiTimer = nil

        activeSource?.stop()
        receiver.stop()

        Persistence.stopAccessLastModelIfNeeded()
        Persistence.stopAccessCaptureFolderIfNeeded()

        if let o = gridObserver {
            NotificationCenter.default.removeObserver(o)
            gridObserver = nil
        }

        markLaunchFinishedOK()
    }

    // MARK: - VENUE helpers

    /// Add one or more venue meshes (OBJ/FBX) via open panel.
    func pickVenueFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        var types: [UTType] = []
        if let obj = UTType(filenameExtension: "obj") { types.append(obj) }
        if let fbx = UTType(filenameExtension: "fbx") { types.append(fbx) }
        p.allowedContentTypes = types
        p.canChooseDirectories = false
        p.begin { [weak self] r in
            guard r == .OK else { return }
            let urls = p.urls
            Task { @MainActor in
                for url in urls {
                    self?.importVenue(from: url)
                }
            }
        }
    }

    private func importVenue(from url: URL) {
        do {
            let ext = url.pathExtension.lowercased()
            let mesh: Mesh
            if ext == "obj" {
                mesh = try OBJLoader.load(url: url)
            } else if ext == "fbx" {
                mesh = try importFBXMeshForVenue(from: url)
            } else {
                return
            }
            let entry = VenueEntry(url: url, mesh: mesh, visible: true)
            var copy = venues
            copy.append(entry)
            venues = copy
        } catch {
            validationErrors = [error.localizedDescription]
            showValidationAlert = true
        }
    }

    private func importFBXMeshForVenue(from url: URL) throws -> Mesh {
        // Re-use the same helper + importer path as main model, but keep it scoped to mesh only.
        let helperResult = try runFBXHelper(url: url)
        guard helperResult.ok else {
            throw NSError(
                domain: "FBXVenue",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: helperResult.message]
            )
        }

        var nsError: NSError?
        let scene = FBXSceneImporter.loadScene(from: url, error: &nsError)
        if let nsError {
            throw nsError
        }
        guard let im = scene.mesh else {
            throw NSError(
                domain: "FBXVenue",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "FBX has no mesh geometry."]
            )
        }

        // Same layout as main FBX import path.
        let verts: [FBXVertexPU] = im.vertexData.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: FBXVertexPU.self)
            return Array(p)
        }

        let idx: [UInt32] = im.indexData.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            return Array(p)
        }

        let outVerts: [Vertex] = verts.map { v in
            Vertex(position: v.position, uv: v.uv, normal: v.normal)
        }
        return Mesh(vertices: outVerts, indices: idx)
    }

    func setVenueVisible(id: VenueEntry.ID, visible: Bool) {
        guard let idx = venues.firstIndex(where: { $0.id == id }) else { return }
        var copy = venues
        copy[idx].visible = visible
        venues = copy
    }

    func clearVenue(id: VenueEntry.ID) {
        venues.removeAll { $0.id == id }
    }

    func refreshNDISources() { receiver.refreshSources() }
    func togglePlayPause() { isPlaying.toggle() }

    // MARK: - MODEL CLEAN (new)

    func cleanScene() {
        // Stop scoped access (best effort)
        Persistence.stopAccessLastModelIfNeeded()

        // Clear persisted last model so next launch autoloads nothing
        Persistence.clearLastModel()

        // Clear model state
        objURL = nil
        fbxURL = nil

        mesh = nil

        fbxCameras = []
        selectedFBXCameraIndex = -1
        fbxCameraStatus = "FBX: —"

        modelStatusText = "Model: cleared"
        markLaunchFinishedOK()
    }

    // MARK: - CAPTURE

    func pickCaptureFolder() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Choose"

        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in
                self?.captureFolderURL = url
                self?.lastCaptureMessage = "Folder: \(url.lastPathComponent)"
                Persistence.saveCaptureFolder(url)
            }
        }
    }

    func takeScreenshot() {
        guard let r = captureBridge else {
            lastCaptureMessage = "Renderer not ready yet."
            return
        }
        guard let dir = captureFolderURL else {
            lastCaptureMessage = "Choose folder first."
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "UVScope_\(timestampString()).png"
            let url = dir.appendingPathComponent(name)
            try r.saveScreenshot(url: url)
            lastCaptureMessage = "Saved: \(name)"
        } catch {
            lastCaptureMessage = "Screenshot failed: \(error.localizedDescription)"
        }
    }

    func toggleRecording() {
        guard let r = captureBridge else {
            lastCaptureMessage = "Renderer not ready yet."
            return
        }
        guard let dir = captureFolderURL else {
            lastCaptureMessage = "Choose folder first."
            return
        }

        if isRecording {
            (activeSource as? FileTextureSource)?.stopRecordingAudioCapture()
            if #available(macOS 13.0, *) {
                Task {
                    await audioCapture.stopCapture()
                    await MainActor.run {
                        r.stopVideoCapture { [weak self] result in
                            DispatchQueue.main.async {
                                switch result {
                                case .success(let url):
                                    self?.lastCaptureMessage = "Saved: \(url.lastPathComponent)"
                                case .failure(let err):
                                    self?.lastCaptureMessage = "Stop failed: \(err.localizedDescription)"
                                }
                                self?.isRecording = false
                            }
                        }
                    }
                }
            } else {
                r.stopVideoCapture { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let url):
                            self?.lastCaptureMessage = "Saved: \(url.lastPathComponent)"
                        case .failure(let err):
                            self?.lastCaptureMessage = "Stop failed: \(err.localizedDescription)"
                        }
                        self?.isRecording = false
                    }
                }
            }
            return
        }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "UVScope_\(timestampString()).mov"
            let url = dir.appendingPathComponent(name)
            
            // Video from Metal, video audio from FileTextureSource tap, mic from AVAudioEngine.
            let hasVideoAudio = (sourceMode == .file && activeSource is FileTextureSource)
            try r.startVideoCapture(url: url, fps: captureFPS, includeVideoAudio: hasVideoAudio, includeMic: isMicEnabled)
            
            if let fileSource = activeSource as? FileTextureSource, hasVideoAudio {
                // Apply current UI gain and connect level meter.
                fileSource.recordingGainDB = videoGainDB
                fileSource.onRecordingLevel = { [weak self] lvl in
                    self?.videoLevel = lvl
                }
                fileSource.startRecordingAudioCapture { [weak r] sb in
                    r?.pushVideoAudioSampleBuffer(sb)
                }
            }
            
            if #available(macOS 13.0, *) {
                let micEnabled = isMicEnabled
                audioCapture.isMicEnabled = micEnabled
                if micEnabled {
                    audioCapture.onMicLevel = { [weak self] lvl in
                        self?.micLevel = lvl
                    }
                    // Apply current UI gain.
                    audioCapture.setGain(dB: micGainDB)
                    audioCapture.onMicSampleBuffer = { [weak r] sampleBuffer in
                        r?.pushMicSampleBuffer(sampleBuffer)
                    }
                    audioCapture.startMicCapture()
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .denied || status == .restricted {
                        lastCaptureMessage = "Microphone permission denied. Enable in System Settings > Privacy & Security > Microphone"
                    }
                }
            }
            
            isRecording = true
            lastCaptureMessage = "Recording… \(name)"
        } catch {
            isRecording = false
            lastCaptureMessage = "Record failed: \(error.localizedDescription)"
        }
    }

    @available(macOS 13.0, *)
    private func prewarmMic() {
        audioCapture.isMicEnabled = true
        audioCapture.startMicCapture()
    }

    private func timestampString() -> String {
        let f = DateFormatter()
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Pickers (model + texture sources)

    func pickOBJFile() {
        modelKind = .obj

        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [UTType(filenameExtension: "obj")].compactMap { $0 }
        p.canChooseDirectories = false
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in
                // Enforce: either OBJ or FBX (clear FBX state)
                self?.fbxURL = nil
                self?.fbxCameras = []
                self?.selectedFBXCameraIndex = -1
                self?.fbxCameraStatus = "FBX: —"

                self?.objURL = url
            }
        }
    }

    func pickFBXFile() {
        modelKind = .fbx

        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [UTType(filenameExtension: "fbx")].compactMap { $0 }
        p.canChooseDirectories = false
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in
                // Enforce: either OBJ or FBX (clear OBJ state)
                self?.objURL = nil
                self?.mesh = nil

                self?.fbxURL = url
                self?.loadFBXScene(from: url)
            }
        }
    }

    func pickVideoFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.movie]
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in self?.fileURL = url }
        }
    }

    func pickImageFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.png, .jpeg]
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url else { return }
            Task { @MainActor in self?.imageURL = url }
        }
    }

    // MARK: - Build sources

    private func rebuildSource() {
        activeSource?.stop()

        switch sourceMode {
        case .ndi:
            let s = NDITextureSource(receiver: receiver)
            s.setLooping(isLooping)
            s.setPlaying(isPlaying)
            s.start()
            activeSource = s

        case .file:
            guard let url = fileURL else { activeSource = nil; return }
            let s = FileTextureSource(url: url)
            s.setLooping(isLooping)
            s.setPlaying(isPlaying)
            s.start()
            activeSource = s

        case .image:
            guard let url = imageURL else { activeSource = nil; return }
            let s = ImageTextureSource(url: url)
            s.setLooping(isLooping)
            s.setPlaying(isPlaying)
            s.start()
            activeSource = s
        }
    }

    // MARK: - OBJ

    private func loadOBJ() {
        guard modelKind == .obj else { return }
        guard let objURL else { return }
        let wasAutoload = (Persistence.restoreLastModel()?.url == objURL)
        do {
            mesh = try OBJLoader.load(url: objURL)
            Persistence.saveLastModel(kind: modelKind.persisted, url: objURL)
            modelStatusText = "OBJ loaded: \(objURL.lastPathComponent)"
            validationErrors = []
            showValidationAlert = false

            markLaunchFinishedOK()
        } catch OBJError.validationFailed(let errors) {
            print("OBJ validation failed:", errors)
            // Reset state like cleanScene
            mesh = nil
            self.objURL = nil
            modelStatusText = "Model: validation failed"
            validationErrors = errors
            showValidationAlert = true
            Persistence.clearLastModel()
            // Don't mark launch as finished if validation failed during autoload
            if !wasAutoload {
                markLaunchFinishedOK()
            }
        } catch {
            print("OBJ load failed:", error)
            // Reset state like cleanScene
            mesh = nil
            self.objURL = nil
            modelStatusText = "Model: error"
            validationErrors = [error.localizedDescription]
            showValidationAlert = true
            Persistence.clearLastModel()
            // Don't mark launch as finished if error during autoload
            if !wasAutoload {
                markLaunchFinishedOK()
            }
        }
    }

    func scrubCommit() {
        guard sourceMode == .file else { return }
        guard let s = activeSource, s.canSeek() else { return }
        s.seek(to: scrubSeconds)
        isScrubbing = false
    }

    // MARK: - FBX Scene (cameras now, mesh later)

    private struct FBXVertexPU {
        var position: SIMD3<Float>
        var uv: SIMD2<Float>
        var normal: SIMD3<Float>
    }

    /// Run external FBXImportHelper tool to validate FBX safely in a separate process.
    /// Returns (ok, message) where ok == false means validation failed with `message`.
    private func runFBXHelper(url: URL) throws -> (ok: Bool, message: String) {
        // Helper binary is copied into .app/Contents/MacOS via Xcode Copy Files phase.
        // Bundle.main.url(forResource:) ищет только в Resources, поэтому берём путь от исполняемого файла.
        guard let execURL = Bundle.main.executableURL else {
            throw NSError(
                domain: "FBXHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Main executable URL not available."]
            )
        }

        let helperURL = execURL.deletingLastPathComponent().appendingPathComponent("FBXImportHelper")
        if !FileManager.default.fileExists(atPath: helperURL.path) {
            throw NSError(
                domain: "FBXHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "FBX helper tool not found in app bundle."]
            )
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [url.path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()

        struct HelperResult: Decodable {
            let ok: Bool
            let error: String?
            let meshCount: Int?
        }

        guard !outData.isEmpty,
              let result = try? JSONDecoder().decode(HelperResult.self, from: outData) else {
            let stderrText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = stderrText.isEmpty ? "FBX helper returned invalid output." : stderrText
            throw NSError(
                domain: "FBXHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }

        if result.ok {
            let count = result.meshCount ?? 1
            return (true, "FBX validated: \(count) mesh\(count == 1 ? "" : "es")")
        } else {
            return (false, result.error ?? "FBX import failed")
        }
    }

    private func loadFBXScene(from url: URL) {
        let wasAutoload = (Persistence.restoreLastModel()?.url == url)
        do {
            let helperResult = try runFBXHelper(url: url)

            guard helperResult.ok else {
                // Validation failed in helper: show error, clear model state, but НЕ падаем.
                mesh = nil
                fbxURL = nil
                fbxCameras = []
                selectedFBXCameraIndex = -1
                fbxCameraStatus = "FBX: —"
                modelStatusText = "Model: validation failed"
                validationErrors = [helperResult.message]
                showValidationAlert = true
                Persistence.clearLastModel()
                if !wasAutoload {
                    markLaunchFinishedOK()
                }
                return
            }

            // ✅ Helper сказал, что файл безопасный и валидный.
            // Теперь можно вызвать существующий FBXSceneImporter в этом процессе
            // (он использует тот же OpenFBX, и если helper не упал, здесь тоже не должно упасть).

            var nsError: NSError?
            let scene = FBXSceneImporter.loadScene(from: url, error: &nsError)

            if let nsError {
                // Validation / parse error на уровне FBXSceneImporter
                let errorMsg = nsError.localizedDescription
                let errors = errorMsg.components(separatedBy: "\n").filter { !$0.isEmpty }
                validationErrors = errors
                showValidationAlert = true

                // Reset state like cleanScene
                mesh = nil
                fbxURL = nil
                fbxCameras = []
                selectedFBXCameraIndex = -1
                fbxCameraStatus = "FBX: —"
                modelStatusText = "Model: validation failed"
                Persistence.clearLastModel()

                if !wasAutoload {
                    markLaunchFinishedOK()
                }
                return
            }

            // Enforce: FBX replaces OBJ
            objURL = nil

            // Cameras
            fbxCameras = scene.cameras as? [FBXImportedCamera] ?? []
            fbxCameraStatus = "FBX: \(fbxCameras.count) camera(s)"
            // Don't auto-select camera - let user choose, or use fit by default
            selectedFBXCameraIndex = -1

            // Mesh
            if let im = scene.mesh {
                // vertexData -> [FBXVertexPU]
                let verts: [FBXVertexPU] = im.vertexData.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: FBXVertexPU.self)
                    return Array(p)
                }

                let idx: [UInt32] = im.indexData.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: UInt32.self)
                    return Array(p)
                }

                // Convert to your Mesh/Vertex (use normal from FBXVertexPU)
                let outVerts: [Vertex] = verts.map { v in
                    Vertex(position: v.position, uv: v.uv, normal: v.normal)
                }
                mesh = Mesh(vertices: outVerts, indices: idx)
            } else {
                mesh = nil
            }

            // Status text
            var lines: [String] = []
            lines.append(scene.statusText)
            lines.append("FBX loaded: \(fbxCameras.count) cameras")
            if !(scene.warningText ?? "").isEmpty {
                lines.append(scene.warningText)
            }
            // Добавляем сообщение от helper’а как дополнительную строку (опционально)
            lines.append(helperResult.message)
            modelStatusText = lines.joined(separator: " • ")

            Persistence.saveLastModel(kind: modelKind.persisted, url: url)
            validationErrors = []
            showValidationAlert = false

            // ✅ Auto-fit после загрузки меша
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.requestFit()
            }

        } catch {
            // Reset state like cleanScene
            fbxCameras = []
            selectedFBXCameraIndex = -1
            fbxCameraStatus = "FBX: —"
            modelStatusText = "Model: error"
            lastCaptureMessage = "FBX import failed: \(error.localizedDescription)"
            mesh = nil
            fbxURL = nil
            validationErrors = [error.localizedDescription]
            showValidationAlert = true
            Persistence.clearLastModel()
            // Don't mark launch as finished if error during autoload
            if !wasAutoload {
                markLaunchFinishedOK()
            }
        }
    }


    // MARK: - Camera application (temporary)

    private func meshCenter() -> SIMD3<Float> {
        guard let mesh else { return SIMD3<Float>(0, 0, 0) }

        var mn = SIMD3<Float>(Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude)
        var mx = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude)

        for v in mesh.vertices {
            mn = simd_min(mn, v.position)
            mx = simd_max(mx, v.position)
        }

        return (mn + mx) * 0.5
    }

    private func meshRadius() -> Float {
        guard let mesh else { return 1 }
        var mn = SIMD3<Float>(Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude)
        var mx = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude)
        for v in mesh.vertices {
            mn = simd_min(mn, v.position)
            mx = simd_max(mx, v.position)
        }
        let ext = mx - mn
        return max(0.001, max(ext.x, max(ext.y, ext.z)) * 0.5)
    }

    private func applySelectedFBXCamera() {
        guard selectedFBXCameraIndex >= 0,
              selectedFBXCameraIndex < fbxCameras.count
        else { return }

        let c = fbxCameras[selectedFBXCameraIndex]

        // FOV: Convert horizontal FOV to vertical using ACTUAL viewport aspect ratio
        let fovH = c.fovHDegrees
        let viewportAspect = captureBridge?.currentAspectRatio ?? (16.0 / 9.0)
        
        // fovV = 2 * atan(tan(fovH/2) / aspect)
        let fovHRad = fovH * Float.pi / 180.0
        let fovVRad = 2.0 * atan(tan(fovHRad * 0.5) / viewportAspect)
        let fovV = fovVRad * 180.0 / Float.pi
        
        camera.fovDegrees = fovV
        fovDegrees = camera.fovDegrees
        
        print("FOV: fovH=\(fovH)°, aspect=\(viewportAspect), fovV=\(fovV)°")
        
        // Используем forward из FBX
        let center = meshCenter()
        let forward = simd_normalize(c.forward)
        let distanceToCenter = simd_length(center - c.position)
        let targetDistance = max(distanceToCenter, 100.0)
        
        camera.target = c.position + forward * targetDistance
        camera.setPositionKeepingTarget(c.position)

        Persistence.saveLastCameraState(camera.toState())
    }

}

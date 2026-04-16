import Foundation
import CoreGraphics

final class NDIReceiver: ObservableObject {
    @Published var sources: [String] = []
    @Published var selectedIndex: Int = -1
    @Published var lastFrameSize: CGSize = .zero

    // Последний видеокадр (копия данных), читается рендерером
    struct VideoFrame {
        let width: Int
        let height: Int
        let stride: Int
        let data: Data
    }

    private let frameLock = NSLock()
    private var latestFrame: VideoFrame?

    func consumeLatestFrame() -> VideoFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    private var finder: NDIlib_find_instance_t?
    private var receiver: NDIlib_recv_instance_t?

    private var running = false
    private var discoveryTimer: Timer?
    private let recvGroup = DispatchGroup()

    // MARK: - Public

    func startDiscovery() {
        DispatchQueue.main.async { [weak self] in
            self?.startDiscoveryOnMain()
        }
    }

    private func startDiscoveryOnMain() {
        if NDIlib_initialize() == false {
            print("❌ NDIlib_initialize failed")
            return
        } else {
            if let v = NDIlib_version() {
                print("✅ NDIlib_initialize OK, version:", String(cString: v))
            }
        }

        if finder == nil {
            var desc = NDIlib_find_create_t()
            desc.p_groups = nil
            desc.p_extra_ips = nil
            desc.show_local_sources = true

            finder = NDIlib_find_create_v2(&desc)
            if finder == nil {
                print("❌ NDIlib_find_create_v2 failed")
                return
            }
        }

        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                self?.refreshSources()
            }
        }

        refreshSources()
    }

    /// Safe reconnect:
    /// 1) stop loop + wait
    /// 2) destroy old receiver
    /// 3) create new receiver + start loop
    func connect(index: Int) {
        guard let finder else {
            print("❌ Finder not started. Call startDiscovery() first.")
            return
        }

        // stop previous receiveLoop safely (if any)
        stopReceiveLoopIfNeeded()

        _ = NDIlib_find_wait_for_sources(finder, 200)

        var count: UInt32 = 0
        guard let ptr = NDIlib_find_get_current_sources(finder, &count), count > 0 else {
            print("❌ No NDI sources found")
            return
        }

        guard index >= 0, index < Int(count) else {
            print("❌ connect(index:) out of range, index=\(index), count=\(count)")
            return
        }

        let source = ptr[index]

        // destroy old receiver (now safe because loop already stopped)
        if let receiver {
            NDIlib_recv_destroy(receiver)
            self.receiver = nil
        }

        var recvDesc = NDIlib_recv_create_v3_t()
        recvDesc.source_to_connect_to = source
        recvDesc.color_format = NDIlib_recv_color_format_BGRX_BGRA
        recvDesc.bandwidth = NDIlib_recv_bandwidth_highest
        recvDesc.allow_video_fields = false

        guard let newRecv = NDIlib_recv_create_v3(&recvDesc) else {
            print("❌ NDIlib_recv_create_v3 failed")
            return
        }

        self.receiver = newRecv
        self.selectedIndex = index

        running = true

        let recvForLoop = newRecv
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.receiveLoop(receiver: recvForLoop)
        }
    }

    func stop() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil

        // stop loop + wait
        stopReceiveLoopIfNeeded()

        if let receiver {
            NDIlib_recv_destroy(receiver)
            self.receiver = nil
        }

        if let finder {
            NDIlib_find_destroy(finder)
            self.finder = nil
        }

        NDIlib_destroy()

        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.sources = []
            self?.selectedIndex = -1
            self?.lastFrameSize = .zero
        }
    }

    // MARK: - Private

    func refreshSources() {
        guard let finder else { return }

        _ = NDIlib_find_wait_for_sources(finder, 500)

        var count: UInt32 = 0
        guard let ptr = NDIlib_find_get_current_sources(finder, &count) else {
            DispatchQueue.main.async { [weak self] in
                self?.sources = []
                self?.selectedIndex = -1
            }
            return
        }

        var names: [String] = []
        names.reserveCapacity(Int(count))

        for i in 0..<Int(count) {
            let src = ptr[i]
            if let cName = src.p_ndi_name {
                names.append(String(cString: cName))
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sources = names

            if count == 0 {
                self.selectedIndex = -1
            } else if self.selectedIndex >= Int(count) {
                self.selectedIndex = -1
            }
        }
    }

    private func stopReceiveLoopIfNeeded() {
        if running {
            running = false
            recvGroup.wait()
        }
    }

    private func receiveLoop(receiver recv: NDIlib_recv_instance_t) {
        recvGroup.enter()
        defer { recvGroup.leave() }

        var videoFrame = NDIlib_video_frame_v2_t()

        while running {
            // если произошёл reconnect и self.receiver сменился — выходим
            if self.receiver != recv { break }

            let type = NDIlib_recv_capture_v2(recv, &videoFrame, nil, nil, 1000)

            if type == NDIlib_frame_type_video {
                let w = Int(videoFrame.xres)
                let h = Int(videoFrame.yres)
                let stride = Int(videoFrame.line_stride_in_bytes)

                if let p = videoFrame.p_data, w > 0, h > 0, stride > 0 {
                    let byteCount = stride * h
                    let data = Data(bytes: p, count: byteCount)

                    frameLock.lock()
                    latestFrame = VideoFrame(width: w, height: h, stride: stride, data: data)
                    frameLock.unlock()

                    DispatchQueue.main.async { [weak self] in
                        self?.lastFrameSize = CGSize(width: w, height: h)
                    }
                }

                NDIlib_recv_free_video_v2(recv, &videoFrame)
            }
        }
    }

    deinit {
        stop()
    }
}

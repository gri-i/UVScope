import Foundation
import simd

// MARK: - Keys

struct PersistKeys {
    static let lastModelRecord = "lastModelRecord"   // ✅ new (replaces lastModelBookmark)
    static let lastCameraState = "lastCameraState"
    static let lastCaptureFolder = "lastCaptureFolder"
    static let venuesRecord = "venuesRecord"

    static func cameraPresetKey(_ index: Int) -> String {
        "cameraPreset_\(index)"
    }
}

// MARK: - ModelSource

enum PersistedModelKind: String, Codable {
    case obj
    case fbx
}

struct PersistedLastModel: Codable {
    let kind: PersistedModelKind
    let bookmark: Data
}

struct PersistedVenue: Codable {
    let bookmark: Data
    let visible: Bool
}

// MARK: - CameraState

struct CameraState: Codable {
    let position: SIMD3<Float>
    let target: SIMD3<Float>
    let yaw: Float
    let pitch: Float
    let distance: Float
    let fov: Float
}

// MARK: - Persistence API

enum Persistence {

    // ---------- Last Model (kind + security-scoped bookmark) ----------

    static func saveLastModel(kind: PersistedModelKind, url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        let rec = PersistedLastModel(kind: kind, bookmark: bookmark)
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: PersistKeys.lastModelRecord)
        }
    }

    static func clearLastModel() {
        UserDefaults.standard.removeObject(forKey: PersistKeys.lastModelRecord)
    }

    /// Restores last model (kind + URL). Starts accessing security-scoped resource.
    /// If file is missing or bookmark invalid -> clears record and returns nil.
    static func restoreLastModel() -> (kind: PersistedModelKind, url: URL)? {
        guard let data = UserDefaults.standard.data(forKey: PersistKeys.lastModelRecord),
              let rec = try? JSONDecoder().decode(PersistedLastModel.self, from: data)
        else { return nil }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: rec.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            if stale {
                saveLastModel(kind: rec.kind, url: url)
            }

            _ = url.startAccessingSecurityScopedResource()

            if !FileManager.default.fileExists(atPath: url.path) {
                url.stopAccessingSecurityScopedResource()
                clearLastModel()
                return nil
            }

            return (rec.kind, url)
        } catch {
            clearLastModel()
            return nil
        }
    }

    /// Stop accessing last model resource (best effort, safe anytime)
    static func stopAccessLastModelIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: PersistKeys.lastModelRecord),
              let rec = try? JSONDecoder().decode(PersistedLastModel.self, from: data)
        else { return }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: rec.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            url.stopAccessingSecurityScopedResource()
        } catch {
            // ignore
        }
    }

    // ---------- Backward compatibility wrappers ----------
    // If old code still calls these, keep them temporarily.

    static func saveLastModelURL(_ url: URL) {
        saveLastModel(kind: .obj, url: url)
    }

    static func restoreLastModelURL() -> URL? {
        restoreLastModel()?.url
    }

    // ---------- Last Camera ----------

    static func saveLastCameraState(_ state: CameraState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: PersistKeys.lastCameraState)
        }
    }

    static func restoreLastCameraState() -> CameraState? {
        guard
            let data = UserDefaults.standard.data(forKey: PersistKeys.lastCameraState),
            let state = try? JSONDecoder().decode(CameraState.self, from: data)
        else { return nil }

        return state
    }

    // ---------- Capture folder (screenshots / video) ----------

    static func saveCaptureFolder(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        UserDefaults.standard.set(bookmark, forKey: PersistKeys.lastCaptureFolder)
    }

    static func clearCaptureFolder() {
        UserDefaults.standard.removeObject(forKey: PersistKeys.lastCaptureFolder)
    }

    static func restoreCaptureFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: PersistKeys.lastCaptureFolder) else {
            return nil
        }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                saveCaptureFolder(url)
            }
            _ = url.startAccessingSecurityScopedResource()

            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                clearCaptureFolder()
                return nil
            }
            return url
        } catch {
            clearCaptureFolder()
            return nil
        }
    }

    static func stopAccessCaptureFolderIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: PersistKeys.lastCaptureFolder) else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            url.stopAccessingSecurityScopedResource()
        } catch {
            // ignore
        }
    }

    // ---------- VENUE geometry (multiple meshes) ----------

    /// Save list of venue entries (url + visibility) using security-scoped bookmarks.
    static func saveVenues(_ entries: [(url: URL, visible: Bool)]) {
        guard !entries.isEmpty else {
            UserDefaults.standard.removeObject(forKey: PersistKeys.venuesRecord)
            return
        }

        var persisted: [PersistedVenue] = []
        persisted.reserveCapacity(entries.count)

        for entry in entries {
            if let bookmark = try? entry.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                persisted.append(PersistedVenue(bookmark: bookmark, visible: entry.visible))
            }
        }

        guard let data = try? JSONEncoder().encode(persisted) else { return }
        UserDefaults.standard.set(data, forKey: PersistKeys.venuesRecord)
    }

    /// Restore venue entries (url + visibility). Starts accessing security-scoped resources.
    static func restoreVenues() -> [(url: URL, visible: Bool)] {
        guard
            let data = UserDefaults.standard.data(forKey: PersistKeys.venuesRecord),
            let persisted = try? JSONDecoder().decode([PersistedVenue].self, from: data)
        else {
            return []
        }

        var result: [(url: URL, visible: Bool)] = []
        result.reserveCapacity(persisted.count)

        for item in persisted {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: item.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if stale {
                    // refresh bookmark
                    _ = try? url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                }

                _ = url.startAccessingSecurityScopedResource()

                guard FileManager.default.fileExists(atPath: url.path) else {
                    url.stopAccessingSecurityScopedResource()
                    continue
                }

                result.append((url: url, visible: item.visible))
            } catch {
                continue
            }
        }

        return result
    }

    // ---------- Camera Presets (0...9) ----------

    static func saveCameraPreset(index: Int, state: CameraState) {
        guard (0...9).contains(index) else { return }
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: PersistKeys.cameraPresetKey(index))
        }
    }

    static func restoreCameraPreset(index: Int) -> CameraState? {
        guard (0...9).contains(index) else { return nil }
        guard
            let data = UserDefaults.standard.data(forKey: PersistKeys.cameraPresetKey(index)),
            let state = try? JSONDecoder().decode(CameraState.self, from: data)
        else { return nil }

        return state
    }
}

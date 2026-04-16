import Foundation

protocol ViewerCaptureBridge: AnyObject {
    func startRecording(url: URL, fps: Int) throws
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void)
    func saveScreenshot(url: URL) throws
}


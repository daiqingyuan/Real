import AppKit
@preconcurrency import AVFoundation
import SwiftUI

@MainActor final class MirrorService: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var status = ""
    @Published private(set) var active = false
    private let queue = DispatchQueue(label: "local.dan.real.camera")
    private var request: CameraRunRequest?
    private var visiblePreviews = CameraPreviewOwnership()
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] notification in
                let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                Task { @MainActor in self?.checkUnexpectedStop(detail: detail) }
            })
        }
    }

    private func checkUnexpectedStop(detail: String?) {
        guard active, let request, !request.isCancelled else { return }
        let session = session
        queue.async { [weak self] in
            // A notification from an earlier stop can arrive during a new start.
            // Query the serial capture queue and fence by request identity.
            guard !session.isRunning, !request.isCancelled else { return }
            Task { @MainActor in
                guard let self, self.request === request, !request.isCancelled else { return }
                self.stop()
                self.status = tr("摄像头不可用") + (detail.map { " · " + $0 } ?? "")
            }
        }
    }
    func retainPreview(_ id: UUID) { visiblePreviews.retain(id) }
    func releasePreview(_ id: UUID) { if visiblePreviews.release(id) { stop() } }
    func start() {
        guard request == nil else { return }
        let request = CameraRunRequest()
        self.request = request
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure(request)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.request === request, !request.isCancelled else { return }
                    if granted { self.configure(request) }
                    else { self.request = nil; self.status = tr("需要摄像头权限") }
                }
            }
        default: self.request = nil; status = tr("需要摄像头权限")
        }
    }
    private func configure(_ request: CameraRunRequest) {
        let session = session
        let unavailable = tr("摄像头不可用")
        // Configuration, starting, and stopping all run on this same serial queue.
        // A cancelled request never becomes an active UI session after a late grant.
        queue.async { [weak self] in
            guard !request.isCancelled else { return }
            var failure: String?
            do {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    throw NSError(domain: "RealCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: unavailable])
                }
                let input = try AVCaptureDeviceInput(device: device)
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                for existing in session.inputs { session.removeInput(existing) }
                if session.canAddInput(input) {
                    session.addInput(input)
                    if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                } else { failure = unavailable }
                session.commitConfiguration()
                if failure == nil && !request.isCancelled {
                    session.startRunning()
                    if !session.isRunning { failure = unavailable }
                }
            } catch { failure = error.localizedDescription }
            if request.isCancelled {
                if session.isRunning { session.stopRunning() }
                return
            }
            let errorMessage = failure
            Task { @MainActor in
                guard let self, self.request === request, !request.isCancelled else { return }
                self.active = errorMessage == nil
                self.status = errorMessage ?? ""
                if errorMessage != nil { self.request = nil }
            }
        }
    }
    func stop() {
        request?.cancel()
        request = nil
        active = false
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        request?.cancel()
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

/// Cancellation crosses the main actor, the permission callback, and the camera
/// queue. Identity distinguishes separate starts; the lock protects its one bit.
private final class CameraRunRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct CameraSurface: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = CameraPreviewView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        // A mirror follows the user's left/right movement, regardless of the
        // camera driver's automatic front-camera mirroring default.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        } else {
            preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        }
        view.wantsLayer = true
        view.layer = preview
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
final class CameraPreviewView: NSView {
    override func layout() { super.layout(); layer?.frame = bounds }
}

/// Duplicate SwiftUI teardown notifications must not stop an unrelated session.
struct CameraPreviewOwnership {
    private var owners = Set<UUID>()
    mutating func retain(_ id: UUID) { owners.insert(id) }
    mutating func release(_ id: UUID) -> Bool {
        guard owners.remove(id) != nil else { return false }
        return owners.isEmpty
    }
}

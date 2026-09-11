import DSLRKit
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var status = "Searching for a USB camera…"
    @Published private(set) var descriptor: CameraDescriptor?
    @Published private(set) var state: CameraState?
    @Published private(set) var capabilities: Set<CameraCapability> = []
    @Published private(set) var liveViewImage: UIImage?
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var isConnected = false
    @Published private(set) var isLiveViewActive = false
    @Published private(set) var isBusy = false

    private let discovery = ImageCaptureCameraDiscovery()
    private var camera: (any Camera)?
    private var discoveryTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var wantsLiveView = false
    private var isConnecting = false
    private var cameraSession = UUID()

    func start() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task {
            do {
                for try await found in discovery.cameras() {
                    guard !isConnected, !isConnecting else { continue }
                    isConnecting = true
                    cameraSession = UUID()
                    camera = found.camera
                    descriptor = found.descriptor
                    status = "Camera detected — connecting…"
                    do {
                        try await connect(found.camera)
                    } catch {
                        await found.camera.disconnect()
                        self.camera = nil
                        descriptor = nil
                        isConnected = false
                        show(error)
                    }
                    isConnecting = false
                }
            } catch {
                show(error)
            }
        }
    }

    func refresh() {
        guard let camera, isConnected else { return }
        Task {
            do {
                state = try await camera.state()
                status = "Connected"
            } catch {
                show(error)
            }
        }
    }

    func toggleLiveView() {
        isLiveViewActive ? stopLiveView() : startLiveView()
    }

    func capture() {
        guard let camera, isConnected, !isBusy else { return }
        let restartLiveView = isLiveViewActive
        if restartLiveView {
            liveViewTask?.cancel()
            liveViewTask = nil
            isLiveViewActive = false
        }
        isBusy = true
        Task {
            defer {
                isBusy = false
                if restartLiveView, isConnected { startLiveView() }
            }
            do {
                let photo = try await camera.capturePhoto(download: true)
                guard let data = photo.data, let image = UIImage(data: data) else {
                    status = "Capture triggered, but no image was downloaded"
                    return
                }
                capturedImage = image
                status = "Photo captured"
                state = try? await camera.state()
            } catch {
                show(error)
            }
        }
    }

    func disconnect() {
        guard let camera else { return }
        wantsLiveView = false
        cameraSession = UUID()
        liveViewTask?.cancel()
        liveViewTask = nil
        Task {
            await camera.stopLiveView()
            await camera.disconnect()
            isConnected = false
            isLiveViewActive = false
            self.camera = nil
            descriptor = nil
            state = nil
            capabilities = []
            status = "Disconnected"
        }
    }

    private func connect(_ camera: any Camera) async throws {
        try await camera.connect()
        capabilities = try await camera.capabilities()
        state = try await camera.state()
        isConnected = true
        status = "Connected"
        if wantsLiveView { startLiveView() }
    }

    private func startLiveView() {
        wantsLiveView = true
        guard let camera, capabilities.contains(.liveView) else {
            status = "Live view is not supported by this profile"
            return
        }
        liveViewTask = Task {
            let session = cameraSession
            do {
                let stream = try await camera.startLiveView()
                isLiveViewActive = true
                status = "Live view active"
                for try await frame in stream {
                    guard !Task.isCancelled else { break }
                    liveViewImage = UIImage(data: frame.jpegData)
                }
                if !Task.isCancelled, wantsLiveView { await handleUnexpectedDisconnect(session: session) }
            } catch {
                if !Task.isCancelled, wantsLiveView { await handleUnexpectedDisconnect(error, session: session) }
            }
        }
    }

    private func stopLiveView() {
        wantsLiveView = false
        liveViewTask?.cancel()
        liveViewTask = nil
        guard let camera else { return }
        Task {
            await camera.stopLiveView()
            isLiveViewActive = false
            status = "Live view stopped"
        }
    }

    private func handleUnexpectedDisconnect(_ error: Error? = nil, session: UUID) async {
        guard cameraSession == session, let disconnectedCamera = camera else { return }
        liveViewTask = nil
        isLiveViewActive = false
        isConnected = false
        state = nil
        capabilities = []
        status = error.map { "Connection lost: \($0.localizedDescription) — reconnecting…" }
            ?? "Connection lost — reconnecting…"
        camera = nil
        descriptor = nil
        Task { await disconnectedCamera.disconnect() }
    }

    private func show(_ error: Error) {
        status = "Error: \(error.localizedDescription)"
    }
}

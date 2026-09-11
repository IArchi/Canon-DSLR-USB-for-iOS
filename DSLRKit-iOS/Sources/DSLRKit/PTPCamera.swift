import Foundation

/// Camera-specific PTP behavior. PTP standardizes the wire format, but DSLR live view and most
/// writable controls remain vendor extensions, so each supported family supplies a profile.
public protocol PTPCameraProfile: Sendable {
    var capabilities: Set<CameraCapability> { get }
    func state(using transport: any PTPTransport) async throws -> CameraState
    func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws
    func capturePhoto(download: Bool, using transport: any PTPTransport) async throws -> CapturedPhoto
    func startLiveView(using transport: any PTPTransport) async throws -> AsyncThrowingStream<Data, Error>
    func stopLiveView(using transport: any PTPTransport) async
}

public actor PTPCameraBridge: VendorCameraBridge {
    public nonisolated let descriptor: CameraDescriptor
    private let transport: any PTPTransport
    private let profile: any PTPCameraProfile
    private var connected = false

    public init(descriptor: CameraDescriptor, transport: any PTPTransport, profile: any PTPCameraProfile) {
        self.descriptor = descriptor
        self.transport = transport
        self.profile = profile
    }

    public func connect() async throws {
        guard !connected else { throw CameraError.alreadyConnected }
        try await transport.open()
        connected = true
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        await transport.close()
    }

    public func capabilities() throws -> Set<CameraCapability> {
        try requireConnection()
        return profile.capabilities
    }

    public func state() async throws -> CameraState {
        try requireConnection()
        return try await profile.state(using: transport)
    }

    public func set(_ settings: CameraSettings) async throws {
        try requireConnection()
        try await profile.set(settings, using: transport)
    }

    public func capturePhoto(download: Bool) async throws -> CapturedPhoto {
        try requireConnection()
        return try await profile.capturePhoto(download: download, using: transport)
    }

    public func startLiveView() async throws -> AsyncThrowingStream<Data, Error> {
        try requireConnection()
        return try await profile.startLiveView(using: transport)
    }

    public func stopLiveView() async {
        guard connected else { return }
        await profile.stopLiveView(using: transport)
    }

    private func requireConnection() throws {
        guard connected else { throw CameraError.notConnected }
    }
}

/// Safe fallback for every standards-compliant PTP camera. It exposes raw PTP and deliberately
/// reports vendor controls as unsupported instead of pretending that PTP defines them.
public struct GenericPTPProfile: PTPCameraProfile {
    public let capabilities: Set<CameraCapability> = []
    public init() {}

    public func state(using transport: any PTPTransport) async throws -> CameraState { CameraState() }

    public func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws {
        throw CameraError.unsupported(settings.firstCapability ?? .exposureMode)
    }

    public func capturePhoto(download: Bool, using transport: any PTPTransport) async throws -> CapturedPhoto {
        throw CameraError.unsupported(.capturePhoto)
    }

    public func startLiveView(using transport: any PTPTransport) async throws -> AsyncThrowingStream<Data, Error> {
        throw CameraError.unsupported(.liveView)
    }

    public func stopLiveView(using transport: any PTPTransport) async {}
}

private extension CameraSettings {
    var firstCapability: CameraCapability? {
        if exposureMode != nil { return .exposureMode }
        if aperture != nil { return .aperture }
        if shutterSpeed != nil { return .shutterSpeed }
        if iso != nil { return .iso }
        if exposureCompensation != nil { return .exposureCompensation }
        if whiteBalance != nil { return .whiteBalance }
        if focusMode != nil { return .focusMode }
        return nil
    }
}

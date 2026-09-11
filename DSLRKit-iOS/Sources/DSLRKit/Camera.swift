import Foundation

/// Manufacturer-neutral camera API. Implementations serialize access in an actor because
/// vendor camera SDKs generally require ordered commands and are not thread-safe.
public protocol Camera: Actor {
    nonisolated var descriptor: CameraDescriptor { get }

    func connect() async throws
    func disconnect() async
    func capabilities() async throws -> Set<CameraCapability>
    func state() async throws -> CameraState
    func set(_ settings: CameraSettings) async throws
    func capturePhoto(download: Bool) async throws -> CapturedPhoto
    func startLiveView() async throws -> AsyncThrowingStream<LiveViewFrame, Error>
    func stopLiveView() async
}

public struct DiscoveredCamera: Sendable {
    public let descriptor: CameraDescriptor
    public let camera: any Camera

    public init(descriptor: CameraDescriptor, camera: any Camera) {
        self.descriptor = descriptor
        self.camera = camera
    }
}

public protocol CameraDiscovery: Sendable {
    func cameras() async -> AsyncThrowingStream<DiscoveredCamera, Error>
}

/// Internal boundary between the public camera API and a PTP camera profile.
public protocol VendorCameraBridge: Sendable {
    var descriptor: CameraDescriptor { get }

    func connect() async throws
    func disconnect() async
    func capabilities() async throws -> Set<CameraCapability>
    func state() async throws -> CameraState
    func set(_ settings: CameraSettings) async throws
    func capturePhoto(download: Bool) async throws -> CapturedPhoto
    /// Must terminate with an error if the camera disconnects or the stream fails.
    func startLiveView() async throws -> AsyncThrowingStream<Data, Error>
    func stopLiveView() async
}

public actor VendorCamera: Camera {
    public nonisolated let descriptor: CameraDescriptor

    private let bridge: any VendorCameraBridge
    private enum ConnectionState {
        case disconnected
        case connecting(UUID)
        case connected
    }

    private var connectionState = ConnectionState.disconnected
    private var liveViewContinuation: AsyncThrowingStream<LiveViewFrame, Error>.Continuation?
    private var liveViewTask: Task<Void, Never>?
    private var liveViewToken: UUID?
    private var liveViewSequence: UInt64 = 0

    public init(bridge: any VendorCameraBridge) {
        self.bridge = bridge
        self.descriptor = bridge.descriptor
    }

    public func connect() async throws {
        guard case .disconnected = connectionState else { throw CameraError.alreadyConnected }
        let token = UUID()
        connectionState = .connecting(token)
        do {
            try await bridge.connect()
            guard case .connecting(token) = connectionState else {
                await bridge.disconnect()
                throw CameraError.notConnected
            }
            connectionState = .connected
        } catch {
            if case .connecting(token) = connectionState { connectionState = .disconnected }
            throw error
        }
    }

    public func disconnect() async {
        guard !isDisconnected else { return }
        connectionState = .disconnected
        await stopLiveView()
        await bridge.disconnect()
    }

    public func capabilities() async throws -> Set<CameraCapability> {
        try requireConnection()
        return try await bridge.capabilities()
    }

    public func state() async throws -> CameraState {
        try requireConnection()
        return try await bridge.state()
    }

    public func set(_ settings: CameraSettings) async throws {
        try requireConnection()
        try await bridge.set(settings)
    }

    public func capturePhoto(download: Bool = true) async throws -> CapturedPhoto {
        try requireConnection()
        if liveViewToken != nil {
            await stopLiveView()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return try await bridge.capturePhoto(download: download)
    }

    public func startLiveView() async throws -> AsyncThrowingStream<LiveViewFrame, Error> {
        try requireConnection()
        guard liveViewToken == nil else { throw CameraError.liveViewAlreadyRunning }

        let token = UUID()
        liveViewToken = token
        let source: AsyncThrowingStream<Data, Error>
        do {
            source = try await bridge.startLiveView()
        } catch {
            if liveViewToken == token { liveViewToken = nil }
            throw error
        }
        guard case .connected = connectionState, liveViewToken == token else {
            await bridge.stopLiveView()
            throw CameraError.notConnected
        }

        let (stream, continuation) = AsyncThrowingStream<LiveViewFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        liveViewContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopLiveView(token: token) }
        }
        liveViewTask = Task { [weak self] in
            do {
                for try await data in source {
                    guard !Task.isCancelled else { break }
                    await self?.receiveLiveView(data, token: token)
                }
                await self?.finishLiveView(token: token, error: nil)
            } catch {
                await self?.finishLiveView(token: token, error: error)
            }
        }
        return stream
    }

    public func stopLiveView() async {
        await stopLiveView(token: nil)
    }

    private func stopLiveView(token expectedToken: UUID?) async {
        guard let token = liveViewToken, expectedToken == nil || expectedToken == token else { return }
        liveViewToken = nil
        liveViewTask?.cancel()
        liveViewTask = nil
        let continuation = liveViewContinuation
        liveViewContinuation = nil
        await bridge.stopLiveView()
        continuation?.finish()
    }

    private func receiveLiveView(_ data: Data, token: UUID) {
        guard liveViewToken == token, let liveViewContinuation else { return }
        liveViewSequence += 1
        liveViewContinuation.yield(.init(jpegData: data, sequenceNumber: liveViewSequence))
    }

    private func finishLiveView(token: UUID, error: Error?) {
        guard liveViewToken == token else { return }
        liveViewToken = nil
        liveViewTask = nil
        let continuation = liveViewContinuation
        liveViewContinuation = nil
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    private func requireConnection() throws {
        guard case .connected = connectionState else { throw CameraError.notConnected }
    }

    private var isDisconnected: Bool {
        if case .disconnected = connectionState { return true }
        return false
    }
}

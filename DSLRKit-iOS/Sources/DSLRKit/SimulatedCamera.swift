import Foundation

/// Deterministic implementation for UI development and integration tests without hardware.
public actor SimulatedCamera: Camera {
    public nonisolated let descriptor: CameraDescriptor

    private let supportedCapabilities: Set<CameraCapability>
    private var connected = false
    private var currentState: CameraState
    private var liveViewTask: Task<Void, Never>?
    private var liveViewContinuation: AsyncThrowingStream<LiveViewFrame, Error>.Continuation?
    private var nextPhoto = 1

    public init(
        model: String = "Simulated DSLR",
        initialState: CameraState = .init(
            settings: .init(exposureMode: .manual, aperture: 5.6, shutterSpeed: .fraction(125), iso: 100),
            batteryPercent: 100
        ),
        capabilities: Set<CameraCapability> = Set(CameraCapability.allCases)
    ) {
        descriptor = .init(id: UUID().uuidString, manufacturer: .simulated, model: model, transport: .simulated)
        currentState = initialState
        supportedCapabilities = capabilities
    }

    public func connect() throws {
        guard !connected else { throw CameraError.alreadyConnected }
        connected = true
    }

    public func disconnect() async {
        stopLiveView()
        connected = false
    }

    public func capabilities() throws -> Set<CameraCapability> {
        try requireConnection()
        return supportedCapabilities
    }

    public func state() throws -> CameraState {
        try requireConnection()
        return currentState
    }

    public func set(_ settings: CameraSettings) throws {
        try requireConnection()
        var updated = currentState.settings
        if let aperture = settings.aperture {
            try require(.aperture)
            guard aperture.isFinite, aperture > 0 else { throw CameraError.invalidSetting("aperture must be positive") }
            updated.aperture = aperture
        }
        if let shutterSpeed = settings.shutterSpeed {
            try require(.shutterSpeed)
            guard shutterSpeed.seconds.isFinite, shutterSpeed.seconds > 0 else { throw CameraError.invalidSetting("shutter speed must be positive") }
            updated.shutterSpeed = shutterSpeed
        }
        if let iso = settings.iso {
            try require(.iso)
            guard iso > 0 else { throw CameraError.invalidSetting("ISO must be positive") }
            updated.iso = iso
        }
        if let compensation = settings.exposureCompensation {
            try require(.exposureCompensation)
            updated.exposureCompensation = compensation
        }
        if let whiteBalance = settings.whiteBalance {
            try require(.whiteBalance)
            updated.whiteBalance = whiteBalance
        }
        if let focusMode = settings.focusMode {
            try require(.focusMode)
            updated.focusMode = focusMode
        }
        if let exposureMode = settings.exposureMode {
            try require(.exposureMode)
            updated.exposureMode = exposureMode
        }
        currentState.settings = updated
    }

    public func capturePhoto(download: Bool = true) throws -> CapturedPhoto {
        try requireConnection()
        try require(.capturePhoto)
        defer { nextPhoto += 1 }
        let name = String(format: "IMG_%04d.JPG", nextPhoto)
        return .init(id: name, fileName: name, data: download ? Self.minimalJPEG : nil)
    }

    public func startLiveView() throws -> AsyncThrowingStream<LiveViewFrame, Error> {
        try requireConnection()
        try require(.liveView)
        guard liveViewTask == nil else { throw CameraError.liveViewAlreadyRunning }

        let (stream, continuation) = AsyncThrowingStream<LiveViewFrame, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        liveViewContinuation = continuation
        currentState.isLiveViewActive = true
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopLiveView() }
        }
        liveViewTask = Task {
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                sequence += 1
                continuation.yield(.init(jpegData: Self.minimalJPEG, sequenceNumber: sequence))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return stream
    }

    public func stopLiveView() {
        liveViewTask?.cancel()
        liveViewTask = nil
        liveViewContinuation?.finish()
        liveViewContinuation = nil
        currentState.isLiveViewActive = false
    }

    private func requireConnection() throws {
        guard connected else { throw CameraError.notConnected }
    }

    private func require(_ capability: CameraCapability) throws {
        guard supportedCapabilities.contains(capability) else { throw CameraError.unsupported(capability) }
    }

    private static let minimalJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
}

import Foundation

/// Selects conservative profiles ported from libgphoto2's `camlibs/ptp2` command sequences.
/// Unknown vendors stay on generic PTP rather than receiving unsafe vendor commands.
public enum GPhotoProfileFactory {
    public static func profile(for descriptor: CameraDescriptor) -> any PTPCameraProfile {
        switch descriptor.manufacturer {
        case .canon: CanonEOSProfile()
        case .nikon: NikonProfile()
        case .sony: SonyAlphaProfile()
        default: GenericPTPProfile()
        }
    }
}

public struct NikonProfile: PTPCameraProfile {
    public let capabilities: Set<CameraCapability> = [
        .liveView, .capturePhoto, .exposureMode, .aperture, .shutterSpeed, .iso,
        .exposureCompensation, .whiteBalance, .focusMode
    ]

    public init() {}

    public func state(using transport: any PTPTransport) async throws -> CameraState {
        try await StandardPTPSettings.state(using: transport)
    }

    public func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws {
        try await StandardPTPSettings.set(settings, using: transport)
    }

    public func capturePhoto(download: Bool, using transport: any PTPTransport) async throws -> CapturedPhoto {
        // Modern Nikon bodies use InitiateCaptureRecInMedia. Parameters mirror libgphoto2: AF on, card target.
        _ = try await transport.send(.init(operationCode: 0x9207, parameters: [1, 0]))
        guard download else { return .init(id: UUID().uuidString) }
        let handle = try await waitForObject(using: transport)
        let image = try await transport.send(.init(operationCode: PTPCode.getObject, parameters: [handle])).data
        return .init(id: String(handle), data: image)
    }

    public func startLiveView(using transport: any PTPTransport) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await transport.send(.init(operationCode: 0x9201))
        return liveViewStream(transport: transport, operation: 0x9203)
    }

    public func stopLiveView(using transport: any PTPTransport) async {
        _ = try? await transport.send(.init(operationCode: 0x9202))
    }
}

public struct CanonEOSProfile: PTPCameraProfile {
    public let capabilities: Set<CameraCapability> = [
        .liveView, .capturePhoto, .aperture, .shutterSpeed, .iso
    ]

    public init() {}

    public func state(using transport: any PTPTransport) async throws -> CameraState {
        // EOS properties are delivered through Canon event records, not standard GetDevicePropValue.
        CameraState()
    }

    public func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws {
        if settings.exposureMode != nil { throw CameraError.unsupported(.exposureMode) }
        if settings.exposureCompensation != nil { throw CameraError.unsupported(.exposureCompensation) }
        if settings.whiteBalance != nil { throw CameraError.unsupported(.whiteBalance) }
        if settings.focusMode != nil { throw CameraError.unsupported(.focusMode) }
        if let aperture = settings.aperture {
            try await setEOSProperty(0xD101, value: CanonValue.aperture(aperture), using: transport)
        }
        if let shutter = settings.shutterSpeed {
            try await setEOSProperty(0xD102, value: CanonValue.shutter(shutter.seconds), using: transport)
        }
        if let iso = settings.iso {
            try await setEOSProperty(0xD103, value: CanonValue.iso(iso), using: transport)
        }
    }

    public func capturePhoto(download: Bool, using transport: any PTPTransport) async throws -> CapturedPhoto {
        try await prepareRemote(using: transport)
        if download { await transport.markCaptureStart() }
        // Regular EOS bodies (including the 2000D) use the newer button press/release commands.
        _ = try await sendCanonRetry(.init(operationCode: 0x9128, parameters: [1, 0]), using: transport)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await sendCanonRetry(.init(operationCode: 0x9128, parameters: [2, 0]), using: transport)
        // The shutter has fired at this point. The 2000D can answer DeviceBusy while writing;
        // release is cleanup and must not turn a successful capture into an application error.
        await releaseCanonButton(2, using: transport)
        await releaseCanonButton(1, using: transport)
        if !download { return .init(id: UUID().uuidString) }

        // EOS capture files are first announced in Canon's proprietary GetEvent payload;
        // ImageCaptureCore's media catalog often does not refresh during a remote session.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let eventData = try? await transport.send(.init(operationCode: 0x9116)).data,
               let object = CanonEOSEventParser.latestJPEG(in: eventData) {
                let response = try await sendCanonRetry(
                    .init(operationCode: 0x1009, parameters: [object.handle]),
                    using: transport
                )
                return .init(id: String(object.handle), fileName: object.fileName, data: response.data)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await transport.downloadCapturedPhoto()
    }

    public func startLiveView(using transport: any PTPTransport) async throws -> AsyncThrowingStream<Data, Error> {
        try await prepareRemote(using: transport)
        try await setEOSProperty(0xD1B1, value: 1, using: transport)
        try await setEOSProperty(0xD1B0, value: 2, using: transport)
        _ = try? await transport.send(.init(operationCode: 0x9151))
        return liveViewStream(transport: transport, operation: 0x9153, parameters: [0x00200000, 0, 0])
    }

    public func stopLiveView(using transport: any PTPTransport) async {
        _ = try? await transport.send(.init(operationCode: 0x9152))
        // Output 1 routes the EVF back to the camera LCD and leaves the mirror raised.
        // Disable both EVF mode and output so stopping really closes live view on the body.
        try? await setEOSProperty(0xD1B0, value: 0, using: transport)
        try? await setEOSProperty(0xD1B1, value: 0, using: transport)
    }

    private func prepareRemote(using transport: any PTPTransport) async throws {
        _ = try await sendCanonRetry(.init(operationCode: 0x9114, parameters: [1]), using: transport)
        _ = try await sendCanonRetry(.init(operationCode: 0x9115, parameters: [1]), using: transport)
        // ImageCaptureCore may return Canon's 0x9116 event payload without a normal response
        // container. Draining is useful but must not block capture or live view on iOS.
        _ = try? await transport.send(.init(operationCode: 0x9116))
    }

    private func sendCanonRetry(_ command: PTPCommand, using transport: any PTPTransport) async throws -> PTPResponse {
        for attempt in 0..<20 {
            do { return try await transport.send(command) }
            catch PTPError.response(let code, _) where code == PTPCode.deviceBusy && attempt < 19 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw PTPError.timedOut
    }

    private func releaseCanonButton(_ button: UInt32, using transport: any PTPTransport) async {
        for attempt in 0..<10 {
            do {
                _ = try await transport.send(.init(operationCode: 0x9129, parameters: [button]))
                return
            } catch PTPError.response(let code, _) where code == PTPCode.deviceBusy {
                if attempt < 9 { try? await Task.sleep(nanoseconds: 50_000_000) }
            } catch {
                return
            }
        }
    }

    private func setEOSProperty(_ property: UInt32, value: UInt32, using transport: any PTPTransport) async throws {
        var payload = Data()
        payload.appendLE(UInt32(12))
        payload.appendLE(property)
        payload.appendLE(value)
        _ = try await transport.send(.init(operationCode: 0x9110, data: payload))
    }
}

enum CanonEOSEventParser {
    struct Object: Equatable {
        let handle: UInt32
        let fileName: String?
    }

    static func latestJPEG(in data: Data) -> Object? {
        var offset = 0
        var latest: Object?
        while offset + 8 <= data.count {
            let size = Int(data.uint32LE(at: offset))
            guard size >= 8, offset + size <= data.count else { break }
            let code = data.uint32LE(at: offset + 4)
            let nameOffset: Int?
            switch code {
            case 0xC186, 0xC1A9: nameOffset = 0x1C
            case 0xC181: nameOffset = 0x28
            case 0xC1A7: nameOffset = 0x2C
            case 0xC1B8: nameOffset = nil
            default: nameOffset = nil
            }
            if [0xC186, 0xC1A9, 0xC181, 0xC1A7, 0xC1B8].contains(code),
               offset + 12 <= data.count {
                let handle = data.uint32LE(at: offset + 8)
                let fileName = nameOffset.flatMap { asciiString(in: data, from: offset + $0, to: offset + size) }
                if fileName == nil || ["jpg", "jpeg"].contains((fileName! as NSString).pathExtension.lowercased()) {
                    latest = .init(handle: handle, fileName: fileName)
                }
            }
            offset += size
        }
        return latest
    }

    private static func asciiString(in data: Data, from start: Int, to end: Int) -> String? {
        guard start < end, start < data.count else { return nil }
        let bytes = data[start..<min(end, data.count)].prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(data: bytes, encoding: .utf8)
    }
}

public struct SonyAlphaProfile: PTPCameraProfile {
    public let capabilities: Set<CameraCapability> = [
        .liveView, .capturePhoto, .exposureMode, .aperture, .shutterSpeed, .iso,
        .exposureCompensation, .whiteBalance, .focusMode
    ]

    public init() {}

    public func state(using transport: any PTPTransport) async throws -> CameraState {
        try await StandardPTPSettings.state(using: transport)
    }

    public func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws {
        try await StandardPTPSettings.set(settings, using: transport)
    }

    public func capturePhoto(download: Bool, using transport: any PTPTransport) async throws -> CapturedPhoto {
        try await sonyButton(property: 0xD2C1, value: 2, using: transport)
        try await sonyButton(property: 0xD2C2, value: 2, using: transport)
        try await Task.sleep(nanoseconds: 250_000_000)
        try await sonyButton(property: 0xD2C2, value: 1, using: transport)
        try await sonyButton(property: 0xD2C1, value: 1, using: transport)
        guard download else { return .init(id: UUID().uuidString) }
        let data = try await retrying { try await transport.send(
            .init(operationCode: PTPCode.getObject, parameters: [0xFFFFC001])
        ).data }
        return .init(id: "ffffc001", data: data)
    }

    public func startLiveView(using transport: any PTPTransport) async throws -> AsyncThrowingStream<Data, Error> {
        // Sony exposes live view as the synthetic PTP object 0xffffc002.
        liveViewStream(transport: transport, operation: PTPCode.getObject, parameters: [0xFFFFC002])
    }

    public func stopLiveView(using transport: any PTPTransport) async {}

    private func sonyButton(property: UInt32, value: UInt16, using transport: any PTPTransport) async throws {
        var payload = Data()
        payload.appendLE(value)
        _ = try await transport.send(.init(operationCode: 0x9207, parameters: [property], data: payload))
    }
}

private enum StandardPTPSettings {
    static func state(using transport: any PTPTransport) async throws -> CameraState {
        var settings = CameraSettings()
        settings.aperture = try? await value(.aperture, as: UInt16.self, using: transport).map { Double($0) / 100 }
        settings.shutterSpeed = try? await value(.shutterSpeed, as: UInt32.self, using: transport).map {
            ShutterSpeed(seconds: Double($0) / 10_000)
        }
        settings.iso = try? await value(.iso, as: UInt16.self, using: transport).map(Int.init)
        return CameraState(settings: settings)
    }

    static func set(_ settings: CameraSettings, using transport: any PTPTransport) async throws {
        if let aperture = settings.aperture { try await set(.aperture, UInt16(aperture * 100), using: transport) }
        if let shutter = settings.shutterSpeed { try await set(.shutterSpeed, UInt32(shutter.seconds * 10_000), using: transport) }
        if let iso = settings.iso { try await set(.iso, UInt16(iso), using: transport) }
        if settings.exposureMode != nil { throw CameraError.unsupported(.exposureMode) }
        if settings.exposureCompensation != nil { throw CameraError.unsupported(.exposureCompensation) }
        if settings.whiteBalance != nil { throw CameraError.unsupported(.whiteBalance) }
        if settings.focusMode != nil { throw CameraError.unsupported(.focusMode) }
    }

    private static func value<T: FixedWidthInteger>(
        _ property: Property, as: T.Type, using transport: any PTPTransport
    ) async throws -> T? {
        let data = try await transport.send(.init(
            operationCode: PTPCode.getDevicePropValue, parameters: [property.rawValue]
        )).data
        guard data.count >= MemoryLayout<T>.size else { return nil }
        return data.prefix(MemoryLayout<T>.size).enumerated().reduce(0) { $0 | T($1.element) << ($1.offset * 8) }
    }

    private static func set<T: FixedWidthInteger>(
        _ property: Property, _ value: T, using transport: any PTPTransport
    ) async throws {
        var data = Data()
        data.appendLE(value)
        _ = try await transport.send(.init(
            operationCode: PTPCode.setDevicePropValue, parameters: [property.rawValue], data: data
        ))
    }

    private enum Property: UInt32 { case aperture = 0x5007, shutterSpeed = 0x500D, iso = 0x500F }
}

private enum CanonValue {
    static func aperture(_ value: Double) throws -> UInt32 {
        guard value.isFinite, value > 0 else { throw CameraError.invalidSetting("aperture must be positive") }
        return nearest(value, in: apertureValues)
    }

    static func shutter(_ seconds: Double) throws -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { throw CameraError.invalidSetting("shutter speed must be positive") }
        return nearest(seconds, in: shutterValues)
    }

    static func iso(_ value: Int) throws -> UInt32 {
        guard value > 0 else { throw CameraError.invalidSetting("ISO must be positive") }
        return nearest(Double(value), in: isoValues)
    }

    private static func nearest(_ value: Double, in values: [(Double, UInt32)]) -> UInt32 {
        values.min { abs($0.0 - value) < abs($1.0 - value) }!.1
    }

    private static let apertureValues: [(Double, UInt32)] = [
        (1, 0x08), (1.4, 0x10), (2, 0x18), (2.8, 0x20), (4, 0x28),
        (5.6, 0x30), (8, 0x38), (11, 0x40), (16, 0x48), (22, 0x50), (32, 0x58)
    ]
    private static let shutterValues: [(Double, UInt32)] = [
        (30, 0x10), (15, 0x18), (8, 0x20), (4, 0x28), (2, 0x30), (1, 0x38),
        (0.5, 0x40), (1.0/4, 0x48), (1.0/8, 0x50), (1.0/15, 0x58),
        (1.0/30, 0x60), (1.0/60, 0x68), (1.0/125, 0x70), (1.0/250, 0x78),
        (1.0/500, 0x80), (1.0/1000, 0x88), (1.0/2000, 0x90), (1.0/4000, 0x98),
        (1.0/8000, 0xA0)
    ]
    private static let isoValues: [(Double, UInt32)] = [
        (50, 0x40), (100, 0x48), (200, 0x50), (400, 0x58), (800, 0x60),
        (1600, 0x68), (3200, 0x70), (6400, 0x78), (12800, 0x80), (25600, 0x88),
        (51200, 0x90), (102400, 0x98)
    ]
}

private func liveViewStream(
    transport: any PTPTransport, operation: UInt16, parameters: [UInt32] = []
) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
        let task = Task {
            while !Task.isCancelled {
                do {
                    let payload = try await transport.send(.init(operationCode: operation, parameters: parameters)).data
                    guard let jpeg = payload.jpegPayload() else { throw CameraError.transport("Live view returned no JPEG") }
                    continuation.yield(jpeg)
                } catch PTPError.response(let code, _) where code == PTPCode.deviceBusy || code == 0xA102 || code == 0xA00B {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func waitForObject(using transport: any PTPTransport) async throws -> UInt32 {
    try await withThrowingTaskGroup(of: UInt32.self) { group in
        group.addTask {
            for await event in transport.events where event.code == PTPCode.objectAdded {
                if let handle = event.parameters.first { return handle }
            }
            throw PTPError.disconnected
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 35_000_000_000)
            throw PTPError.timedOut
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func retrying<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    for attempt in 0..<100 {
        do { return try await operation() }
        catch PTPError.response(let code, _) where code == PTPCode.deviceBusy || code == 0x2009 {
            if attempt == 99 { throw PTPError.timedOut }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    throw PTPError.timedOut
}

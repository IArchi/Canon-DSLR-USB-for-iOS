import Foundation
import Testing
@testable import DSLRKit

@Test func cameraRequiresConnection() async {
    let camera = SimulatedCamera()
    await #expect(throws: CameraError.notConnected) {
        _ = try await camera.state()
    }
}

@Test func settingsCaptureAndLiveView() async throws {
    let camera = SimulatedCamera()
    try await camera.connect()

    try await camera.set(.init(aperture: 8, shutterSpeed: .fraction(250), iso: 400))
    let state = try await camera.state()
    #expect(state.settings.aperture == 8)
    #expect(state.settings.shutterSpeed == .fraction(250))
    #expect(state.settings.iso == 400)

    let photo = try await camera.capturePhoto(download: true)
    #expect(photo.fileName == "IMG_0001.JPG")
    #expect(photo.data?.starts(with: [0xFF, 0xD8]) == true)

    let stream = try await camera.startLiveView()
    var iterator = stream.makeAsyncIterator()
    let frame = try await iterator.next()
    #expect(frame?.sequenceNumber == 1)
    #expect(frame?.jpegData.starts(with: [0xFF, 0xD8]) == true)
    await camera.stopLiveView()
    #expect(try await camera.state().isLiveViewActive == false)
}

@Test func unsupportedCapabilityFailsExplicitly() async throws {
    let camera = SimulatedCamera(capabilities: [.capturePhoto])
    try await camera.connect()
    await #expect(throws: CameraError.unsupported(.iso)) {
        try await camera.set(.init(iso: 800))
    }
}

@Test func settingsUpdateIsAtomic() async throws {
    let camera = SimulatedCamera()
    try await camera.connect()
    let before = try await camera.state().settings
    await #expect(throws: CameraError.invalidSetting("ISO must be positive")) {
        try await camera.set(.init(aperture: 11, iso: 0))
    }
    #expect(try await camera.state().settings == before)
}

@Test func invalidShutterSpeedDoesNotTrap() {
    #expect(ShutterSpeed.fraction(0).description == "invalid")
}

@Test func ptpCommandUsesLittleEndianContainerFormat() {
    let packet = PTPPacket.commandData(
        for: .init(operationCode: PTPCode.getDevicePropValue, parameters: [0x500F]),
        transactionID: 7
    )
    #expect(packet == Data([
        0x10, 0, 0, 0, 1, 0, 0x15, 0x10, 7, 0, 0, 0, 0x0F, 0x50, 0, 0
    ]))
}

@Test func ptpResponseRejectsWrongContainerType() {
    let commandPacket = PTPPacket.commandData(for: .init(operationCode: PTPCode.getDeviceInfo), transactionID: 1)
    #expect(throws: PTPError.malformedPacket) {
        _ = try PTPPacket.response(from: commandPacket)
    }
}

@Test func imageCaptureResponseUsesDataPhaseFromFirstBlob() throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let responsePacket = Data([12, 0, 0, 0, 3, 0, 1, 0x20, 1, 0, 0, 0])
    let response = try PTPPacket.response(from: jpeg, second: responsePacket)
    #expect(response.responseCode == PTPCode.ok)
    #expect(response.data == jpeg)
}

@Test func imageCaptureResponseAcceptsReversedBlobs() throws {
    let payload = Data([1, 2, 3])
    let responsePacket = Data([12, 0, 0, 0, 3, 0, 1, 0x20, 1, 0, 0, 0])
    #expect(try PTPPacket.response(from: responsePacket, second: payload).data == payload)
}

@Test func ptpEventDecodesParameters() throws {
    let packet = Data([16, 0, 0, 0, 4, 0, 6, 0x40, 2, 0, 0, 0, 0x0F, 0x50, 0, 0])
    #expect(try PTPPacket.event(from: packet) == .init(code: PTPCode.devicePropChanged, parameters: [0x500F]))
}

@Test func jpegIsExtractedFromVendorLiveViewEnvelope() {
    let envelope = Data([1, 2, 3, 0xFF, 0xD8, 4, 5, 0xFF, 0xD9, 6])
    #expect(envelope.jpegPayload() == Data([0xFF, 0xD8, 4, 5, 0xFF, 0xD9]))
}

@Test func factorySelectsVendorProfiles() {
    let canon = CameraDescriptor(id: "1", manufacturer: .canon, model: "EOS")
    let nikon = CameraDescriptor(id: "2", manufacturer: .nikon, model: "Z")
    let sony = CameraDescriptor(id: "3", manufacturer: .sony, model: "Alpha")
    #expect(GPhotoProfileFactory.profile(for: canon) is CanonEOSProfile)
    #expect(GPhotoProfileFactory.profile(for: nikon) is NikonProfile)
    #expect(GPhotoProfileFactory.profile(for: sony) is SonyAlphaProfile)
}

@Test func canonISOUsesEOSPropertyEnvelope() async throws {
    let transport = RecordingPTPTransport()
    try await CanonEOSProfile().set(.init(iso: 400), using: transport)
    let command = await transport.commands.first
    #expect(command?.operationCode == 0x9110)
    #expect(command?.data == Data([12, 0, 0, 0, 3, 0xD1, 0, 0, 0x58, 0, 0, 0]))
}

@Test func canonCaptureUsesEOS2000DButtonSequence() async throws {
    let transport = RecordingPTPTransport()
    let photo = try await CanonEOSProfile().capturePhoto(download: false, using: transport)
    let commands = await transport.commands
    #expect(commands.map(\.operationCode) == [0x9114, 0x9115, 0x9116, 0x9128, 0x9128, 0x9129, 0x9129])
    #expect(commands.suffix(4).map(\.parameters) == [[1, 0], [2, 0], [2], [1]])
    #expect(photo.data == nil)
}

@Test func canonCaptureContinuesWhenEventDrainHasNoPTPResponse() async throws {
    let transport = RecordingPTPTransport(failingOperation: 0x9116)
    _ = try await CanonEOSProfile().capturePhoto(download: false, using: transport)
    #expect(await transport.commands.last?.operationCode == 0x9129)
}

@Test func canonCaptureSucceedsWhenReleaseIsTemporarilyBusy() async throws {
    let transport = RecordingPTPTransport(failingOperation: 0x9129, failure: .response(code: PTPCode.deviceBusy, parameters: [0]))
    let photo = try await CanonEOSProfile().capturePhoto(download: false, using: transport)
    let commands = await transport.commands
    #expect(commands.filter { $0.operationCode == 0x9128 }.count == 2)
    #expect(commands.filter { $0.operationCode == 0x9129 }.count == 3)
    #expect(photo.data == nil)
}

@Test func canonCaptureRetriesBusyHalfPressWithoutDoubleCapture() async throws {
    let transport = RecordingPTPTransport(failingOperation: 0x9128, failure: .response(code: PTPCode.deviceBusy, parameters: [0]))
    _ = try await CanonEOSProfile().capturePhoto(download: false, using: transport)
    let presses = await transport.commands.filter { $0.operationCode == 0x9128 }
    #expect(presses.map(\.parameters) == [[1, 0], [1, 0], [2, 0]])
}

@Test func canonCaptureDownloadsWhenFullPressReturnsBusy() async throws {
    let transport = RecordingPTPTransport(
        failingOperation: 0x9128,
        failure: .response(code: PTPCode.deviceBusy, parameters: [0]),
        failOccurrence: 2,
        capturedEventData: canonTransferEvent(handle: 42, name: "IMG_0001.JPG"),
        capturedObjectData: Data([0xFF, 0xD8])
    )
    let photo = try await CanonEOSProfile().capturePhoto(download: true, using: transport)
    #expect(photo.data == Data([0xFF, 0xD8]))
    #expect(await transport.commands.filter { $0.operationCode == 0x9128 }.count == 3)
}

private func canonTransferEvent(handle: UInt32, name: String) -> Data {
    var data = Data()
    let size = 28 + name.utf8.count + 1
    data.appendLE(UInt32(size)); data.appendLE(UInt32(0xC186)); data.appendLE(handle)
    data.appendLE(UInt16(0x3801)); data.append(Data(repeating: 0, count: 14)); data.append(Data("\(name)\0".utf8))
    return data
}

@Test func canonStopLiveViewDisablesCameraEVF() async {
    let transport = RecordingPTPTransport()
    await CanonEOSProfile().stopLiveView(using: transport)
    let commands = await transport.commands
    #expect(commands.map(\.operationCode) == [0x9152, 0x9110, 0x9110])
    #expect(commands[1].data == Data([12, 0, 0, 0, 0xB0, 0xD1, 0, 0, 0, 0, 0, 0]))
    #expect(commands[2].data == Data([12, 0, 0, 0, 0xB1, 0xD1, 0, 0, 0, 0, 0, 0]))
}

@Test func canonEventParserFindsRequestedJPEG() {
    var event = Data()
    event.appendLE(UInt32(41))
    event.appendLE(UInt32(0xC186))
    event.appendLE(UInt32(0x12345678))
    event.appendLE(UInt16(0x3801))
    event.append(Data(repeating: 0, count: 6))
    event.appendLE(UInt32(1234))
    event.appendLE(UInt32(0))
    event.append(Data("IMG_0001.JPG\0".utf8))
    #expect(CanonEOSEventParser.latestJPEG(in: event) == .init(handle: 0x12345678, fileName: "IMG_0001.JPG"))
}

@Test func canonEventParserIgnoresRawWhenJPEGFollows() {
    func event(handle: UInt32, name: String) -> Data {
        var data = Data()
        let size = 28 + name.utf8.count + 1
        data.appendLE(UInt32(size)); data.appendLE(UInt32(0xC186)); data.appendLE(handle)
        data.appendLE(UInt16(0)); data.append(Data(repeating: 0, count: 14)); data.append(Data("\(name)\0".utf8))
        return data
    }
    let parsed = CanonEOSEventParser.latestJPEG(in: event(handle: 1, name: "IMG.CR2") + event(handle: 2, name: "IMG.JPG"))
    #expect(parsed?.handle == 2)
}

@Test func ptpErrorDescribesCameraResponseCode() {
    let error = PTPError.response(code: PTPCode.operationNotSupported, parameters: [])
    #expect(error.localizedDescription.contains("0x2005"))
}

private actor RecordingPTPTransport: PTPTransport {
    nonisolated let events = AsyncStream<PTPEvent> { $0.finish() }
    private(set) var commands: [PTPCommand] = []
    private let failingOperation: UInt16?
    private let failure: PTPError
    private let downloadedPhoto: CapturedPhoto?
    private let failOccurrence: Int
    private let capturedEventData: Data?
    private let capturedObjectData: Data?
    private(set) var didMarkCaptureStart = false

    init(
        failingOperation: UInt16? = nil,
        failure: PTPError = .malformedPacket,
        failOccurrence: Int = 1,
        downloadedPhoto: CapturedPhoto? = nil,
        capturedEventData: Data? = nil,
        capturedObjectData: Data? = nil
    ) {
        self.failingOperation = failingOperation
        self.failure = failure
        self.failOccurrence = failOccurrence
        self.downloadedPhoto = downloadedPhoto
        self.capturedEventData = capturedEventData
        self.capturedObjectData = capturedObjectData
    }

    func open() {}
    func close() {}
    func send(_ command: PTPCommand) throws -> PTPResponse {
        commands.append(command)
        if command.operationCode == failingOperation,
           commands.filter({ $0.operationCode == failingOperation }).count == failOccurrence { throw failure }
        if command.operationCode == 0x9116,
           commands.filter({ $0.operationCode == 0x9128 }).count >= 2,
           let capturedEventData { return .init(responseCode: PTPCode.ok, data: capturedEventData) }
        if command.operationCode == 0x1009, let capturedObjectData {
            return .init(responseCode: PTPCode.ok, data: capturedObjectData)
        }
        return .init(responseCode: PTPCode.ok)
    }

    func markCaptureStart() { didMarkCaptureStart = true }

    func downloadCapturedPhoto() throws -> CapturedPhoto {
        guard let downloadedPhoto else { throw CameraError.unsupported(.capturePhoto) }
        return downloadedPhoto
    }
}

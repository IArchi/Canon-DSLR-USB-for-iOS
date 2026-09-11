#if canImport(ImageCaptureCore)
@preconcurrency import ImageCaptureCore
import Foundation

/// PTP-over-USB implementation using Apple's public ImageCaptureCore API. This is the supported
/// iPhone/iPad path; iOS does not expose libusb to ordinary applications.
public final class ImageCapturePTPTransport: NSObject, PTPTransport, @unchecked Sendable, ICCameraDeviceDelegate {
    public let events: AsyncStream<PTPEvent>

    private let camera: ICCameraDevice
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    private let lock = NSLock()
    private var transactionID: UInt32 = 0
    private var filesBeforeCapture: Set<String> = []
    private var addedFiles: [ICCameraFile] = []

    public init(camera: ICCameraDevice) {
        self.camera = camera
        (events, eventContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
        super.init()
        camera.delegate = self
        camera.ptpEventHandler = { [eventContinuation] packet in
            guard let event = try? PTPPacket.event(from: packet) else { return }
            eventContinuation.yield(event)
        }
    }

    deinit { eventContinuation.finish() }

    public func open() async throws {
        guard !camera.hasOpenSession else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            camera.requestOpenSession(options: nil) { error in
                if let error { continuation.resume(throwing: CameraError.transport(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }

    public func close() async {
        guard camera.hasOpenSession else { return }
        await withCheckedContinuation { continuation in
            camera.requestCloseSession(options: nil) { _ in continuation.resume() }
        }
    }

    public func send(_ command: PTPCommand) async throws -> PTPResponse {
        let transaction = lock.withLock {
            transactionID &+= 1
            return transactionID
        }
        let packet = PTPPacket.commandData(for: command, transactionID: transaction)
        return try await withCheckedThrowingContinuation { continuation in
            camera.requestSendPTPCommand(packet, outData: command.data) { first, second, error in
                do {
                    if let error { throw CameraError.transport(error.localizedDescription) }
                    let response: PTPResponse
                    do {
                        response = try PTPPacket.response(from: first, second: second)
                    } catch {
                        throw PTPError.malformedResponse(
                            operationCode: command.operationCode,
                            first: first.prefix(24),
                            second: second.prefix(24)
                        )
                    }
                    guard response.responseCode == PTPCode.ok else {
                        throw PTPError.response(code: response.responseCode, parameters: response.parameters)
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func markCaptureStart() async {
        filesBeforeCapture = Set((camera.mediaFiles ?? []).compactMap { Self.fileKey($0 as? ICCameraFile) })
        lock.withLock { addedFiles.removeAll() }
    }

    public func downloadCapturedPhoto() async throws -> CapturedPhoto {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let file = newestCapturedFile() { return try await download(file) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PTPError.timedOut
    }

    private func newestCapturedFile() -> ICCameraFile? {
        let files = lock.withLock { addedFiles } + (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        return files
            .filter { file in
                guard let key = Self.fileKey(file), !filesBeforeCapture.contains(key) else { return false }
                let ext = (file.name as NSString?)?.pathExtension.lowercased() ?? ""
                return ["jpg", "jpeg", "heic"].contains(ext)
            }
            .max { ($0.fileCreationDate ?? .distantPast) < ($1.fileCreationDate ?? .distantPast) }
    }

    private func download(_ file: ICCameraFile) async throws -> CapturedPhoto {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalName = file.name ?? "capture.jpg"
        let savedName = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            file.requestDownload(options: [
                .downloadsDirectoryURL: directory,
                .saveAsFilename: originalName,
                .overwrite: true
            ]) { filename, error in
                if let error { continuation.resume(throwing: CameraError.transport(error.localizedDescription)) }
                else if let filename { continuation.resume(returning: filename) }
                else { continuation.resume(throwing: CameraError.transport("Téléchargement terminé sans fichier")) }
            }
        }
        let url = directory.appendingPathComponent(savedName)
        return .init(id: Self.fileKey(file) ?? UUID().uuidString, fileName: savedName, data: try Data(contentsOf: url))
    }

    private static func fileKey(_ file: ICCameraFile?) -> String? {
        guard let file else { return nil }
        return "\(file.name ?? "")|\(file.fileSize)|\(file.fileCreationDate?.timeIntervalSince1970 ?? 0)"
    }

    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        lock.withLock { addedFiles.append(contentsOf: items.compactMap { $0 as? ICCameraFile }) }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    public func didRemove(_ device: ICDevice) { eventContinuation.finish() }
    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {}
}

/// Discovers USB PTP cameras and turns each one into the same `Camera` abstraction.
/// Supply profiles for vendor-specific controls; unknown models receive `GenericPTPProfile`.
@MainActor
public final class ImageCaptureCameraDiscovery: NSObject, CameraDiscovery, @preconcurrency ICDeviceBrowserDelegate {
    public typealias ProfileProvider = @Sendable (CameraDescriptor) -> any PTPCameraProfile

    private let browser = ICDeviceBrowser()
    private let profileProvider: ProfileProvider
    private var continuation: AsyncThrowingStream<DiscoveredCamera, Error>.Continuation?

    public init(profileProvider: @escaping ProfileProvider = GPhotoProfileFactory.profile) {
        self.profileProvider = profileProvider
        super.init()
        browser.delegate = self
        if #available(iOS 15.2, macOS 10.15, *) {
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x0101)!
        }
    }

    public func cameras() -> AsyncThrowingStream<DiscoveredCamera, Error> {
        let (stream, continuation) = AsyncThrowingStream<DiscoveredCamera, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.continuation?.finish()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }

        #if os(iOS)
        if #available(iOS 14, *) {
            browser.requestControlAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if status == .authorized { self.browser.start() }
                    else { self.continuation?.finish(throwing: CameraError.authorizationDenied) }
                }
            }
        } else {
            browser.start()
        }
        #else
        browser.start()
        #endif
        return stream
    }

    public func stop() {
        browser.stop()
        continuation?.finish()
        continuation = nil
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let device = device as? ICCameraDevice,
              device.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return }
        let descriptor = Self.descriptor(for: device)
        let bridge = PTPCameraBridge(
            descriptor: descriptor,
            transport: ImageCapturePTPTransport(camera: device),
            profile: profileProvider(descriptor)
        )
        continuation?.yield(.init(descriptor: descriptor, camera: VendorCamera(bridge: bridge)))
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}

    private static func descriptor(for device: ICDevice) -> CameraDescriptor {
        let vendorID = UInt16(clamping: device.usbVendorID)
        let manufacturer: CameraManufacturer = switch vendorID {
        case 0x04A9: .canon
        case 0x04B0: .nikon
        case 0x054C: .sony
        default: .other
        }
        return .init(
            id: device.uuidString ?? "usb-\(device.usbLocationID)",
            manufacturer: manufacturer,
            model: device.name ?? device.productKind ?? "PTP Camera",
            transport: .usb,
            usbVendorID: vendorID,
            usbProductID: UInt16(clamping: device.usbProductID)
        )
    }
}
#endif

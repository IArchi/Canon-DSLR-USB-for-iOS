import Foundation

public enum CameraManufacturer: String, Sendable, CaseIterable {
    case canon
    case nikon
    case sony
    case other
    case simulated
}

public struct CameraDescriptor: Hashable, Sendable {
    public let id: String
    public let manufacturer: CameraManufacturer
    public let model: String
    public let transport: CameraTransport
    public let usbVendorID: UInt16?
    public let usbProductID: UInt16?

    public init(
        id: String,
        manufacturer: CameraManufacturer,
        model: String,
        transport: CameraTransport = .unknown,
        usbVendorID: UInt16? = nil,
        usbProductID: UInt16? = nil
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.transport = transport
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
    }
}

public enum CameraTransport: String, Hashable, Sendable {
    case usb
    case network
    case simulated
    case unknown
}

public enum CameraCapability: String, Hashable, Sendable, CaseIterable {
    case liveView
    case capturePhoto
    case exposureMode
    case aperture
    case shutterSpeed
    case iso
    case exposureCompensation
    case whiteBalance
    case focusMode
}

public enum ExposureMode: String, Sendable, CaseIterable {
    case program
    case aperturePriority
    case shutterPriority
    case manual
}

public struct ShutterSpeed: Hashable, Sendable, CustomStringConvertible {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public static func fraction(_ denominator: Int) -> Self {
        Self(seconds: denominator > 0 ? 1 / Double(denominator) : .nan)
    }

    public var description: String {
        guard seconds.isFinite, seconds > 0 else { return "invalid" }
        return seconds >= 1 ? "\(seconds)s" : "1/\(Int((1 / seconds).rounded()))"
    }
}

public enum WhiteBalance: String, Sendable, CaseIterable {
    case auto
    case daylight
    case shade
    case cloudy
    case tungsten
    case fluorescent
    case flash
}

public enum FocusMode: String, Sendable, CaseIterable {
    case manual
    case single
    case continuous
}

public struct CameraSettings: Equatable, Sendable {
    public var exposureMode: ExposureMode?
    public var aperture: Double?
    public var shutterSpeed: ShutterSpeed?
    public var iso: Int?
    public var exposureCompensation: Double?
    public var whiteBalance: WhiteBalance?
    public var focusMode: FocusMode?

    public init(
        exposureMode: ExposureMode? = nil,
        aperture: Double? = nil,
        shutterSpeed: ShutterSpeed? = nil,
        iso: Int? = nil,
        exposureCompensation: Double? = nil,
        whiteBalance: WhiteBalance? = nil,
        focusMode: FocusMode? = nil
    ) {
        self.exposureMode = exposureMode
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.exposureCompensation = exposureCompensation
        self.whiteBalance = whiteBalance
        self.focusMode = focusMode
    }
}

public struct CameraState: Equatable, Sendable {
    public var settings: CameraSettings
    public var batteryPercent: Int?
    public var isLiveViewActive: Bool

    public init(settings: CameraSettings = .init(), batteryPercent: Int? = nil, isLiveViewActive: Bool = false) {
        self.settings = settings
        self.batteryPercent = batteryPercent
        self.isLiveViewActive = isLiveViewActive
    }
}

public struct LiveViewFrame: Sendable {
    /// JPEG bytes, deliberately not UIImage so decoding stays under the app's control.
    public let jpegData: Data
    public let sequenceNumber: UInt64
    public let timestamp: Date

    public init(jpegData: Data, sequenceNumber: UInt64, timestamp: Date = Date()) {
        self.jpegData = jpegData
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
    }
}

public struct CapturedPhoto: Sendable {
    public let id: String
    public let fileName: String?
    public let data: Data?
    public let remoteURL: URL?

    public init(id: String, fileName: String? = nil, data: Data? = nil, remoteURL: URL? = nil) {
        self.id = id
        self.fileName = fileName
        self.data = data
        self.remoteURL = remoteURL
    }
}

public enum CameraError: Error, Equatable, Sendable {
    case notConnected
    case alreadyConnected
    case liveViewAlreadyRunning
    case liveViewNotRunning
    case unsupported(CameraCapability)
    case invalidSetting(String)
    case authorizationDenied
    case transport(String)
}

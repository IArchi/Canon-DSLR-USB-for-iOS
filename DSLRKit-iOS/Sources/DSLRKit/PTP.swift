import Foundation

/// A transport-independent PTP command. ImageCaptureCore supplies the USB transport on iOS.
public struct PTPCommand: Equatable, Sendable {
    public let operationCode: UInt16
    public let parameters: [UInt32]
    public let data: Data?

    public init(operationCode: UInt16, parameters: [UInt32] = [], data: Data? = nil) {
        self.operationCode = operationCode
        self.parameters = parameters
        self.data = data
    }
}

public struct PTPResponse: Equatable, Sendable {
    public let responseCode: UInt16
    public let parameters: [UInt32]
    public let data: Data

    public init(responseCode: UInt16, parameters: [UInt32] = [], data: Data = Data()) {
        self.responseCode = responseCode
        self.parameters = parameters
        self.data = data
    }
}

public struct PTPEvent: Equatable, Sendable {
    public let code: UInt16
    public let parameters: [UInt32]

    public init(code: UInt16, parameters: [UInt32] = []) {
        self.code = code
        self.parameters = parameters
    }
}

public enum PTPCode {
    public static let ok: UInt16 = 0x2001
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let operationNotSupported: UInt16 = 0x2005
    public static let deviceBusy: UInt16 = 0x2019

    public static let getDeviceInfo: UInt16 = 0x1001
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let initiateCapture: UInt16 = 0x100E
    public static let getDevicePropDesc: UInt16 = 0x1014
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016

    public static let objectAdded: UInt16 = 0x4002
    public static let devicePropChanged: UInt16 = 0x4006
    public static let captureComplete: UInt16 = 0x400D
}

enum PTPProperty {
    static let whiteBalance: UInt32 = 0x5005
    static let aperture: UInt32 = 0x5007
    static let focusMode: UInt32 = 0x500A
    static let shutterSpeed: UInt32 = 0x500D
    static let exposureMode: UInt32 = 0x500E
    static let iso: UInt32 = 0x500F
    static let exposureCompensation: UInt32 = 0x5010
}

public enum PTPError: Error, Equatable, Sendable {
    case malformedPacket
    case malformedResponse(operationCode: UInt16, first: Data, second: Data)
    case response(code: UInt16, parameters: [UInt32])
    case timedOut
    case disconnected
}

extension PTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedPacket: "Réponse PTP invalide"
        case .malformedResponse(let operationCode, let first, let second):
            "Réponse PTP invalide pour 0x\(String(operationCode, radix: 16, uppercase: true)) " +
            "(bloc 1: \(first.hexPrefix), bloc 2: \(second.hexPrefix))"
        case .response(let code, let parameters):
            "Commande PTP refusée (code 0x\(String(code, radix: 16, uppercase: true)), paramètres \(parameters))"
        case .timedOut: "Délai d’attente PTP dépassé"
        case .disconnected: "Appareil PTP déconnecté"
        }
    }
}

/// Serialized command channel. A concrete implementation can use USB, TCP/IP or a test double.
public protocol PTPTransport: Sendable {
    var events: AsyncStream<PTPEvent> { get }
    func open() async throws
    func close() async
    func send(_ command: PTPCommand) async throws -> PTPResponse
    func markCaptureStart() async
    func downloadCapturedPhoto() async throws -> CapturedPhoto
}

public extension PTPTransport {
    func markCaptureStart() async {}
    func downloadCapturedPhoto() async throws -> CapturedPhoto { throw CameraError.unsupported(.capturePhoto) }
}

public enum PTPPacket {
    private static let commandContainer: UInt16 = 1
    private static let responseContainer: UInt16 = 3
    private static let eventContainer: UInt16 = 4

    public static func commandData(for command: PTPCommand, transactionID: UInt32) -> Data {
        var result = Data()
        result.appendLE(UInt32(12 + command.parameters.count * 4))
        result.appendLE(commandContainer)
        result.appendLE(command.operationCode)
        result.appendLE(transactionID)
        for parameter in command.parameters { result.appendLE(parameter) }
        return result
    }

    public static func response(from packet: Data, data: Data = Data()) throws -> PTPResponse {
        guard packet.count >= 12,
              packet.uint32LE(at: 0) == packet.count,
              packet.uint16LE(at: 4) == responseContainer else { throw PTPError.malformedPacket }
        let code = packet.uint16LE(at: 6)
        var parameters: [UInt32] = []
        for offset in stride(from: 12, to: packet.count, by: 4) {
            guard offset + 4 <= packet.count else { throw PTPError.malformedPacket }
            parameters.append(packet.uint32LE(at: offset))
        }
        return PTPResponse(responseCode: code, parameters: parameters, data: data)
    }

    /// ImageCaptureCore returns the incoming data phase and response container as two blobs.
    /// Their documented names have varied, so identify the response by its PTP container type.
    public static func response(from first: Data, second: Data) throws -> PTPResponse {
        if let response = try? response(from: second, data: first) { return response }
        if let response = try? response(from: first, data: second) { return response }
        throw PTPError.malformedPacket
    }

    public static func event(from packet: Data) throws -> PTPEvent {
        guard packet.count >= 12,
              packet.uint32LE(at: 0) == packet.count,
              packet.uint16LE(at: 4) == eventContainer else { throw PTPError.malformedPacket }
        var parameters: [UInt32] = []
        for offset in stride(from: 12, to: packet.count, by: 4) {
            guard offset + 4 <= packet.count else { throw PTPError.malformedPacket }
            parameters.append(packet.uint32LE(at: offset))
        }
        return PTPEvent(code: packet.uint16LE(at: 6), parameters: parameters)
    }
}

extension Data {
    var hexPrefix: String {
        if isEmpty { return "vide" }
        return prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }


    func jpegPayload() -> Data? {
        guard let start = firstRange(of: Data([0xFF, 0xD8]))?.lowerBound,
              let end = self[start...].firstRange(of: Data([0xFF, 0xD9]))?.upperBound else { return nil }
        return self[start..<end]
    }
}

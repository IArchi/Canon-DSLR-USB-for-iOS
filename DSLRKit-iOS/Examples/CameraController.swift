import DSLRKit
import Foundation

/// Minimal controller usable from a SwiftUI or UIKit application.
@MainActor
final class CameraController: ObservableObject {
    @Published private(set) var cameras: [DiscoveredCamera] = []
    @Published private(set) var liveViewJPEG: Data?
    @Published private(set) var lastPhoto: CapturedPhoto?
    @Published private(set) var errorMessage: String?

    private let discovery = ImageCaptureCameraDiscovery()
    private var liveViewTask: Task<Void, Never>?

    func discover() {
        Task {
            do {
                for try await discovered in await discovery.cameras() {
                    guard !cameras.contains(where: { $0.descriptor.id == discovered.descriptor.id }) else { continue }
                    cameras.append(discovered)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func connect(_ discovered: DiscoveredCamera) {
        Task {
            do {
                try await discovered.camera.connect()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setExposure(on camera: any Camera, aperture: Double, shutterDenominator: Int, iso: Int) {
        Task {
            do {
                try await camera.set(.init(
                    aperture: aperture,
                    shutterSpeed: .fraction(shutterDenominator),
                    iso: iso
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startLiveView(on camera: any Camera) {
        liveViewTask?.cancel()
        liveViewTask = Task {
            do {
                for try await frame in try await camera.startLiveView() {
                    guard !Task.isCancelled else { break }
                    liveViewJPEG = frame.jpegData
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func capture(on camera: any Camera) {
        Task {
            do {
                lastPhoto = try await camera.capturePhoto(download: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func disconnect(_ camera: any Camera) {
        liveViewTask?.cancel()
        liveViewTask = nil
        Task { await camera.disconnect() }
    }
}

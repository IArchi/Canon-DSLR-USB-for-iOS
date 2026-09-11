import DSLRKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = CameraViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    cameraCard
                    imageCard(title: "Live view", image: model.liveViewImage)
                    controls
                    imageCard(title: "Latest photo", image: model.capturedImage)
                }
                .padding()
            }
            .navigationTitle("DSLRKit Demo")
            .task { model.start() }
        }
    }

    private var statusCard: some View {
        GroupBox("Status") {
            HStack {
                Circle()
                    .fill(model.isConnected ? .green : .orange)
                    .frame(width: 12, height: 12)
                Text(model.status)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var cameraCard: some View {
        GroupBox("Camera") {
            if let camera = model.descriptor {
                VStack(alignment: .leading, spacing: 8) {
                    row("Model", camera.model)
                    row("Manufacturer", camera.manufacturer.rawValue.capitalized)
                    row("Transport", camera.transport.rawValue.uppercased())
                    row("USB", usbIdentifier(camera))
                    row("Battery", model.state?.batteryPercent.map { "\($0) %" } ?? "Unknown")
                    row("Capabilities", model.capabilities.map(\.rawValue).sorted().joined(separator: ", "))
                }
            } else {
                Text("Connect and turn on a camera set to PTP mode.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(model.isLiveViewActive ? "Stop live view" : "Start live view") {
                model.toggleLiveView()
            }
            .buttonStyle(.bordered)
            .disabled(!model.isConnected || !model.capabilities.contains(.liveView))

            Button("Capture") { model.capture() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected || !model.capabilities.contains(.capturePhoto) || model.isBusy)

            Button("Refresh") { model.refresh() }
                .buttonStyle(.bordered)
                .disabled(!model.isConnected)
        }
    }

    private func imageCard(title: String, image: UIImage?) -> some View {
        GroupBox(title) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera").font(.largeTitle)
                    Text("No image")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func usbIdentifier(_ camera: CameraDescriptor) -> String {
        guard let vendor = camera.usbVendorID, let product = camera.usbProductID else { return "—" }
        return String(format: "%04X:%04X", vendor, product)
    }
}

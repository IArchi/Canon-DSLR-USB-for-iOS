# iOS example

1. Add `DSLRKit-iOS` as a local or Git Swift Package dependency in Xcode.
2. Add the following entry to the app's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Connect to and control your USB camera.</string>
```

3. Copy `CameraController.swift` into the app.
4. Connect the DSLR to the iPhone or iPad, using a powered USB adapter if necessary.

Minimal usage:

```swift
let controller = CameraController()
controller.discover()

// After a camera appears in controller.cameras:
let found = controller.cameras[0]
controller.connect(found)
controller.setExposure(on: found.camera, aperture: 8, shutterDenominator: 125, iso: 200)
controller.startLiveView(on: found.camera)
controller.capture(on: found.camera)
```

To display live view in SwiftUI:

```swift
if let data = controller.liveViewJPEG, let image = UIImage(data: data) {
    Image(uiImage: image).resizable().scaledToFit()
}
```

Available commands vary by camera. Check `try await camera.capabilities()` and handle `CameraError.unsupported`.

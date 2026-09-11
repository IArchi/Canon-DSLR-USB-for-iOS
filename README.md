# DSLRKit

Common Swift `async/await` API for PTP cameras (Canon, Nikon, Sony, and others) providing:

- connection and capability discovery;
- status, exposure, and focus settings;
- photo capture and retrieval;
- JPEG live view through `AsyncThrowingStream`;
- simulation without a camera.

Successfully tested on Canon EOS 2000D.

## Installation

In Xcode, select **File > Add Package Dependencies**, then enter the Git URL of this directory.
Add the `DSLRKit` product to the iOS target. A complete integration example is available in
[`Examples/`](Examples/).

```swift
let camera: any Camera = SimulatedCamera()
try await camera.connect()
try await camera.set(.init(aperture: 8, shutterSpeed: .fraction(125), iso: 200))

for try await frame in try await camera.startLiveView() {
    // UIImage(data: frame.jpegData)
}
```

## USB connection on iPhone and iPad

The gphoto2 command-line client depends on the separate libgphoto2 library. A direct port of the
client would therefore provide no drivers, and using `libusb` in a regular iOS app is not a public
path supported by Apple.

DSLRKit instead uses Apple's public USB/PTP transport, `ImageCaptureCore` (iOS 13+).
It supports discovery, session opening, PTP commands, and PTP events on iPhone and iPad.
The following entry is required in the app's `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Connect to and control your USB camera.</string>
```

```swift
let discovery = await ImageCaptureCameraDiscovery()

for try await found in await discovery.cameras() {
    try await found.camera.connect()
}
```

`ImageCaptureCameraDiscovery` requests iOS control permission, keeps only USB cameras, identifies
Canon (`04a9`), Nikon (`04b0`), and Sony (`054c`), then creates a `VendorCamera`.
`ImageCapturePTPTransport` encodes PTP containers in little-endian format, transfers data, and
exposes events as an `AsyncStream`.

Profiles are selected automatically through `GPhotoProfileFactory`:

- Canon EOS: remote mode, capture, ISO/aperture/shutter speed, and EOS live view;
- modern Nikon: `0x9207` capture, download through the ObjectAdded event, standard PTP properties,
  and Nikon live view;
- Sony Alpha: half-press/full-press sequence, RAM download, standard PTP properties, and a synthetic
  live-view object;
- unknown manufacturer: `GenericPTPProfile`, without risky proprietary commands.

These sequences are derived from `libgphoto2/camlibs/ptp2`. The essential Canon tables were ported
with selection of the nearest supported value. Some older or unusual families use different
operations and require a dedicated VID/PID profile.

## Manufacturer profiles

PTP standardizes transport, but not live view or most DSLR settings. These commands are extensions
that differ by manufacturer and sometimes by camera family. The `PTPCameraProfile` interface
isolates this behavior: status, settings, capture, and starting or stopping live view.
`GenericPTPProfile` is the safe fallback for any discovered camera. It supports connection but
explicitly returns `CameraError.unsupported` for operations that are not implemented.

The sequences were derived from the **LGPL** `gphoto/libgphoto2` repository, particularly
`camlibs/ptp2`. No C or libusb code is included or linked into the app. The sequences still need to
be calibrated on the targeted physical cameras.

### iOS constraints

- For local Wi-Fi, the host app must provide the usage descriptions and Bonjour declarations
  required by iOS.
- `USBDriverKit` does not replace this transport on every device: Apple limits it to M-series iPads,
  and distribution requires the appropriate DriverKit entitlements. `ImageCaptureCore` remains the
  common public PTP path for iPhone and iPad.
- Communication is suspended when the iOS app enters the background.
- Support for “all cameras” cannot be absolute: only PTP cameras and extensions that are actually
  described and tested by a profile can expose live view, capture, and settings.

## Verification

```sh
swift test
```

The code is also checked directly against the iPhoneOS SDK using Swift 6:

```sh
swiftc -typecheck -swift-version 6 -parse-as-library \
  -target arm64-apple-ios15.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  Sources/DSLRKit/*.swift
```

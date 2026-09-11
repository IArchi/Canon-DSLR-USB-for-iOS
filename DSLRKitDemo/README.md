# DSLRKitDemo

A minimal SwiftUI app for testing DSLRKit on a physical iPhone or iPad.

## Run

1. Open `DSLRKitDemo.xcodeproj` in Xcode.
2. Select the `DSLRKitDemo` target, open **Signing & Capabilities**, and choose your team.
3. Select the iPhone as the destination and run the app.
4. Allow the app to control the camera.
5. Connect the DSLR via USB, turn it on, and select its PTP/remote control mode.

The app displays the model, manufacturer, USB identifiers, battery level, capabilities,
live view, and the latest downloaded photo.

A powered USB hub or adapter may be required if the camera draws too much power.

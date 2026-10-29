import SwiftUI
import WatchKit

/// The system volume slider for the Watch's own audio output. While it is on screen the Digital Crown
/// changes the volume (the control takes crown focus), so our controls page behaves like Now Playing.
struct VolumeControl: WKInterfaceObjectRepresentable {
    var tint: UIColor = .green

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(tint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { control.focus() }
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.setTintColor(tint)
    }
}

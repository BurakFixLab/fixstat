import Foundation
import MacSensors

public enum HardwareText {
    public static func title(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard: L("Keyboard")
        case .trackpad: L("Trackpad")
        case .display: L("Display")
        case .ambientLight: L("Ambient light sensor")
        case .speakers: L("Speakers")
        case .microphone: L("Microphone")
        case .camera: L("Camera")
        case .wifi: L("Wi-Fi")
        case .bluetooth: L("Bluetooth")
        case .ports: L("Ports")
        case .lid: L("Lid sensor")
        }
    }

    public static func symbol(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .display: "display"
        case .ambientLight: "sun.max"
        case .speakers: "speaker.wave.2"
        case .microphone: "mic"
        case .camera: "camera"
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .ports: "cable.connector"
        case .lid: "laptopcomputer"
        }
    }

    public static func instructions(_ item: HardwareCheck.Item) -> String {
        switch item {
        case .keyboard:
            L("Press every key. A key turns blue once it registers; a key that stays grey did not respond. Hold fn for the top row, otherwise macOS uses those keys itself. Touch ID / power cannot be tested here.")
        case .trackpad:
            L("Run a finger over the whole trackpad surface; the pointer can be anywhere. Cells that stay empty did not register touches. Then click once in each of the nine zones and secondary-click (two fingers) in each zone, keeping the pointer in this window. Also force click, scroll and pinch.")
        case .display:
            L("Shows solid colours full screen on the built-in display to spot dead or stuck pixels, lines, stains and backlight bleed. Click or press → for the next colour, ← to go back, esc to end.")
        case .ambientLight:
            L("Checks the ambient light sensor next to the camera in three steps: normal light, covered with a finger, and a flashlight on it. The camera confirms that the light really reached the sensor, so a missing flashlight is not taken for a broken sensor.")
        case .speakers:
            L("Plays test tones on the left and right speaker. The sweep runs from low to high frequencies and reveals rattling or distorted speakers.")
        case .microphone:
            L("Speak or tap near the microphones and watch the level. Record a few seconds and play them back to judge the sound.")
        case .camera:
            L("Shows the built-in camera image. Check sharpness, colours and that the green camera light turns on.")
        case .wifi:
            L("Shows the Wi-Fi link and scans for nearby networks. A weak signal next to the router or few networks can point to an antenna or cable problem.")
        case .bluetooth:
            L("Shows the Bluetooth controller and scans for nearby devices for ten seconds. Finding no devices in a busy room points to an antenna problem.")
        case .ports:
            L("Plug a USB device, a charger or a display into each port in turn. Every port should show a data connection; charging ports should show power in.")
        case .lid:
            L("Close the lid until the Mac sleeps, then open it again. FixStat detects the closing through the lid (Hall) sensor.")
        }
    }

    public static func status(_ status: HardwareCheck.Status) -> String {
        switch status {
        case .untested: L("Not tested")
        case .passed: L("Passed")
        case .failed: L("Failed")
        case .skipped: L("Skipped")
        }
    }
}

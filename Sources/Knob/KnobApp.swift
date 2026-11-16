import AppKit
import SwiftUI

enum Knob {
    /// Bundle identifier; also the unified-logging subsystem.
    static let id = "io.github.uphillbill.knob"
}

@main
struct KnobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(audio: appDelegate.audio)
        } label: {
            Image(systemName: "speaker.wave.2.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Knob EQ", id: "eq") {
            EQWindow(audio: appDelegate.audio, model: appDelegate.eqWindow)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let audio = AudioController()
    let eqWindow = EQWindowModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        audio.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audio.shutdown()
    }
}

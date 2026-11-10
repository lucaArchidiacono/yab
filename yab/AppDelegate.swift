import AVFoundation
import UIKit
import os

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "AppDelegate")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Sound from web pages is media, as in Safari: it plays with the ringer on silent,
        // and goes on in the background and with the phone locked.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            Self.logger.error("Could not set up audio: \(error, privacy: .public)")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

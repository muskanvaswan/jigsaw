import CloudKit
import Observation
import UIKit

/// Routes iCloud share invitations into the app, whether it was already running or opened by the link.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata { Invitations.shared.received(metadata) }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Invitations.shared.received(metadata)
    }
}

/// Share invitations waiting to be opened.
@Observable
final class Invitations {
    static let shared = Invitations()

    var pending: [CKShare.Metadata] = []

    func received(_ metadata: CKShare.Metadata) {
        DispatchQueue.main.async { self.pending.append(metadata) }
    }
}

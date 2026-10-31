import CloudKit
import UIKit

/// Apple's screen for inviting people to a puzzle, choosing what they can do, and managing who's in.
@MainActor
enum Sharing {
    /// UICloudSharingController holds its delegate weakly.
    private static var delegate: Delegate?

    static func present(_ share: CKShare, container: CKContainer, thumbnail: UIImage?) {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        let delegate = Delegate(thumbnail: thumbnail?.jpegData(compressionQuality: 0.7))
        Self.delegate = delegate
        controller.delegate = delegate
        controller.modalPresentationStyle = .formSheet
        topViewController()?.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Delegate: NSObject, UICloudSharingControllerDelegate {
        let thumbnail: Data?

        init(thumbnail: Data?) { self.thumbnail = thumbnail }

        func itemTitle(for csc: UICloudSharingController) -> String? { "Jigsaw puzzle" }

        func itemThumbnailData(for csc: UICloudSharingController) -> Data? { thumbnail }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
    }
}

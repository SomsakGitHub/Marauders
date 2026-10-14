import UIKit
import MyLibrarySDKCore

@MainActor
public enum MyLibrarySDKFeature {
    public static func startFlow(
        data: MyLibraryFlowData,
        from viewController: UIViewController? = nil,
        onClose: ((String?) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard MyLibrarySDKCore.isConfigured else {
            assertionFailure("Call MyLibrarySDKCore.initialize(app:) before MyLibrarySDKFeature.startFlow")
            return
        }

        let screen = MyLibraryViewController(data: data, onClose: onClose)
        let source = viewController ?? UIApplication.myLibraryTopViewController()
        guard let source else { return }

        source.present(screen, animated: true, completion: completion)
    }
}

private extension UIApplication {
    static func myLibraryTopViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    ) -> UIViewController? {
        if let nav = base as? UINavigationController {
            return myLibraryTopViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return myLibraryTopViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return myLibraryTopViewController(base: presented)
        }
        return base
    }
}

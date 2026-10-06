import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension PebbleService: ServiceUI {
    static var image: UIImage? {
        UIImage(systemName: "applewatch.side.right")
    }

    static func setupViewController(
        colorPalette _: LoopUIColorPalette,
        pluginHost: PluginHost
    ) -> SetupUIResult<ServiceViewController, ServiceUI> {
        let service = PebbleService(hostIdentifier: pluginHost.hostIdentifier, hostVersion: pluginHost.hostVersion)
        let nav = ServiceNavigationController()
        let host = UIHostingController(
            rootView: PebbleServiceFormView(
                service: service,
                mode: .create,
                dismiss: { [weak nav] in
                    nav?.notifyComplete()
                },
                onCreateFinished: { [weak nav] in
                    guard let nav else { return }
                    nav.notifyServiceCreatedAndOnboarded(service as ServiceUI)
                }
            )
        )
        nav.setViewControllers([host], animated: false)
        return .userInteractionRequired(nav)
    }

    func settingsViewController(colorPalette _: LoopUIColorPalette) -> ServiceViewController {
        let nav = ServiceNavigationController()
        let host = UIHostingController(
            rootView: PebbleServiceFormView(
                service: self,
                mode: .settings,
                dismiss: { [weak nav] in
                    nav?.notifyComplete()
                },
                onCreateFinished: nil
            )
        )
        nav.setViewControllers([host], animated: false)
        return nav
    }
}

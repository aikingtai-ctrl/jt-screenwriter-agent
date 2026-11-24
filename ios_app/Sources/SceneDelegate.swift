import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let win = UIWindow(windowScene: windowScene)
        win.overrideUserInterfaceStyle = .light
        win.backgroundColor = .white
        win.rootViewController = WorkbenchViewController()
        self.window = win
        win.makeKeyAndVisible()
    }
}

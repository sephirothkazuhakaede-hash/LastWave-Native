import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import SwiftUI
import UIKit

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var user: FirebaseAuth.User?
    @Published var working = false
    @Published var error: String?
    private var listener: AuthStateDidChangeListenerHandle?

    init() {
        user = Auth.auth().currentUser
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.user = user }
        }
    }

    deinit {
        if let listener { Auth.auth().removeStateDidChangeListener(listener) }
    }

    func signInWithGoogle() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw AuthError.configuration
            }
            guard let presenter = UIApplication.shared.capyflowPresentingViewController else {
                throw AuthError.presenter
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.missingToken
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            let signInError = error as NSError
            if signInError.domain != kGIDSignInErrorDomain || signInError.code != -5 {
                self.error = error.localizedDescription
            }
        }
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum AuthError: LocalizedError {
    case configuration, presenter, missingToken
    var errorDescription: String? {
        switch self {
        case .configuration: "Google sign-in is not configured for this build."
        case .presenter: "CapyFlow could not open the Google sign-in window."
        case .missingToken: "Google did not return a valid sign-in token."
        }
    }
}

private extension UIApplication {
    var capyflowPresentingViewController: UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        return root?.capyflowTopViewController
    }
}

private extension UIViewController {
    var capyflowTopViewController: UIViewController {
        if let presentedViewController { return presentedViewController.capyflowTopViewController }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.capyflowTopViewController ?? navigation
        }
        if let tabs = self as? UITabBarController {
            return tabs.selectedViewController?.capyflowTopViewController ?? tabs
        }
        return self
    }
}

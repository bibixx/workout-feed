import SwiftUI
import SafariServices

/// Outbound links, one place.
enum AppLinks {
    static let feedSetupDocs = URL(string: "https://bibixx.github.io/workout-feed/")!
}

/// In-app browser for docs — present in a sheet with `.ignoresSafeArea()`.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

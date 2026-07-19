import Foundation

/// Public product destinations shared by every macOS surface.
///
/// Keep these in one place so Settings, menus, and future onboarding links
/// cannot drift to different repositories or support addresses.
enum VeloraLinks {
    static let supportEmailAddress = "sushilk.1991@gmail.com"

    static var websiteURL: URL? {
        URL(string: "https://sushilk1991.github.io/velora/")
    }

    static var repositoryURL: URL? {
        URL(string: "https://github.com/\(UpdateChecker.repoSlug)")
    }

    /// GitHub does not expose a safe unauthenticated one-click-star URL. The
    /// repository page is the honest destination because its Star control is
    /// visible there and GitHub can handle sign-in when required.
    static var starURL: URL? {
        repositoryURL
    }

    static var issuesURL: URL? {
        URL(string: "https://github.com/\(UpdateChecker.repoSlug)/issues")
    }

    static var supportEmailURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress
        components.queryItems = [URLQueryItem(name: "subject", value: "Velora Support")]
        return components.url
    }
}

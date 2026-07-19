import Foundation

enum VeloraMobileLinks {
    static let supportEmailAddress = "sushilk.1991@gmail.com"

    static var website: URL? {
        URL(string: "https://sushilk1991.github.io/velora/")
    }

    static var repository: URL? {
        URL(string: "https://github.com/sushilk1991/velora")
    }

    static var star: URL? {
        repository
    }

    static var actionButtonGuide: URL? {
        URL(string: "https://support.apple.com/guide/shortcuts/apdfea15680b/ios")
    }

    static var supportEmail: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmailAddress
        components.queryItems = [URLQueryItem(name: "subject", value: "Velora for iPhone Support")]
        return components.url
    }
}

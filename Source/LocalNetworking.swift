import Foundation

private final class LocalRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum LocalNetwork {
    private static let blocker = LocalRedirectBlocker()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
    }()
}

import Foundation
@main struct LocalNetworkTest {
    static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data("synthetic document".utf8)
        let (_, response) = try await LocalNetwork.session.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 307)
        precondition(response.url == url)
        print("PASS local assistant blocks document-body redirects")
    }
}

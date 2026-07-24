import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

fileprivate let baseURL = URL(string: "https://api.openai.com/v1/realtime/calls")!

package extension URLRequest {
	static func webRTCConnectionRequest(ephemeralKey: String, model: Model? = nil) -> URLRequest {
		var url = baseURL
		if let model {
			url = url.appending(queryItems: [
				URLQueryItem(name: "model", value: model.rawValue),
			])
		}
		var request = URLRequest(url: url)

		request.httpMethod = "POST"
		request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")

		return request
	}
}

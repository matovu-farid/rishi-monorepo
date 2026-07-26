import Foundation

internal extension Result {
	init(catching body: () async throws(Failure) -> Success) async {
		do { self = try .success(await body()) }
		catch { self = .failure(error) }
	}
}

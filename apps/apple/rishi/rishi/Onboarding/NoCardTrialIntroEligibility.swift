enum NoCardTrialIntroEligibility {
    static func shouldPresent(for refreshResult: Result<EntitlementSnapshot, Error>?) -> Bool {
        guard case .success(let snapshot) = refreshResult else { return true }
        return !snapshot.isPaidActive
    }
}

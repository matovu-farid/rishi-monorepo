/// Bridges the server-backed `EntitlementService` stream into the
/// `EntitlementReconciler`'s server signal. Without this, `reconciler.level`
/// only reflects on-device StoreKit (flag-gated) and ignores the worker's
/// has_pro / trial state. Runs for the app's lifetime.
public enum EntitlementServerBridge {
    @MainActor
    public static func run(
        levels: AsyncStream<EntitlementLevel>,
        into reconciler: EntitlementReconciler
    ) async {
        for await level in levels {
            reconciler.setServer(level)
        }
    }
}

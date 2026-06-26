













enum FeatureFlags {
    
    
    static var readAloud: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

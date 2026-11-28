import Foundation

extension WindowLibrary {
    /// setFlaggedLayout sets the app-wide flagged layout on the library and every open store.
    public func setFlaggedLayout(_ layout: FlaggedViewLayout) {
        flaggedLayout = layout
        for store in stores.values { store.flaggedLayout = layout }
    }
}

extension AppStore {
    /// useFlaggedLayout mirrors the app-wide layout on a store no `WindowLibrary` owns, as agterm-win's are.
    public func useFlaggedLayout(_ layout: FlaggedViewLayout) {
        flaggedLayout = layout
    }
}

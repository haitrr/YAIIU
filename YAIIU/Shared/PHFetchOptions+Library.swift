import Photos

extension PHFetchOptions {
    /// Fetch options used for every library scan and identifier lookup.
    ///
    /// PhotoKit returns only the representative ("cover") photo of each burst
    /// stack unless `includeAllBurstAssets` is set, so the remaining frames
    /// would never be listed, hashed or uploaded. Identifier lookups must use
    /// the same options or a burst frame tracked elsewhere resolves to nothing.
    static func library(includeHidden: Bool) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = includeHidden
        options.includeAllBurstAssets = true
        return options
    }
}

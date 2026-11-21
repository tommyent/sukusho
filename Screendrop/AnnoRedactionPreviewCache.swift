import CoreGraphics

/// Owned by one canvas. Only the preview may reuse redactions: export samples
/// the composed context, which can include earlier overlapping redactions.
nonisolated final class AnnoRedactionPreviewCache {
    static let defaultByteLimit = 32 * 1024 * 1024

    private let cache: BoundedCGImageCache
    /// Target memory budget for a single cached preview tile so oversized
    /// regions (e.g. a full-screen blur on a 5K screenshot) are downsampled
    /// before filtering and fit inside the cache instead of missing every frame.
    let maxTileBytes: Int
    private var lease: BoundedCGImageCache.Lease?
    private var source: CGImage?

    init(byteLimit: Int = defaultByteLimit) {
        self.cache = BoundedCGImageCache(byteLimit: byteLimit, countLimit: 32)
        self.maxTileBytes = max(1, byteLimit / 2)
    }

    /// Cache entries are keyed in source pixels, so frame-only viewport moves
    /// and animations reuse them; only replacing or clearing the source image
    /// invalidates the cache.
    func configure(source: CGImage?) {
        if self.source !== source {
            cache.removeAll()
        }
        self.source = source
        if source != nil, lease == nil { lease = cache.beginUse() }
        if source == nil { releaseResources() }
    }

    func releaseResources() {
        source = nil
        lease = nil
        cache.removeAll()
    }

    func image(kind: String, density: Double, bounds: CGRect, render: () -> CGImage?) -> CGImage? {
        let key = "\(kind):\(density):\(bounds.origin.x):\(bounds.origin.y):\(bounds.width):\(bounds.height)"
        if let image = cache.image(for: key) { return image }
        let generation = cache.generation
        guard let image = render() else { return nil }
        cache.insert(image, for: key, generation: generation)
        return image
    }
}

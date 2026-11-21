import CoreGraphics

/// Owned by one canvas. Only the preview may reuse redactions: export samples
/// the composed context, which can include earlier overlapping redactions.
nonisolated final class AnnoRedactionPreviewCache {
    private let cache = BoundedCGImageCache(byteLimit: 32 * 1024 * 1024, countLimit: 32)
    private var lease: BoundedCGImageCache.Lease?
    private var source: CGImage?

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

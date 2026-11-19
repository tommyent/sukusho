// For a before/after comparison, copy this file into Screendrop/ in each disposable
// checkout and build Debug Dev. Launch each with -libraryScrollBenchmark /path/to/new.csv
// and the same isolated Library of exactly 500 grid cards at the same width.
// The idle rows measure the guest display cadence. Pass 0 warms thumbnails; passes 1–3
// traverse the same range. Intervals measure main-thread display callbacks, not GPU completion.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

static NSCollectionView *findGrid(NSView *view) {
    if ([view isKindOfClass:NSCollectionView.class] && !view.isHiddenOrHasHiddenAncestor) {
        NSCollectionView *grid = (NSCollectionView *)view;
        NSInteger count = 0;
        for (NSInteger s = 0; s < grid.numberOfSections; s++) count += [grid numberOfItemsInSection:s];
        if (count == 500 && grid.enclosingScrollView) return grid;
    }
    for (NSView *child in view.subviews) {
        NSCollectionView *grid = findGrid(child);
        if (grid) return grid;
    }
    return nil;
}

@interface LibraryScrollProbe : NSObject
@end

@implementation LibraryScrollProbe {
    NSScrollView *_scroll;
    CADisplayLink *_link;
    NSString *_output;
    NSMutableString *_rows;
    double _phaseStart, _previous;
    NSInteger _pass;
    CGFloat _distance;
}

- (void)start:(NSString *)output attempts:(NSInteger)left {
    NSCollectionView *grid = findGrid(NSApp.keyWindow.contentView);
    if (!grid || grid.enclosingScrollView.documentView.bounds.size.height <= grid.visibleRect.size.height) {
        if (left > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                [self start:output attempts:left - 1];
            });
        } else {
            [@"No scrollable 500-card collection in the key window\n" writeToFile:output
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
        return;
    }
    _scroll = grid.enclosingScrollView;
    _distance = _scroll.documentView.bounds.size.height - _scroll.contentView.bounds.size.height;
    _output = output;
    _rows = [NSMutableString stringWithString:@"pass,elapsed_s,interval_ms,scroll_y\n"];
    _pass = -1;
    _link = [grid displayLinkWithTarget:self selector:@selector(frame:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)frame:(CADisplayLink *)link {
    double now = CACurrentMediaTime();
    if (!_phaseStart) { _phaseStart = _previous = now; return; }
    double elapsed = now - _phaseStart;
    double duration = _pass < 0 ? 2.0 : 12.0;
    if (_pass >= 0) {
        double fraction = MIN(1.0, elapsed / duration);
        if (_pass % 2) fraction = 1.0 - fraction;
        NSPoint point = _scroll.contentView.bounds.origin;
        point.y = round(_distance * fraction);
        [_scroll.contentView scrollToPoint:point];
        [_scroll reflectScrolledClipView:_scroll.contentView];
    }
    [_rows appendFormat:@"%ld,%.6f,%.4f,%.0f\n", (long)_pass, elapsed, 1000*(now - _previous), _scroll.contentView.bounds.origin.y];
    _previous = now;
    if (elapsed < duration) return;
    _phaseStart = now;
    if (++_pass <= 3) return;
    [link invalidate];
    _link = nil;
    [_rows writeToFile:_output atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
@end

__attribute__((constructor)) static void prepareLibraryScrollProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *output = [NSUserDefaults.standardUserDefaults stringForKey:@"libraryScrollBenchmark"];
        if (output.length) [[[LibraryScrollProbe alloc] init] start:output attempts:60];
    });
}

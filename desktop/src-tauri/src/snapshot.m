#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

// Called on the webview's main thread by the opt-in synthetic UI probe.
// WKWebView snapshots only its own content; no desktop capture is requested.
void manasprites_snapshot(void *raw, const char *destination) {
    WKWebView *webview = (__bridge WKWebView *)raw;
    NSString *path = [NSString stringWithUTF8String:destination];
    [webview takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
        if (!image || error) return;
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:path options:NSDataWritingAtomic error:NULL];
    }];
}

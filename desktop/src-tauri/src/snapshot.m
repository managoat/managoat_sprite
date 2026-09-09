#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <stdbool.h>

// The Rust command validates the card URL before calling this native writer.
bool manasprites_copy_card_url(const char *value) {
    @autoreleasepool {
        NSString *text = [NSString stringWithUTF8String:value];
        if (!text) return false;
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        return [pasteboard setString:text forType:NSPasteboardTypeString];
    }
}

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

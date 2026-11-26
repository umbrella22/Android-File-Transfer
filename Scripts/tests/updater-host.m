// Test-only application. Exercise a normal in-process Sparkle update without GUI automation.
#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

@interface SmokeDriver : NSObject <SPUUserDriver>
@end
@implementation SmokeDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancel {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"No update: %@", error); exit(2); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { NSLog(@"Update failed: %@", error); exit(3); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { ack(); }
- (void)dismissUpdateInstallation {}
@end

int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        if ([[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"2"]) {
            NSURL *receipt = [[bundle.bundleURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"relaunched"];
            return [@"2" writeToURL:receipt atomically:YES encoding:NSUTF8StringEncoding error:NULL] ? 0 : 4;
        }
        [NSApplication sharedApplication];
        static SPUUpdater *updater;
        static SmokeDriver *driver;
        driver = [SmokeDriver new];
        updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:nil];
        NSError *error = nil;
        if (![updater startUpdater:&error]) { NSLog(@"%@", error); return 1; }
        dispatch_async(dispatch_get_main_queue(), ^{ [updater checkForUpdates]; });
        [NSApp run];
    }
    return 0;
}

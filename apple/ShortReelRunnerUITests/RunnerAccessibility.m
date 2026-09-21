#import "RunnerAccessibility.h"
#import <objc/message.h>

static id ReadObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

NSString *SRApplicationBundleID(XCUIApplication *app) {
    id value = ReadObject(app, @"bundleID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

XCUIApplication *SRForegroundApplication(void) {
    @try {
        id client = ReadObject(XCUIDevice.sharedDevice, @"accessibilityInterface");
        NSArray *elements = ReadObject(client, @"activeApplications");
        id tracker = ReadObject(client, @"applicationProcessTracker");
        SEL lookup = NSSelectorFromString(@"monitoredApplicationWithProcessIdentifier:");
        SEL process = NSSelectorFromString(@"processIdentifier");
        if (![elements isKindOfClass:NSArray.class] || ![tracker respondsToSelector:lookup]) return nil;
        XCUIApplication *systemApp = nil;
        for (id element in elements) {
            if (![element respondsToSelector:process]) continue;
            int pid = ((int (*)(id, SEL))objc_msgSend)(element, process);
            XCUIApplication *app = ((id (*)(id, SEL, int))objc_msgSend)(tracker, lookup, pid);
            if (![app isKindOfClass:XCUIApplication.class] || app.state != XCUIApplicationStateRunningForeground) continue;
            if ([SRApplicationBundleID(app) isEqualToString:@"com.apple.springboard"]) systemApp = app;
            else return app;
        }
        return systemApp;
    } @catch (NSException *exception) {
        return nil;
    }
}

#import <XCTest/XCTest.h>

NS_ASSUME_NONNULL_BEGIN
// XCTest's active-process query is private; keep it isolated and fail closed
// when an SDK changes it, rather than directing input at the runner host.
XCUIApplication * _Nullable SRForegroundApplication(void);
NSString * _Nullable SRApplicationBundleID(XCUIApplication *app);
NS_ASSUME_NONNULL_END

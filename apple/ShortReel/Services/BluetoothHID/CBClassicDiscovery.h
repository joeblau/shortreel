#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CBClassicDiscovery : NSObject
@property (nonatomic, copy, nullable) void (^onDeviceFound)(NSString *address, NSString *name);
@property (nonatomic, copy, nullable) void (^onFinished)(void);
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
- (void)start;
- (void)stop;
@end
NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface HIDControlSession : NSObject
@property (nonatomic, readonly) BOOL suspended;
@property (nonatomic, readonly) BOOL unplugged;
- (nullable NSData *)responseToPacket:(NSData *)packet;
- (void)recordInput:(NSData *)packet;
@end
NS_ASSUME_NONNULL_END

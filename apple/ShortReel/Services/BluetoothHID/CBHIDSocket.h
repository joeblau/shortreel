#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The classic CoreBluetooth socket is a stream; each outgoing HID transaction
/// needs the ancillary packet boundary used by the Bluetooth socket transport.
@interface CBHIDSocket : NSObject
- (nullable instancetype)initWithFileDescriptor:(int)descriptor
                                 callbackQueue:(dispatch_queue_t)callbackQueue
                                      onPacket:(void (^)(NSData *packet))onPacket
                                       onClose:(void (^)(NSError * _Nullable error))onClose
                                         error:(NSError **)error;
- (BOOL)writePacket:(NSData *)packet maximumSize:(NSUInteger)maximumSize error:(NSError **)error;
- (void)close;
@end

NS_ASSUME_NONNULL_END

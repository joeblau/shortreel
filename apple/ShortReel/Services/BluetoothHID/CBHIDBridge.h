#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CBHIDPeerState : NSObject
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL hasControlChannel;
@property (nonatomic) BOOL hasInterruptChannel;
@end

@interface CBHIDBridge : NSObject

@property (nonatomic, copy, nullable) void (^onPeerChannelsChanged)(CBHIDPeerState *peer);

@property (nonatomic, copy, nullable) void (^onPeerDisconnected)(NSString *address);

@property (nonatomic, copy, nullable) void (^onConnectionFailed)(NSString *address, NSError *error);

@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

- (BOOL)startWithServiceName:(NSString *)serviceName
               serviceRecord:(NSData *)sdpRecord
                       error:(NSError **)error;
- (void)stop;
- (void)disconnectPeerWithAddress:(NSString *)address;

- (void)requestConnectionToPeerWithAddress:(NSString *)address NS_SWIFT_NAME(requestConnection(address:));
- (void)cancelConnectionRequestWithAddress:(NSString *)address NS_SWIFT_NAME(cancelConnectionRequest(address:));

- (BOOL)sendReport:(NSData *)report toPeerWithAddress:(NSString *)address error:(NSError **)error;

- (NSArray<NSString *> *)connectedPeerAddresses;

@end

NS_ASSUME_NONNULL_END

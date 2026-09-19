#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift-facing snapshot of one classic peer's HID channel state.
@interface CBHIDPeerState : NSObject
@property (nonatomic, copy) NSString *address;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL hasControlChannel;
@property (nonatomic) BOOL hasInterruptChannel;
@end

/// Thin bridge over CoreBluetooth's private CBClassicManager. All private API
/// is reached through runtime lookups so nothing private needs to be linked or
/// declared in a way the linker can see. Mirrors TapKit's HIDKit HostManager:
/// publishes an HID SDP record and accepts L2CAP PSM 0x11 / 0x13 channels.
@interface CBHIDBridge : NSObject

/// Fired (on an internal queue) when a peer opens or closes one of the HID
/// L2CAP channels, with the peer's full channel state.
@property (nonatomic, copy, nullable) void (^onPeerChannelsChanged)(CBHIDPeerState *peer);

/// Fired when a peer drops its ACL connection.
@property (nonatomic, copy, nullable) void (^onPeerDisconnected)(NSString *address);

/// Fired when an explicitly requested reconnect fails. Incoming connections
/// continue to use the ordinary channel callbacks.
@property (nonatomic, copy, nullable) void (^onConnectionFailed)(NSString *address, NSError *error);

/// Fired with diagnostic log lines.
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

/// Publishes the HID SDP record, turns discoverable/connectable on, and starts
/// listening for incoming HID channels. `serviceName` is what the iPhone shows
/// in its Bluetooth device list.
- (BOOL)startWithServiceName:(NSString *)serviceName
               serviceRecord:(NSData *)sdpRecord
                       error:(NSError **)error;
- (void)stop;
- (void)disconnectPeerWithAddress:(NSString *)address;

/// Makes one reconnect attempt for this exact, already bonded address. Waits
/// for this bridge's service publication, then opens control before interrupt.
/// The caller owns the timeout and must cancel a request when it expires.
- (void)requestConnectionToPeerWithAddress:(NSString *)address NS_SWIFT_NAME(requestConnection(address:));
- (void)cancelConnectionRequestWithAddress:(NSString *)address NS_SWIFT_NAME(cancelConnectionRequest(address:));

/// Writes one HIDP DATA input report (already including the 0xA1 header and
/// report ID) on the peer's interrupt channel.
- (BOOL)sendReport:(NSData *)report toPeerWithAddress:(NSString *)address error:(NSError **)error;

/// Addresses of peers that currently have both HID channels open.
- (NSArray<NSString *> *)connectedPeerAddresses;

@end

NS_ASSUME_NONNULL_END

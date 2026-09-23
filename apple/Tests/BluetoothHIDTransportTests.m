#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <unistd.h>
#import "../ShortReel/Services/BluetoothHID/CBHIDBridge.m"

static NSData *bytes(const uint8_t *value, NSUInteger count) { return [NSData dataWithBytes:value length:count]; }
#define DATA(...) bytes((uint8_t[]){__VA_ARGS__}, sizeof((uint8_t[]){__VA_ARGS__}))
static void check(BOOL passed, NSString *reason) { if (!passed) { NSLog(@"FAIL: %@", reason); exit(1); } }

@interface FakePeer : NSObject
@property id manager;
@property int opens;
@property int closes;
@property int originalCalls;
- (void)handleL2CAPChannelOpened:(NSDictionary *)args;
- (void)handleL2CAPChannelClosed:(NSDictionary *)args;
- (id)channelWithPSM:(unsigned short)psm;
@end
@implementation FakePeer
- (void)handleL2CAPChannelOpened:(NSDictionary *)args { _opens++; }
- (void)handleL2CAPChannelClosed:(NSDictionary *)args { _closes++; }
- (id)channelWithPSM:(unsigned short)psm { return self; }
@end
@interface FakeBridge : CBHIDBridge
@property int attaches;
@end
@implementation FakeBridge
- (void)attachChannelCallbacksToPeer:(CBClassicPeer *)peer { _attaches++; }
@end
static void originalMessage(FakePeer *peer, SEL selector, int message, NSDictionary *args) { peer.originalCalls++; }

int main(void) { @autoreleasepool {
    FakeBridge *bridge = [FakeBridge new];
    FakePeer *peer = [FakePeer new]; peer.manager = [NSObject new];
    CBHIDManagers = [NSMapTable weakToWeakObjectsMapTable];
    [CBHIDManagers setObject:bridge forKey:peer.manager];
    CBHIDOriginalPeerHandleMsg = (IMP)originalMessage;
    CBHIDPeerHandleMsg((id)peer, @selector(handleMsg:args:), 27, @{@"kCBMsgArgPSM":@17});
    check(peer.opens == 1 && bridge.attaches == 1 && peer.originalCalls == 0, @"incoming HID open is routed before the peer state gate");
    CBHIDPeerHandleMsg((id)peer, @selector(handleMsg:args:), 28, @{@"kCBMsgArgPSM":@19});
    check(peer.closes == 1 && bridge.attaches == 2, @"incoming HID close reaches its callback");
    CBHIDPeerHandleMsg((id)peer, @selector(handleMsg:args:), 27, @{@"kCBMsgArgPSM":@25});
    check(peer.originalCalls == 1, @"unrelated PSM preserves original behavior");
    peer.manager = [NSObject new];
    CBHIDPeerHandleMsg((id)peer, @selector(handleMsg:args:), 27, @{@"kCBMsgArgPSM":@17});
    check(peer.originalCalls == 2, @"another manager preserves original behavior");

    HIDControlSession *control = [HIDControlSession new];
    check([[control responseToPacket:DATA(0x71)] isEqual:DATA(0)], @"report mode negotiation succeeds");
    check([[control responseToPacket:DATA(0x60)] isEqual:DATA(0xA0,1)], @"GET_PROTOCOL returns report mode");
    check([[control responseToPacket:DATA(0x70)] isEqual:DATA(3)], @"unadvertised boot mode is rejected");
    check([[control responseToPacket:DATA(0x41,2)] isEqual:DATA(0xA1,2,0,0,0,0,0,0,0,0)], @"initial pointer report contains released buttons");
    [control recordInput:DATA(0xA1,2,0,0,0,0,0xFF,0x7F,0,0)];
    check([[control responseToPacket:DATA(0x49,2,3,0)] isEqual:DATA(0xA1,2,0,0)], @"GET_REPORT honors host buffer length");
    check([[control responseToPacket:DATA(0x41,2)] isEqual:DATA(0xA1,2,0,0,0,0,0xFF,0x7F,0,0)], @"GET_REPORT returns actual latest input");
    check([[control responseToPacket:DATA(0x52,1,0x03)] isEqual:DATA(0)], @"keyboard output accepted");
    check([[control responseToPacket:DATA(0x42,1)] isEqual:DATA(0xA2,1,3)], @"keyboard output readback");
    check([[control responseToPacket:DATA(0x41,5)] isEqual:DATA(2)], @"unknown report rejected");
    check([[control responseToPacket:DATA(0x49,1)] isEqual:DATA(4)], @"truncated request rejected");
    [control responseToPacket:DATA(0x13)]; check(control.suspended, @"suspend handled");
    [control responseToPacket:DATA(0x14)]; check(!control.suspended, @"resume handled");
    [control responseToPacket:DATA(0x15)]; check(control.unplugged, @"virtual unplug handled");

    int pair[2]; check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, @"create real stream socket pair");
    dispatch_semaphore_t received = dispatch_semaphore_create(0), closed = dispatch_semaphore_create(0);
    __block NSData *readPacket;
    NSError *error = nil;
    CBHIDSocket *socket = [[CBHIDSocket alloc] initWithFileDescriptor:pair[0] callbackQueue:dispatch_get_global_queue(0,0) onPacket:^(NSData *packet) {
        readPacket = packet; dispatch_semaphore_signal(received);
    } onClose:^(NSError *failure) { dispatch_semaphore_signal(closed); } error:&error];
    check(socket != nil, error.localizedDescription ?: @"socket adapter initialized");
    close(pair[0]);
    check([socket writePacket:DATA(0xA1,2,0,0,0,0,1,0,2,0) maximumSize:64 error:&error], error.localizedDescription ?: @"socket write");
    uint8_t buffer[32]; ssize_t count = recv(pair[1],buffer,sizeof(buffer),0);
    check(count == 10 && [bytes(buffer,count) isEqual:DATA(0xA1,2,0,0,0,0,1,0,2,0)], @"complete HID report reaches peer socket");
    check(![socket writePacket:DATA(1,2,3) maximumSize:2 error:&error], @"oversized reports are rejected");
    uint8_t request[] = {0x60}; check(send(pair[1],request,1,0) == 1, @"peer sends protocol request");
    check(dispatch_semaphore_wait(received,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0 && [readPacket isEqual:DATA(0x60)], @"incoming control reaches read callback");
    close(pair[1]);
    check(dispatch_semaphore_wait(closed,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)) == 0, @"peer EOF closes adapter");
    check(![socket writePacket:DATA(1) maximumSize:64 error:&error], @"closed socket errors propagate");
    NSLog(@"PASS: incoming dispatch, HID control negotiation, real socket I/O, limits, and disconnects");
}}

#import "HIDControlSession.h"

static NSData *HIDBytes(const uint8_t *bytes, NSUInteger count) {
    return [NSData dataWithBytes:bytes length:count];
}
static NSData *HIDHandshake(uint8_t status) { return HIDBytes(&status, 1); }
@implementation HIDControlSession {
    NSMutableDictionary<NSNumber *, NSData *> *_inputReports;
    uint8_t _keyboardLEDs;
}
- (instancetype)init {
    if ((self = [super init])) {
        _inputReports = [NSMutableDictionary dictionary];
        for (uint8_t reportID = 1; reportID <= 2; reportID++) {
            uint8_t report[9] = {reportID};
            _inputReports[@(reportID)] = HIDBytes(report, sizeof(report));
        }
    }
    return self;
}
- (void)recordInput:(NSData *)packet {
    const uint8_t *bytes = packet.bytes;
    if (packet.length == 10 && bytes[0] == 0xA1 && (bytes[1] == 1 || bytes[1] == 2)) {
        _inputReports[@(bytes[1])] = [packet subdataWithRange:NSMakeRange(1, 9)];
    }
}
- (NSData *)responseToPacket:(NSData *)packet {
    if (!packet.length) return nil;
    const uint8_t *bytes = packet.bytes;
    uint8_t header = bytes[0], transaction = header >> 4, parameter = header & 0x0F;
    switch (transaction) {
        case 0: return nil; // A handshake is never itself acknowledged.
        case 1: // HID_CONTROL is not acknowledged.
            if (packet.length != 1) return nil;
            if (parameter == 3) _suspended = YES;
            if (parameter == 4) _suspended = NO;
            if (parameter == 5) _unplugged = YES;
            return nil;
        case 4: { // GET_REPORT, optionally limited by the host buffer size.
            BOOL sized = (parameter & 8) != 0;
            if ((parameter & 4) || packet.length != (sized ? 4 : 2)) return HIDHandshake(4);
            uint8_t type = parameter & 3, reportID = bytes[1];
            NSData *report;
            if (type == 1) report = _inputReports[@(reportID)];
            else if (type == 2 && reportID == 1) {
                uint8_t output[] = {1, _keyboardLEDs};
                report = HIDBytes(output, sizeof(output));
            } else if (type == 0) return HIDHandshake(4);
            if (!report) return HIDHandshake(2);
            NSUInteger length = report.length;
            if (sized) length = MIN(length, (NSUInteger)(bytes[2] | (bytes[3] << 8)));
            uint8_t responseHeader = 0xA0 | type;
            NSMutableData *response = [HIDBytes(&responseHeader, 1) mutableCopy];
            [response appendData:[report subdataWithRange:NSMakeRange(0, length)]];
            return response;
        }
        case 5: // SET_REPORT supports the keyboard LED output report.
            if (parameter != 2 || packet.length < 2) return HIDHandshake(4);
            if (bytes[1] != 1) return HIDHandshake(2);
            if (packet.length != 3) return HIDHandshake(4);
            _keyboardLEDs = bytes[2] & 0x1F;
            return HIDHandshake(0);
        case 6: { // GET_PROTOCOL: report mode.
            if (parameter || packet.length != 1) return HIDHandshake(4);
            uint8_t response[] = {0xA0, 1};
            return HIDBytes(response, sizeof(response));
        }
        case 7: // Boot mode is not advertised by the service record.
            if (packet.length != 1 || parameter > 1) return HIDHandshake(4);
            return HIDHandshake(parameter == 1 ? 0 : 3);
        case 10: // Unacknowledged keyboard output DATA.
            if (parameter == 2 && packet.length == 3 && bytes[1] == 1) _keyboardLEDs = bytes[2] & 0x1F;
            return nil;
        default: return HIDHandshake(3); // Unsupported request.
    }
}
@end

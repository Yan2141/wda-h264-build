#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IFarmH264Server : NSObject

+ (instancetype)sharedServer;

/// Khởi động TCP server phát luồng H.264 Annex-B trên cổng mặc định 9101 (qua usbmuxd).
- (BOOL)startWithPort:(uint16_t)port fps:(NSInteger)fps maxWidth:(NSInteger)maxWidth bitrateBps:(NSInteger)bitrateBps;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

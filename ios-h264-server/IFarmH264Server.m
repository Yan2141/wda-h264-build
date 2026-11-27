#import "IFarmH264Server.h"
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <dlfcn.h>
#import <unistd.h>

// Private QuartzCore symbol resolved dynamically at runtime (no private headers needed)
typedef void (*CARenderServerRenderDisplayFn)(kern_return_t, CFStringRef, IOSurfaceRef, int, int);

static const uint8_t kAnnexBStartCode[4] = { 0x00, 0x00, 0x00, 0x01 };

@interface IFarmH264Server ()
@property (nonatomic, assign) int listenFd;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *clientFds;
@property (nonatomic, strong) dispatch_queue_t netQueue;
@property (nonatomic, strong) dispatch_queue_t encodeQueue;
@property (nonatomic, strong) dispatch_source_t frameTimer;
@property (nonatomic, assign) VTCompressionSessionRef vtSession;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) NSInteger fps;
@property (nonatomic, assign) NSInteger bitrateBps;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) CARenderServerRenderDisplayFn renderDisplayFn;
@end

static void IFarmVTOutputCallback(void *outputCallbackRefCon,
                                  void *sourceFrameRefCon,
                                  OSStatus status,
                                  VTEncodeInfoFlags infoFlags,
                                  CMSampleBufferRef sampleBuffer);

@implementation IFarmH264Server

+ (instancetype)sharedServer {
  static IFarmH264Server *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[IFarmH264Server alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _listenFd = -1;
    _clientFds = [NSMutableArray array];
    _netQueue = dispatch_queue_create("com.ifarm.h264.net", DISPATCH_QUEUE_SERIAL);
    _encodeQueue = dispatch_queue_create("com.ifarm.h264.encode", DISPATCH_QUEUE_SERIAL);
    void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    if (qc) {
      _renderDisplayFn = (CARenderServerRenderDisplayFn)dlsym(qc, "CARenderServerRenderDisplay");
    }
  }
  return self;
}

- (BOOL)startWithPort:(uint16_t)port fps:(NSInteger)fps maxWidth:(NSInteger)maxWidth bitrateBps:(NSInteger)bitrateBps {
  if (self.running) return YES;
  self.fps = fps > 0 ? fps : 15;
  self.bitrateBps = bitrateBps > 0 ? bitrateBps : 1200000;

  CGRect bounds = [UIScreen mainScreen].bounds;
  CGFloat aspect = bounds.size.height / MAX(1.0, bounds.size.width);
  int targetW = (int)MIN(maxWidth > 0 ? maxWidth : 540, bounds.size.width * [UIScreen mainScreen].scale);
  targetW = (targetW / 2) * 2;
  int targetH = ((int)round(targetW * aspect) / 2) * 2;
  self.width = MAX(240, targetW);
  self.height = MAX(320, targetH);

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return NO;

  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port > 0 ? port : 9101);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // Chỉ nhận kết nối qua usbmuxd

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0) {
    close(fd);
    return NO;
  }

  self.listenFd = fd;
  self.running = YES;
  [self setupVideoToolbox];
  [self startAcceptLoop];
  [self startCaptureTimer];
  return YES;
}

- (void)setupVideoToolbox {
  if (self.vtSession) {
    VTCompressionSessionInvalidate(self.vtSession);
    CFRelease(self.vtSession);
    self.vtSession = NULL;
  }

  OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                           self.width,
                                           self.height,
                                           kCMVideoCodecType_H264,
                                           NULL,
                                           NULL,
                                           NULL,
                                           IFarmVTOutputCallback,
                                           (__bridge void *)self,
                                           &_vtSession);
  if (st != noErr || !self.vtSession) return;

  VTSessionSetProperty(self.vtSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  VTSessionSetProperty(self.vtSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
  VTSessionSetProperty(self.vtSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
  int maxKeyInterval = (int)(self.fps * 2);
  CFNumberRef keyNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxKeyInterval);
  VTSessionSetProperty(self.vtSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyNum);
  CFRelease(keyNum);

  int bitrate = (int)self.bitrateBps;
  CFNumberRef brNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bitrate);
  VTSessionSetProperty(self.vtSession, kVTCompressionPropertyKey_AverageBitRate, brNum);
  CFRelease(brNum);

  VTCompressionSessionPrepareToEncodeFrames(self.vtSession);
}

- (void)startAcceptLoop {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    while (self.running && self.listenFd >= 0) {
      struct sockaddr_in cli;
      socklen_t len = sizeof(cli);
      int cfd = accept(self.listenFd, (struct sockaddr *)&cli, &len);
      if (cfd < 0) {
        if (!self.running) break;
        usleep(50000);
        continue;
      }
      int nodelay = 1;
      setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
      int nosigpipe = 1;
      setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
      dispatch_async(self.netQueue, ^{
        [self.clientFds addObject:@(cfd)];
      });
    }
  });
}

- (void)startCaptureTimer {
  if (self.frameTimer) {
    dispatch_source_cancel(self.frameTimer);
    self.frameTimer = nil;
  }
  uint64_t intervalNs = (uint64_t)(NSEC_PER_SEC / MAX(1, self.fps));
  self.frameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.encodeQueue);
  dispatch_source_set_timer(self.frameTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNs, intervalNs / 4);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.frameTimer, ^{
    [weakSelf captureAndEncodeFrame];
  });
  dispatch_resume(self.frameTimer);
}

- (void)captureAndEncodeFrame {
  if (!self.running || !self.vtSession) return;

  __block BOOL hasClients = NO;
  dispatch_sync(self.netQueue, ^{
    hasClients = self.clientFds.count > 0;
  });
  if (!hasClients) return;

  NSDictionary *attrs = @{
    (id)kIOSurfaceWidth: @(self.width),
    (id)kIOSurfaceHeight: @(self.height),
    (id)kIOSurfaceBytesPerElement: @4,
    (id)kIOSurfacePixelFormat: @((uint32_t)kCVPixelFormatType_32BGRA)
  };
  IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)attrs);
  if (!surface) return;

  if (self.renderDisplayFn) {
    self.renderDisplayFn(0, CFSTR("LCD"), surface, 0, 0);
  }

  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
  CFRelease(surface);
  if (cr != kCVReturnSuccess || !pixelBuffer) return;

  CMTime pts = CMTimeMake(self.frameIndex++, (int32_t)self.fps);
  VTEncodeInfoFlags flags = 0;
  VTCompressionSessionEncodeFrame(self.vtSession, pixelBuffer, pts, kCMTimeInvalid, NULL, NULL, &flags);
  CVPixelBufferRelease(pixelBuffer);
}

- (void)broadcastAnnexB:(NSData *)data {
  if (!data.length) return;
  dispatch_async(self.netQueue, ^{
    NSMutableIndexSet *dead = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < self.clientFds.count; i++) {
      int fd = self.clientFds[i].intValue;
      const uint8_t *bytes = (const uint8_t *)data.bytes;
      size_t remaining = data.length;
      while (remaining > 0) {
        ssize_t sent = send(fd, bytes, remaining, 0);
        if (sent <= 0) {
          close(fd);
          [dead addIndex:i];
          break;
        }
        bytes += sent;
        remaining -= (size_t)sent;
      }
    }
    if (dead.count > 0) {
      [self.clientFds removeObjectsAtIndexes:dead];
    }
  });
}

- (void)stop {
  self.running = NO;
  if (self.frameTimer) {
    dispatch_source_cancel(self.frameTimer);
    self.frameTimer = nil;
  }
  if (self.listenFd >= 0) {
    close(self.listenFd);
    self.listenFd = -1;
  }
  dispatch_sync(self.netQueue, ^{
    for (NSNumber *n in self.clientFds) close(n.intValue);
    [self.clientFds removeAllObjects];
  });
  if (self.vtSession) {
    VTCompressionSessionInvalidate(self.vtSession);
    CFRelease(self.vtSession);
    self.vtSession = NULL;
  }
}

@end

static void IFarmVTOutputCallback(void *outputCallbackRefCon,
                                  void *sourceFrameRefCon,
                                  OSStatus status,
                                  VTEncodeInfoFlags infoFlags,
                                  CMSampleBufferRef sampleBuffer) {
  if (status != noErr || !sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) return;
  IFarmH264Server *server = (__bridge IFarmH264Server *)outputCallbackRefCon;

  NSMutableData *annexB = [NSMutableData data];
  BOOL isKey = NO;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
    isKey = !CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
  }

  if (isKey) {
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    size_t spsSize = 0, ppsSize = 0;
    const uint8_t *sps = NULL, *pps = NULL;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsSize, NULL, NULL) == noErr &&
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsSize, NULL, NULL) == noErr) {
      [annexB appendBytes:kAnnexBStartCode length:4];
      [annexB appendBytes:sps length:spsSize];
      [annexB appendBytes:kAnnexBStartCode length:4];
      [annexB appendBytes:pps length:ppsSize];
    }
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLen = 0;
  char *dataPtr = NULL;
  if (CMBlockBufferGetDataPointer(block, 0, NULL, &totalLen, &dataPtr) == kCMBlockBufferNoErr && dataPtr) {
    size_t offset = 0;
    while (offset + 4 <= totalLen) {
      uint32_t naluLen = 0;
      memcpy(&naluLen, dataPtr + offset, 4);
      naluLen = CFSwapInt32BigToHost(naluLen);
      offset += 4;
      if (offset + naluLen > totalLen) break;
      [annexB appendBytes:kAnnexBStartCode length:4];
      [annexB appendBytes:dataPtr + offset length:naluLen];
      offset += naluLen;
    }
  }

  [server broadcastAnnexB:annexB];
}

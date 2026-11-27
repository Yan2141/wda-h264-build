#import "IFarmH264Server.h"
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <dlfcn.h>
#import <errno.h>
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
@property (nonatomic, assign) OSStatus vtCreateStatus;
@property (nonatomic, assign) OSStatus vtPrepareStatus;
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
  int targetW = (int)MIN(maxWidth > 0 ? maxWidth : 544, bounds.size.width * [UIScreen mainScreen].scale);
  targetW = MAX(256, (targetW / 16) * 16);
  int targetH = MAX(256, ((int)round(targetW * aspect) / 16) * 16);
  self.width = targetW;
  self.height = targetH;

  uint16_t listenPort = port > 0 ? port : 9101;
  int fd = socket(AF_INET6, SOCK_STREAM, 0);
  int yes = 1;
  int bound = -1;
  if (fd >= 0) {
    int no = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in6 addr6;
    memset(&addr6, 0, sizeof(addr6));
    addr6.sin6_family = AF_INET6;
    addr6.sin6_port = htons(listenPort);
    addr6.sin6_addr = in6addr_any;
    bound = bind(fd, (struct sockaddr *)&addr6, sizeof(addr6));
    if (bound != 0) {
      close(fd);
      fd = -1;
    }
  }
  if (fd < 0) {
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
      NSLog(@"[IFarmH264Server] socket() failed errno=%d", errno);
      return NO;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(listenPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    bound = bind(fd, (struct sockaddr *)&addr, sizeof(addr));
  }

  if (bound != 0 || listen(fd, 8) != 0) {
    NSLog(@"[IFarmH264Server] bind/listen failed on port %u errno=%d", listenPort, errno);
    close(fd);
    return NO;
  }
  NSLog(@"[IFarmH264Server] Listening on port %u (dual-stack, %dx%d @ %ldfps)", listenPort, self.width, self.height, (long)self.fps);

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

  NSDictionary *srcAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @((uint32_t)kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey: @(self.width),
    (id)kCVPixelBufferHeightKey: @(self.height),
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };
  OSStatus st = VTCompressionSessionCreate(kCFAllocatorDefault,
                                           self.width,
                                           self.height,
                                           kCMVideoCodecType_H264,
                                           NULL,
                                           (__bridge CFDictionaryRef)srcAttrs,
                                           NULL,
                                           IFarmVTOutputCallback,
                                           (__bridge void *)self,
                                           &_vtSession);
  self.vtCreateStatus = st;
  NSLog(@"[IFarmH264Server] VTCompressionSessionCreate status=%d session=%p (%dx%d)", (int)st, self.vtSession, self.width, self.height);
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

  self.vtPrepareStatus = VTCompressionSessionPrepareToEncodeFrames(self.vtSession);
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
      NSLog(@"[IFarmH264Server] Client accepted fd=%d vtSession=%p renderFn=%p", cfd, self.vtSession, self.renderDisplayFn);
      if (!self.vtSession) {
        NSString *dbg = [NSString stringWithFormat:@"#ERR:no_vtSession vtCreate=%d vtPrep=%d renderFn=%p %dx%d\n", (int)self.vtCreateStatus, (int)self.vtPrepareStatus, self.renderDisplayFn, self.width, self.height];
        const char *cstr = dbg.UTF8String;
        send(cfd, cstr, strlen(cstr), 0);
      }
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

  NSDictionary *pbAttrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };
  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault,
                                    self.width,
                                    self.height,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)pbAttrs,
                                    &pixelBuffer);
  if (cr != kCVReturnSuccess || !pixelBuffer) {
    NSString *dbg = [NSString stringWithFormat:@"#ERR:pbCreate=%d\n", (int)cr];
    [self broadcastAnnexB:[dbg dataUsingEncoding:NSUTF8StringEncoding]];
    return;
  }

  // Khung đầu tiên: điền nền BGRA mẫu để xác minh encoder + callback + TCP
  if (self.frameIndex == 0 && CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess) {
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bpr = CVPixelBufferGetBytesPerRow(pixelBuffer);
    if (base && bpr > 0) memset(base, 0x40, bpr * (size_t)self.height);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  }

  IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
  if (surface && self.renderDisplayFn && self.frameIndex > 0) {
    self.renderDisplayFn(0, CFSTR("LCD"), surface, 0, 0);
  }

  CMTime pts = CMTimeMake(self.frameIndex++, (int32_t)self.fps);
  CMTime dur = CMTimeMake(1, (int32_t)self.fps);
  VTEncodeInfoFlags flags = 0;
  OSStatus encSt = VTCompressionSessionEncodeFrame(self.vtSession, pixelBuffer, pts, dur, NULL, NULL, &flags);
  if (encSt != noErr) {
    NSString *dbg = [NSString stringWithFormat:@"#ERR:encode=%d\n", (int)encSt];
    [self broadcastAnnexB:[dbg dataUsingEncoding:NSUTF8StringEncoding]];
  }
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
  IFarmH264Server *server = (__bridge IFarmH264Server *)outputCallbackRefCon;
  if (status != noErr || !sampleBuffer || !CMSampleBufferDataIsReady(sampleBuffer)) {
    NSString *dbg = [NSString stringWithFormat:@"#ERR:vtCb=%d ready=%d\n", (int)status, sampleBuffer ? (int)CMSampleBufferDataIsReady(sampleBuffer) : -1];
    [server broadcastAnnexB:[dbg dataUsingEncoding:NSUTF8StringEncoding]];
    return;
  }

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

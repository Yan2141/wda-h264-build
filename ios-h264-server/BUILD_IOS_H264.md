# Hướng dẫn build module H.264 TCP (cổng 9101) vào WDA `.ipa` cho TrollStore

Phía PC (`iFarm-AirPlay-H264`) đã sẵn sàng:
- `UsbmuxForwarder` tự động mở tunnel tới cổng `9101` của iPhone qua `usbmuxd` (`127.0.0.1:27015`).
- `DeviceStreamPipeline` tách gói H.264 Annex-B qua `H264AccessUnitParser` và đẩy qua `/api/h264/:udid` tới `WebCodecs` (`webcodecs-h264.js`).
- Khi frame H.264 đầu tiên được giải mã thành công, `confirm-render` tự động tạm dừng luồng MJPEG (`9100`).

## Các bước build trên macOS (Xcode)
1. Mở project `WebDriverAgent.xcodeproj` trong Xcode.
2. Kéo 2 file `IFarmH264Server.h` và `IFarmH264Server.m` vào target `WebDriverAgentLib` (hoặc `WebDriverAgentRunner`).
3. Thêm các framework sau vào **Build Phases -> Link Binary With Libraries** (nếu chưa có):
   - `VideoToolbox.framework`
   - `CoreVideo.framework`
   - `CoreMedia.framework`
   - `IOSurface.framework`
   - `QuartzCore.framework`
4. Trong điểm khởi động WDA (ví dụ `FBWebServer.m` ngay trước hoặc sau `startServing`):
   ```objc
   #import "IFarmH264Server.h"
   // ...
   [[IFarmH264Server sharedServer] startWithPort:9101 fps:15 maxWidth:540 bitrateBps:1200000];
   ```
5. Build `WebDriverAgentRunner` (Generic iOS Device), đóng gói thành `.ipa`, rồi **trích xuất và hợp nhất** entitlement gốc của executable với `entitlements.plist` trước khi ký `ldid` (tránh làm mất các quyền sẵn có của WDA Runner):
   ```bash
   APP_BIN="Payload/WebDriverAgentRunner-Runner.app/WebDriverAgentRunner-Runner"
   ldid -e "$APP_BIN" > orig_entitlements.plist
   /usr/libexec/PlistBuddy -c "Merge entitlements.plist" orig_entitlements.plist
   ldid -Sorig_entitlements.plist "$APP_BIN"
   ```
6. Nén lại thành bản thử riêng `wda-h264-test.ipa` và cài qua TrollStore lên **1 máy iPhone thử nghiệm** trước.

## Tiêu chí nghiệm thu bản thử (`wda-h264-test.ipa`, hỗ trợ iOS 12+)
1. `CARenderServerRenderDisplay` trên dải iOS mục tiêu (từ iOS 12 trở lên: TrollStore ở iOS 14–16 hoặc jailbreak/`ldid` ở iOS 12–13) có hình khi chuyển giữa SpringBoard và các ứng dụng.
2. `iFarm` kết nối được cổng loopback `9101` qua `usbmuxd` (`UsbmuxForwarder`), Electron vẽ được luồng H.264 qua `WebCodecs`.
3. WDA vẫn nhận tap/vuốt bình thường trong lúc phát H.264, và MJPEG (`9100`) tự lên hình lại khi dừng luồng H.264.

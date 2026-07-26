/// Flutter front-end for Harbor SoCs.
///
/// A toolkit of Flutter widgets that surface a Harbor SoC's peripherals,
/// whether driven from RTL simulation today or real hardware later. The first
/// feature is the video monitor; a serial console and audio in/out are planned.
///
/// Video: use [captureFramebufferFrame] (re-exported from `package:harbor`) to
/// scan a framebuffer out through the real display datapath in the ROHD
/// simulator, then show the result with [VideoMonitor].
library;

export 'package:harbor/harbor.dart'
    show CapturedFrame, captureFramebufferFrame, HarborDisplayTiming;

// Video
export 'src/video/video_monitor.dart';

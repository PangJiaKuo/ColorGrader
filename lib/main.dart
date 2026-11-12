// ============================================================================
// ColorGrader —— 本地离线运行的 Flutter 图片调色 App
// ----------------------------------------------------------------------------
// 核心设计（对应需求中的"强制逻辑"）：
//   1. 相册模式：预览永远基于「原图解码出来的缩略图原始像素」(raw RGBA) 重新计算，
//      导出永远重新读取「原始文件」再用整套参数计算。任何处理结果都不会回写进
//      预览源 / 导出源，因此不存在"二次叠加调色"。
//   2. 相机模式：ImageStream 每一帧在独立 isolate 中做 YUV→RGB + 全参数调色渲染，
//      主 isolate 只负责把 RGBA 变成 ui.Image 显示，保证不卡 UI；
//      拍照时先 stopImageStream（Android 必须），takePicture 拿到原始 JPEG，
//      再对原始 JPEG 应用当前参数生成最终图片。
//   3. 预览低分辨率 / 导出高分辨率：预览缩略图长边 900px，相机帧长边 480px，
//      导出长边最多 4096px（内存安全上限）。
//
// 所有像素运算集中在 PixelEngine + applyColorPipeline + applySharpen 三个纯函数里，
// 相册预览、相机预览、最终导出走的是同一套数学，颜色表现完全一致。
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 相册预览缩略图的处理上限（长边像素）
const int _kThumbMaxEdge = 900;

/// 摄像头预览帧的处理上限（长边像素）。越大越清晰但越吃 CPU
const int _kFrameMaxEdge = 480;

/// 导出/拍照最终出图的长边上限，避免超大图在 isolate 里 OOM
const int _kPhotoMaxEdge = 4096;

/// 保存到相系统的相册名
const String _kAlbumName = 'ColorGrader';

// ============================================================================
// 1. 调色参数模型
// ============================================================================

@immutable
class AdjustParams {
  const AdjustParams({
    this.brightness = 0.0,
    this.contrast = 0.0,
    this.saturation = 0.0,
    this.temperature = 0.0,
    this.sharpen = 0.0,
    this.highlights = 0.0,
    this.shadows = 0.0,
    this.tint = 0.0,
    this.exposure = 0.0,
    this.fade = 0.0,
  });

  /// 全部归零的中性参数（"重置参数"用它）
  static const AdjustParams neutral = AdjustParams();

  final double brightness; // 亮度 -100..100
  final double contrast; // 对比度 -100..100
  final double saturation; // 饱和度 -100..100
  final double temperature; // 色温 -100..100（正=暖，负=冷）
  final double sharpen; // 锐化 0..100
  final double highlights; // 高光 -100..100
  final double shadows; // 阴影 -100..100
  final double tint; // 色调 -100..100（正=品红，负=绿）
  final double exposure; // 曝光 -100..100（乘法增益）
  final double fade; // 褪色 0..100（向中灰混合的胶片灰雾）

  bool get isNeutral =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      temperature == 0 &&
      sharpen == 0 &&
      highlights == 0 &&
      shadows == 0 &&
      tint == 0 &&
      exposure == 0 &&
      fade == 0;

  AdjustParams copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
    double? temperature,
    double? sharpen,
    double? highlights,
    double? shadows,
    double? tint,
    double? exposure,
    double? fade,
  }) {
    return AdjustParams(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temperature: temperature ?? this.temperature,
      sharpen: sharpen ?? this.sharpen,
      highlights: highlights ?? this.highlights,
      shadows: shadows ?? this.shadows,
      tint: tint ?? this.tint,
      exposure: exposure ?? this.exposure,
      fade: fade ?? this.fade,
    );
  }

  /// 模板 JSON 只保存参数，不含任何图片数据
  Map<String, dynamic> toJson() => <String, dynamic>{
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'temperature': temperature,
    'sharpen': sharpen,
    'highlights': highlights,
    'shadows': shadows,
    'tint': tint,
    'exposure': exposure,
    'fade': fade,
  };

  factory AdjustParams.fromJson(Map<String, dynamic> json) {
    double d(String k) {
      final dynamic v = json[k];
      if (v is num) return v.toDouble();
      return 0.0;
    }

    return AdjustParams(
      brightness: d('brightness'),
      contrast: d('contrast'),
      saturation: d('saturation'),
      temperature: d('temperature'),
      sharpen: d('sharpen'),
      highlights: d('highlights'),
      shadows: d('shadows'),
      tint: d('tint'),
      exposure: d('exposure'),
      fade: d('fade'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AdjustParams &&
      other.brightness == brightness &&
      other.contrast == contrast &&
      other.saturation == saturation &&
      other.temperature == temperature &&
      other.sharpen == sharpen &&
      other.highlights == highlights &&
      other.shadows == shadows &&
      other.tint == tint &&
      other.exposure == exposure &&
      other.fade == fade;

  @override
  int get hashCode => Object.hash(
    brightness,
    contrast,
    saturation,
    temperature,
    sharpen,
    highlights,
    shadows,
    tint,
    exposure,
    fade,
  );
}

// ============================================================================
// 2. 像素处理引擎（纯 Dart，可用于任意 isolate）
// ============================================================================
//
// 处理顺序（必须在所有路径上保持一致）：
//   亮度 → 对比度 → 色温   （三者都是逐通道仿射，可合并成 3 张 256 项 LUT）
//   → 高光/阴影             （按亮度加权的加性映射，预计算成 256 项 tone LUT）
//   → 饱和度               （围绕亮度做线性缩放）
//   → 锐化                 （空间卷积，独立的 unsharp 两趟扫描）
//
// 之所以把亮度/对比度/色温做成 LUT：预览每帧要处理几十万像素，
// 查表比 float 运算快一个数量级，而且预览与导出共用同一 LUT，颜色严格一致。

@pragma('vm:prefer-inline')
int _clamp255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

@pragma('vm:prefer-inline')
int _q255(double v) {
  final int i = (v * 255.0).round();
  return i < 0 ? 0 : (i > 255 ? 255 : i);
}

class PixelEngine {
  PixelEngine(AdjustParams p) {
    _build(p);
  }

  final Uint8List lutR = Uint8List(256);
  final Uint8List lutG = Uint8List(256);
  final Uint8List lutB = Uint8List(256);
  final Int16List tone = Int16List(256);

  /// 饱和度系数，定点 256 = 1.0
  int satMul = 256;

  /// 褪色系数，定点 256 = 不褪色；其余按比例与中灰 128 混合
  int fadeMul = 256;

  void _build(AdjustParams p) {
    // 亮度：最多 ±0.35（归一化 0..1 上的偏移量）
    final double bOff = (p.brightness / 100.0) * 0.35;
    // 对比度：0.1x ~ 1.9x
    final double k = 1.0 + (p.contrast / 100.0) * 0.9;
    // 色温：正数偏暖（红↑蓝↓），负数偏冷
    final double tShift = (p.temperature / 100.0) * 0.12;
    // 高光 / 阴影：按亮度平方加权，最大 ±0.30
    final double hi = (p.highlights / 100.0) * 0.30;
    final double sh = (p.shadows / 100.0) * 0.30;
    // 曝光：乘法增益 0.4x ~ 1.6x
    final double eGain = 1.0 + (p.exposure / 100.0) * 0.6;
    // 色调：正数偏品红（R/B↑ G↓），负数偏绿
    final double tintAmt = (p.tint / 100.0) * 0.10;
    // 褪色：0..0.35 比例向中灰混合
    final double fadeK = (p.fade / 100.0) * 0.35;

    satMul = ((1.0 + p.saturation / 100.0) * 256.0).round().clamp(0, 512);
    fadeMul = ((1.0 - fadeK) * 256.0).round().clamp(0, 256);

    for (int i = 0; i < 256; i++) {
      final double v = i / 255.0;
      // 先亮度，再对比度（围绕中灰 0.5），再曝光乘法增益
      final double nm = (((v + bOff) - 0.5) * k + 0.5) * eGain;
      lutR[i] = _q255(nm + tShift * 1.0 + tintAmt);
      lutG[i] = _q255(nm + tShift * 0.15 - tintAmt);
      lutB[i] = _q255(nm - tShift * 1.0 + tintAmt);
    }

    for (int l = 0; l < 256; l++) {
      final double L = l / 255.0;
      final double hiW = L * L; // 高光权重：越亮越受影响
      final double shW = (1.0 - L) * (1.0 - L); // 阴影权重：越暗越受影响
      final double d = hi * hiW + sh * shW;
      // 取整到 0..255 的加性偏移，值域 ±77 足够表达 ±0.30
      tone[l] = (d * 255.0).round().clamp(-77, 77);
    }
  }
}

/// 把一帧 packed RGBA（长度为 w*h*4）就地做完整调色。
/// 调用方负责传入副本，绝不传"已经调过色的缓冲区"。
void applyColorPipeline(Uint8List px, int w, int h, PixelEngine eng) {
  final Uint8List lutR = eng.lutR;
  final Uint8List lutG = eng.lutG;
  final Uint8List lutB = eng.lutB;
  final Int16List tone = eng.tone;
  final int satMul = eng.satMul;
  final int fadeMul = eng.fadeMul;
  final int fadeGray = 256 - fadeMul; // 中灰混合系数，0 = 不褪色
  final int total = w * h * 4;

  for (int o = 0; o < total; o += 4) {
    // 1) 亮度 / 对比度 / 色温（查表）
    final int r2 = lutR[px[o]];
    final int g2 = lutG[px[o + 1]];
    final int b2 = lutB[px[o + 2]];

    // 2) 高光 / 阴影：按亮度加权，红绿蓝加同一个 delta，亮度只会整体平移
    final int l = (r2 * 77 + g2 * 150 + b2 * 29) >> 8; // 0.299/0.587/0.114 定点
    final int d = tone[l];
    int rr = _clamp255(r2 + d);
    int gg = _clamp255(g2 + d);
    int bb = _clamp255(b2 + d);
    final int l2 = _clamp255(l + d);

    // 3) 饱和度：围绕亮度缩放
    rr = _clamp255(l2 + (((rr - l2) * satMul) >> 8));
    gg = _clamp255(l2 + (((gg - l2) * satMul) >> 8));
    bb = _clamp255(l2 + (((bb - l2) * satMul) >> 8));

    // 4) 褪色：向中灰 128 混合（fadeGray=0 时保持原值）
    if (fadeGray > 0) {
      rr = _clamp255((rr * fadeMul + 128 * fadeGray) >> 8);
      gg = _clamp255((gg * fadeMul + 128 * fadeGray) >> 8);
      bb = _clamp255((bb * fadeMul + 128 * fadeGray) >> 8);
    }

    px[o] = rr;
    px[o + 1] = gg;
    px[o + 2] = bb;
    // alpha 保持原样（输入恒为 255）
  }
}

/// 反锐化掩膜（unsharp mask）：先横向再纵向各做一次 3 点差分，
/// 全流程只需要两行缓冲区，不需要整帧拷贝，4096px 的导出图也不爆内存。
void applySharpen(Uint8List px, int w, int h, double amount) {
  if (amount <= 0.005 || w < 3 || h < 3) return;
  // 定点增益：amount=1.0 时约 0.47 的差分放大
  final int a = (amount * 120.0).round().clamp(0, 255);
  final int rowBytes = w * 4;

  // ---- 横向 pass（就地，用 prev 保存原始左邻像素） ----
  for (int y = 0; y < h; y++) {
    final int base = y * rowBytes;
    int prevR = px[base];
    int prevG = px[base + 1];
    int prevB = px[base + 2];
    for (int x = 0; x < w; x++) {
      final int i = base + x * 4;
      final int curR = px[i];
      final int curG = px[i + 1];
      final int curB = px[i + 2];
      final int nextR = (x + 1 < w) ? px[i + 4] : curR;
      final int nextG = (x + 1 < w) ? px[i + 5] : curG;
      final int nextB = (x + 1 < w) ? px[i + 6] : curB;

      final int nr = curR + ((a * ((curR << 1) - prevR - nextR)) >> 8);
      final int ng = curG + ((a * ((curG << 1) - prevG - nextG)) >> 8);
      final int nb = curB + ((a * ((curB << 1) - prevB - nextB)) >> 8);

      px[i] = _clamp255(nr);
      px[i + 1] = _clamp255(ng);
      px[i + 2] = _clamp255(nb);

      prevR = curR;
      prevG = curG;
      prevB = curB;
    }
  }

  // ---- 纵向 pass（就地，prevRow 保存上一行的"横向处理后"原始值） ----
  Uint8List prevRow = Uint8List(rowBytes);
  Uint8List curRow = Uint8List(rowBytes);
  for (int y = 0; y < h; y++) {
    final int base = y * rowBytes;
    final int downBase = (y + 1 < h) ? base + rowBytes : base;
    for (int x = 0; x < w; x++) {
      final int i = base + x * 4;
      final int curR = px[i];
      final int curG = px[i + 1];
      final int curB = px[i + 2];
      curRow[x * 4] = curR;
      curRow[x * 4 + 1] = curG;
      curRow[x * 4 + 2] = curB;

      final int upR = (y > 0) ? prevRow[x * 4] : curR;
      final int upG = (y > 0) ? prevRow[x * 4 + 1] : curG;
      final int upB = (y > 0) ? prevRow[x * 4 + 2] : curB;
      final int dR = px[downBase + x * 4];
      final int dG = px[downBase + x * 4 + 1];
      final int dB = px[downBase + x * 4 + 2];

      px[i] = _clamp255(curR + ((a * ((curR << 1) - upR - dR)) >> 8));
      px[i + 1] = _clamp255(curG + ((a * ((curG << 1) - upG - dG)) >> 8));
      px[i + 2] = _clamp255(curB + ((a * ((curB << 1) - upB - dB)) >> 8));
    }
    // 交换缓冲：下一轮的 prevRow 就是本行横向处理后的值
    final Uint8List tmp = prevRow;
    prevRow = curRow;
    curRow = tmp;
  }
}

/// 对一段 packed RGBA 施加参数（含锐化），供相册导出 / 拍照出图使用
void renderRgbaInPlace(Uint8List rgba, int w, int h, AdjustParams params) {
  applyColorPipeline(rgba, w, h, PixelEngine(params));
  applySharpen(rgba, w, h, params.sharpen / 100.0);
}

// ============================================================================
// 3. 摄像头帧：请求 / 响应模型 + 常驻 worker isolate
// ============================================================================

class FrameRequest {
  const FrameRequest({
    required this.seq,
    required this.isBgra,
    required this.yPlane,
    required this.uPlane,
    required this.vPlane,
    required this.yRowStride,
    required this.yPixelStride,
    required this.uvRowStride,
    required this.uvPixelStride,
    required this.vRowStride,
    required this.vPixelStride,
    required this.bgraRowStride,
    required this.bgraPixelStride,
    required this.srcW,
    required this.srcH,
    required this.rotation,
    required this.mirror,
    required this.maxEdge,
    required this.params,
  });

  final int seq;
  final bool isBgra;

  // YUV_420_888 三个平面
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int yRowStride;
  final int yPixelStride;
  final int uvRowStride;
  final int uvPixelStride;
  final int vRowStride;
  final int vPixelStride;

  // BGRA8888 回退路径
  final int bgraRowStride;
  final int bgraPixelStride;

  final int srcW;
  final int srcH;
  final int rotation; // 0 / 90 / 180 / 270（顺时针）
  final bool mirror; // 前摄镜像
  final int maxEdge;
  final AdjustParams params;
}

class FrameResponse {
  const FrameResponse({
    required this.seq,
    required this.width,
    required this.height,
    required this.rgba,
    this.error,
  });

  factory FrameResponse.failure(int seq, String error) => FrameResponse(
    seq: seq,
    width: 0,
    height: 0,
    rgba: Uint8List(0),
    error: error,
  );

  final int seq;
  final int width;
  final int height;
  final Uint8List rgba;
  final String? error;
}

/// 在 worker isolate 中把一帧摄像头数据 → 已调色的 RGBA
FrameResponse renderCameraFrame(FrameRequest r) {
  final int srcW = r.srcW;
  final int srcH = r.srcH;
  if (srcW <= 0 || srcH <= 0) {
    return FrameResponse.failure(r.seq, 'invalid frame size');
  }

  // 降采样步长：只取整像素，保证不引入色彩串扰
  int step = 1;
  final int longEdge = math.max(srcW, srcH);
  if (longEdge > r.maxEdge) {
    step = (longEdge / r.maxEdge).ceil();
  }
  final int sw = srcW ~/ step;
  final int sh = srcH ~/ step;

  final int rot = ((r.rotation % 360) + 360) % 360;
  final bool swap = rot == 90 || rot == 270;
  final int outW = swap ? sh : sw;
  final int outH = swap ? sw : sh;

  final Uint8List out = Uint8List(outW * outH * 4);
  final PixelEngine eng = PixelEngine(r.params);
  final Uint8List lutR = eng.lutR;
  final Uint8List lutG = eng.lutG;
  final Uint8List lutB = eng.lutB;
  final Int16List tone = eng.tone;
  final int satMul = eng.satMul;
  final int fadeMul = eng.fadeMul;
  final int fadeGray = 256 - fadeMul;

  // 逆映射：把输出坐标 (dx,dy) 映射回降采样坐标系 (sx,sy)，系数只有 0/±1
  final (int ax, int bx, int cx, int ay, int by, int cy) = switch (rot) {
    90 => (0, 1, 0, -1, 0, sh - 1),
    180 => (-1, 0, sw - 1, 0, -1, sh - 1),
    270 => (0, -1, sw - 1, 1, 0, 0),
    _ => (1, 0, 0, 0, 1, 0),
  };

  final Uint8List yP = r.yPlane;
  final Uint8List uP = r.uPlane;
  final Uint8List vP = r.vPlane;
  final bool planarV = vP.isNotEmpty && r.vRowStride > 0;
  final bool bgra = r.isBgra;
  final bool mirror = r.mirror;

  int o = 0;
  for (int dy = 0; dy < outH; dy++) {
    for (int dx0 = 0; dx0 < outW; dx0++) {
      final int dx = mirror ? (outW - 1 - dx0) : dx0;
      int sx = ax * dx + bx * dy + cx;
      int sy = ay * dx + by * dy + cy;
      if (sx < 0) {
        sx = 0;
      } else if (sx >= sw) {
        sx = sw - 1;
      }
      if (sy < 0) {
        sy = 0;
      } else if (sy >= sh) {
        sy = sh - 1;
      }

      final int px = sx * step;
      final int py = sy * step;

      int r0;
      int g0;
      int b0;

      if (bgra) {
        final int idx = py * r.bgraRowStride + px * r.bgraPixelStride;
        if (idx + 2 >= r.yPlane.length) {
          r0 = 0;
          g0 = 0;
          b0 = 0;
        } else {
          b0 = yP[idx];
          g0 = yP[idx + 1];
          r0 = yP[idx + 2];
        }
      } else {
        final int yIdx = py * r.yRowStride + px * r.yPixelStride;
        final int yv = (yIdx < yP.length) ? yP[yIdx] : 16;
        final int uvY = py >> 1;
        final int uvX = px >> 1;
        final int uIdx = uvY * r.uvRowStride + uvX * r.uvPixelStride;
        final int uv = (uIdx < uP.length) ? uP[uIdx] : 128;
        int vv;
        if (planarV) {
          final int vIdx = uvY * r.vRowStride + uvX * r.vPixelStride;
          vv = (vIdx < vP.length) ? vP[vIdx] : 128;
        } else {
          // NV12/NV21：U、V 交错在同一个平面里，UV 交错时 uPixelStride 通常为 2
          final int vIdx = uIdx + (r.uvPixelStride >= 2 ? 1 : 0);
          vv = (vIdx < uP.length) ? uP[vIdx] : 128;
        }
        final int u1 = uv - 128;
        final int v1 = vv - 128;
        r0 = yv + ((359 * v1) >> 8);
        g0 = yv - ((88 * u1 + 183 * v1) >> 8);
        b0 = yv + ((454 * u1) >> 8);
        r0 = _clamp255(r0);
        g0 = _clamp255(g0);
        b0 = _clamp255(b0);
      }

      // 与 applyColorPipeline 完全一致的调色数学
      final int r2 = lutR[r0];
      final int g2 = lutG[g0];
      final int b2 = lutB[b0];
      final int l = (r2 * 77 + g2 * 150 + b2 * 29) >> 8;
      final int d = tone[l];
      int rr = _clamp255(r2 + d);
      int gg = _clamp255(g2 + d);
      int bb = _clamp255(b2 + d);
      final int l2 = _clamp255(l + d);
      rr = _clamp255(l2 + (((rr - l2) * satMul) >> 8));
      gg = _clamp255(l2 + (((gg - l2) * satMul) >> 8));
      bb = _clamp255(l2 + (((bb - l2) * satMul) >> 8));

      // 褪色：与 applyColorPipeline 一致，向中灰 128 混合
      if (fadeGray > 0) {
        rr = _clamp255((rr * fadeMul + 128 * fadeGray) >> 8);
        gg = _clamp255((gg * fadeMul + 128 * fadeGray) >> 8);
        bb = _clamp255((bb * fadeMul + 128 * fadeGray) >> 8);
      }

      out[o] = rr;
      out[o + 1] = gg;
      out[o + 2] = bb;
      out[o + 3] = 255;
      o += 4;
    }
  }

  // 锐化放在最后，只在这一帧的小图上做
  applySharpen(out, outW, outH, r.params.sharpen / 100.0);

  return FrameResponse(seq: r.seq, width: outW, height: outH, rgba: out);
}

/// worker isolate 入口：只做苦力活，收到 FrameRequest 就算一帧
void _frameWorkerEntry(SendPort mainPort) {
  final ReceivePort inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((dynamic msg) {
    if (msg is FrameRequest) {
      try {
        mainPort.send(renderCameraFrame(msg));
      } catch (e) {
        mainPort.send(FrameResponse.failure(msg.seq, '$e'));
      }
    }
  });
}

// ============================================================================
// 4. 图片解码 / 导出（都在临时 isolate 里跑，主线程不卡）
// ============================================================================

class ThumbResult {
  const ThumbResult(this.width, this.height, this.rgba);
  final int width;
  final int height;

  /// 原图缩略图的「原始颜色」像素（RGBA），是相册预览的唯一数据源
  final Uint8List rgba;
}

/// 把原图解码成一张缩略图 RGBA（未做任何调色）
Future<ThumbResult> decodeThumbnail(
  Uint8List srcBytes, {
  int maxEdge = _kThumbMaxEdge,
}) {
  return Isolate.run(() {
    final img.Image? decoded = img.decodeImage(srcBytes);
    if (decoded == null) {
      throw const FormatException('无法解码该图片（可能是不支持的 HEIC 格式）');
    }
    int w = decoded.width;
    int h = decoded.height;
    img.Image work = decoded;
    final int longEdge = math.max(w, h);
    if (longEdge > maxEdge) {
      final double scale = maxEdge / longEdge;
      w = (w * scale).round();
      h = (h * scale).round();
      work = img.copyResize(
        decoded,
        width: w,
        height: h,
        interpolation: img.Interpolation.linear,
      );
    }
    final Uint8List rgba = work.getBytes(order: img.ChannelOrder.rgba);
    return ThumbResult(work.width, work.height, rgba);
  });
}

/// 预览用：对缩略图副本施加参数（绝不改动 source）
Future<Uint8List> renderThumbnailPreview(
  Uint8List source,
  int w,
  int h,
  AdjustParams params,
) {
  return Isolate.run(() {
    final Uint8List copy = Uint8List.fromList(source);
    renderRgbaInPlace(copy, w, h, params);
    return copy;
  });
}

/// 导出/拍照用：解码原始文件 → 全分辨率调色 → JPEG 字节
Future<Uint8List> processPhotoBytes(Uint8List srcBytes, AdjustParams params) {
  return Isolate.run(() {
    final img.Image? decoded = img.decodeImage(srcBytes);
    if (decoded == null) {
      throw const FormatException('无法解码该图片（可能是不支持的 HEIC 格式）');
    }
    int w = decoded.width;
    int h = decoded.height;
    img.Image work = decoded;
    final int longEdge = math.max(w, h);
    if (longEdge > _kPhotoMaxEdge) {
      final double scale = _kPhotoMaxEdge / longEdge;
      w = (w * scale).round();
      h = (h * scale).round();
      work = img.copyResize(
        decoded,
        width: w,
        height: h,
        interpolation: img.Interpolation.linear,
      );
    }
    final Uint8List rgba = work.getBytes(order: img.ChannelOrder.rgba);
    renderRgbaInPlace(rgba, w, h, params);
    final img.Image out = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer, // 注意：这里要 ByteBuffer，不是 Uint8List
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return img.encodeJpg(out, quality: 92);
  });
}

// ============================================================================
// 5. 模板仓库（JSON 存放在应用沙盒）
// ============================================================================

class ColorTemplate {
  const ColorTemplate({
    required this.id,
    required this.name,
    required this.params,
    required this.createdAt,
    this.builtin = false,
  });

  final String id;
  final String name;
  final AdjustParams params;
  final DateTime createdAt;

  /// 内置预设：不写入沙盒、不可删除
  final bool builtin;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'params': params.toJson(),
  };

  factory ColorTemplate.fromJson(Map<String, dynamic> json) {
    final dynamic p = json['params'];
    return ColorTemplate(
      id: (json['id'] ?? '') as String,
      name: (json['name'] ?? '未命名') as String,
      params: AdjustParams.fromJson(
        p is Map<String, dynamic> ? p : const <String, dynamic>{},
      ),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '') as String) ??
          DateTime.now(),
    );
  }
}

/// 内置预设：一键套用，不进沙盒、不可删除。
/// 字段顺序：亮度 对比度 饱和度 色温 锐化 高光 阴影 色调 曝光 褪色。
final List<ColorTemplate> _kBuiltinTemplates = <ColorTemplate>[
  ColorTemplate(
    id: 'builtin-bright',
    name: '明亮清新',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      brightness: 18,
      contrast: 10,
      saturation: 12,
      temperature: 8,
      highlights: 10,
      shadows: 12,
      exposure: 10,
      fade: 8,
    ),
  ),
  ColorTemplate(
    id: 'builtin-sunset',
    name: '暖阳夕阳',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      brightness: 8,
      contrast: 14,
      saturation: 18,
      temperature: 35,
      highlights: 6,
      shadows: 10,
      tint: 6,
      fade: 12,
    ),
  ),
  ColorTemplate(
    id: 'builtin-cool',
    name: '清冷通透',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      brightness: 6,
      contrast: 8,
      saturation: -6,
      temperature: -28,
      shadows: 8,
      tint: -6,
      exposure: 6,
    ),
  ),
  ColorTemplate(
    id: 'builtin-bw',
    name: '黑白复古',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      contrast: 22,
      saturation: -100,
      highlights: -8,
      shadows: 14,
      sharpen: 10,
      fade: 28,
    ),
  ),
  ColorTemplate(
    id: 'builtin-cine',
    name: '电影高对比',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      contrast: 28,
      saturation: 10,
      highlights: -16,
      shadows: -10,
      temperature: -6,
      fade: 10,
    ),
  ),
  ColorTemplate(
    id: 'builtin-japanese',
    name: '柔和日系',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      brightness: 12,
      contrast: -12,
      saturation: -10,
      temperature: 10,
      highlights: 14,
      shadows: 16,
      fade: 22,
    ),
  ),
  ColorTemplate(
    id: 'builtin-food',
    name: '浓郁美食',
    createdAt: DateTime.utc(2024, 1, 1),
    builtin: true,
    params: AdjustParams(
      contrast: 16,
      saturation: 30,
      temperature: 12,
      highlights: 4,
      fade: 6,
    ),
  ),
];

/// 模板只存参数 JSON，落在 getApplicationSupportDirectory()/templates/ 下
/// Android 实际路径形如：
///   /data/user/0/com.pangjiakuo.color_grader/files/color_templates.json
class TemplateRepository {
  static const String _folderName = 'templates';
  static const String _fileName = 'color_templates.json';

  Directory? _dir;

  Future<File> _file() async {
    _dir ??= await getApplicationSupportDirectory();
    final Directory dir = Directory('${_dir!.path}/$_folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return File('${dir.path}/$_fileName');
  }

  Future<String> storagePath() async => (await _file()).path;

  Future<List<ColorTemplate>> load() async {
    final File f = await _file();
    if (!await f.exists()) return <ColorTemplate>[];
    final String text = await f.readAsString();
    if (text.trim().isEmpty) return <ColorTemplate>[];
    final dynamic decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return <ColorTemplate>[];
    final dynamic list = decoded['templates'];
    if (list is! List) return <ColorTemplate>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ColorTemplate.fromJson)
        .toList();
  }

  Future<void> save(List<ColorTemplate> templates) async {
    final File f = await _file();
    final Map<String, dynamic> doc = <String, dynamic>{
      'version': 1,
      'templates': templates.map((ColorTemplate t) => t.toJson()).toList(),
    };
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(doc),
      flush: true,
    );
  }
}

// ============================================================================
// 6. App 入口
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 整个 App 锁竖屏：摄像头 stream 的旋转计算按竖屏推导，锁屏最稳
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const ColorGraderApp());
}

class ColorGraderApp extends StatelessWidget {
  const ColorGraderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ColorGrader 调色工坊',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF6C8CFF),
        scaffoldBackgroundColor: const Color(0xFF101114),
        sliderTheme: const SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          showValueIndicator: ShowValueIndicator.never,
        ),
      ),
      home: const GraderPage(),
    );
  }
}

enum PreviewMode { album, camera }

// ============================================================================
// 7. 主界面
// ============================================================================

class _ParamSpec {
  const _ParamSpec(
    this.label,
    this.icon,
    this.min,
    this.max,
    this.read,
    this.write,
  );

  final String label;
  final IconData icon;
  final double min;
  final double max;
  final double Function(AdjustParams) read;
  final AdjustParams Function(AdjustParams, double) write;
}

final List<_ParamSpec> _kSpecs = <_ParamSpec>[
  _ParamSpec(
    '亮度',
    Icons.brightness_6_outlined,
    -100,
    100,
    (p) => p.brightness,
    (p, v) => p.copyWith(brightness: v),
  ),
  _ParamSpec(
    '对比度',
    Icons.contrast,
    -100,
    100,
    (p) => p.contrast,
    (p, v) => p.copyWith(contrast: v),
  ),
  _ParamSpec(
    '饱和度',
    Icons.palette_outlined,
    -100,
    100,
    (p) => p.saturation,
    (p, v) => p.copyWith(saturation: v),
  ),
  _ParamSpec(
    '色温',
    Icons.thermostat_outlined,
    -100,
    100,
    (p) => p.temperature,
    (p, v) => p.copyWith(temperature: v),
  ),
  _ParamSpec(
    '锐化',
    Icons.details_outlined,
    0,
    100,
    (p) => p.sharpen,
    (p, v) => p.copyWith(sharpen: v),
  ),
  _ParamSpec(
    '高光',
    Icons.wb_sunny_outlined,
    -100,
    100,
    (p) => p.highlights,
    (p, v) => p.copyWith(highlights: v),
  ),
  _ParamSpec(
    '阴影',
    Icons.brightness_low_outlined,
    -100,
    100,
    (p) => p.shadows,
    (p, v) => p.copyWith(shadows: v),
  ),
  _ParamSpec(
    '色调',
    Icons.colorize_outlined,
    -100,
    100,
    (p) => p.tint,
    (p, v) => p.copyWith(tint: v),
  ),
  _ParamSpec(
    '曝光',
    Icons.exposure_outlined,
    -100,
    100,
    (p) => p.exposure,
    (p, v) => p.copyWith(exposure: v),
  ),
  _ParamSpec(
    '褪色',
    Icons.gradient,
    0,
    100,
    (p) => p.fade,
    (p, v) => p.copyWith(fade: v),
  ),
];

/// 单个参数行：滑块 + 可直接输入数值的小输入框，二者双向联动。
class _ParamRow extends StatefulWidget {
  const _ParamRow({
    required this.spec,
    required this.value,
    required this.onChanged,
    required this.onReset,
  });

  final _ParamSpec spec;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  @override
  State<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends State<_ParamRow> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toInt().toString());
    _focus = FocusNode();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  @override
  void didUpdateWidget(_ParamRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 非输入状态下，外部（滑块/模板/重置）改值时同步文本
    if (!_typing && widget.value.toInt() != oldWidget.value.toInt()) {
      _ctrl.text = widget.value.toInt().toString();
    }
  }

  /// 解析输入、clamp 到参数范围并取整后写回；非法输入回退当前值。
  void _commit() {
    final String raw = _ctrl.text.trim();
    final double? parsed = raw.isEmpty ? null : double.tryParse(raw);
    double v = widget.value;
    if (parsed != null) v = parsed;
    v = v.clamp(widget.spec.min, widget.spec.max).roundToDouble();
    final String text = v.toInt().toString();
    if (_ctrl.text != text) _ctrl.text = text;
    _typing = false;
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _ParamSpec spec = widget.spec;
    final double value = widget.value.clamp(spec.min, spec.max);
    final bool active = value != 0;
    return SizedBox(
      height: 44,
      child: Row(
        children: <Widget>[
          Icon(spec.icon, size: 16, color: Colors.white54),
          const SizedBox(width: 8),
          SizedBox(
            width: 42,
            child: Text(
              spec.label,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          Expanded(
            child: Slider(
              min: spec.min,
              max: spec.max,
              value: value,
              onChanged: (double v) {
                _typing = false;
                _ctrl.text = v.toInt().toString();
                widget.onChanged(v);
              },
            ),
          ),
          SizedBox(
            width: 50,
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: false,
              ),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: active ? const Color(0xFF8FA6FF) : Colors.white38,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: '0',
              ),
              onTap: () {
                _typing = true;
                _ctrl.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: _ctrl.text.length,
                );
              },
              onSubmitted: (_) {
                _commit();
                _focus.unfocus();
              },
            ),
          ),
          SizedBox(
            width: 26,
            height: 26,
            child: InkWell(
              borderRadius: BorderRadius.circular(13),
              onTap: widget.onReset,
              child: const Icon(
                Icons.close,
                size: 14,
                color: Colors.white24,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class GraderPage extends StatefulWidget {
  const GraderPage({super.key});

  @override
  State<GraderPage> createState() => _GraderPageState();
}

class _GraderPageState extends State<GraderPage> with WidgetsBindingObserver {
  // ---------- 公共状态 ----------
  PreviewMode _mode = PreviewMode.album;
  AdjustParams _params = AdjustParams.neutral;
  final ImagePicker _picker = ImagePicker();
  final TemplateRepository _repo = TemplateRepository();
  List<ColorTemplate> _templates = <ColorTemplate>[];
  String _templatePath = '';
  bool _busy = false;

  // ---------- 相簿模式 ----------
  String? _originalPath; // 原始文件路径（导出的唯一数据源）
  Uint8List? _thumbSource; // 原图缩略图的原始像素（预览的唯一数据源）
  int _thumbW = 0;
  int _thumbH = 0;
  ui.Image? _previewImage;
  Timer? _previewDebounce;
  int _renderSeq = 0;

  // ---------- 相机模式 ----------
  List<CameraDescription> _cameras = const <CameraDescription>[];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _cameraIniting = false;
  bool _cameraStreaming = false;
  ui.Image? _frameImage;
  int _rotationOffset = 0;

  ReceivePort? _workerPort;
  SendPort? _workerSend;
  Isolate? _workerIsolate;
  bool _frameBusy = false;
  bool _decodingFrame = false;
  int _frameSeq = 0;
  int _latestSentSeq = 0;

  String? _lastCapturePath; // 相机模式最近一次拍照的「原始」文件

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTemplates();
  }

  /// dispose 阶段不能再 setState，用这个标记让内部方法走"纯释放"分支
  bool _disposing = false;

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _previewDebounce?.cancel();
    _previewImage?.dispose();
    _teardownCamera(notifyUi: false);
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerPort?.close();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // 生命周期：切到后台释放相机，回前台重新初始化
  // --------------------------------------------------------------------------
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_mode != PreviewMode.camera) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _teardownCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // ==========================================================================
  // 模板
  // ==========================================================================

  Future<void> _loadTemplates() async {
    try {
      final List<ColorTemplate> list = await _repo.load();
      final String path = await _repo.storagePath();
      if (!mounted) return;
      setState(() {
        _templates = list;
        _templatePath = path;
      });
    } catch (_) {
      // 读失败就当作空列表，不阻塞主流程
    }
  }

  Future<void> _saveTemplateDialog() async {
    final TextEditingController ctrl = TextEditingController(
      text: '模板 ${_templates.length + 1}',
    );
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('保存调色模板'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '模板名称',
            helperText: '只保存 10 个参数，不保存图片',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final ColorTemplate tpl = ColorTemplate(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      params: _params,
      createdAt: DateTime.now(),
    );
    setState(() => _templates = <ColorTemplate>[..._templates, tpl]);
    try {
      await _repo.save(_templates);
      if (!mounted) return;
      _toast('模板「${tpl.name}」已保存');
    } catch (e) {
      if (!mounted) return;
      _toast('保存模板失败：$e');
    }
  }

  Future<void> _deleteTemplate(ColorTemplate tpl) async {
    setState(
      () => _templates = _templates
          .where((ColorTemplate t) => t.id != tpl.id)
          .toList(),
    );
    try {
      await _repo.save(_templates);
      if (!mounted) return;
      _toast('已删除「${tpl.name}」');
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败：$e');
    }
  }

  void _applyTemplate(ColorTemplate tpl) {
    setState(() => _params = tpl.params);
    _schedulePreviewRender();
    _toast('已加载「${tpl.name}」');
  }

  Widget _templateTile(
    ColorTemplate t,
    int badge, {
    required bool builtin,
    required BuildContext sheetCtx,
    required StateSetter? setSheet,
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF2A2D34),
        child: builtin
            ? const Icon(Icons.auto_awesome, size: 14, color: Colors.white54)
            : Text('$badge', style: const TextStyle(fontSize: 12)),
      ),
      title: Text(t.name),
      subtitle: Text(
        _summary(t.params),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: builtin
          ? null
          : IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () async {
                await _deleteTemplate(t);
                setSheet?.call(() {});
              },
            ),
      onTap: () {
        Navigator.pop(sheetCtx);
        _applyTemplate(t);
      },
    );
  }

  Future<void> _showTemplateSheet() async {
    await _loadTemplates();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF181A1F),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setSheet) {
            return SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.62,
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                    child: Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            '模板列表',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _saveTemplateDialog();
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('保存当前'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 2),
                          child: Text(
                            '内置预设',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        for (int i = 0; i < _kBuiltinTemplates.length; i++)
                          _templateTile(
                            _kBuiltinTemplates[i],
                            i + 1,
                            builtin: true,
                            sheetCtx: ctx,
                            setSheet: null,
                          ),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 2),
                          child: Text(
                            '我的模板',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                        if (_templates.isEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 10, 16, 10),
                            child: Text(
                              '还没有自定义模板，调好参数后点「保存当前」',
                              style: TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          )
                        else
                          for (int i = 0; i < _templates.length; i++)
                            _templateTile(
                              _templates[i],
                              i + 1,
                              builtin: false,
                              sheetCtx: ctx,
                              setSheet: setSheet,
                            ),
                      ],
                    ),
                  ),
                  if (_templatePath.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
                      child: Text(
                        'JSON 存放于应用沙盒：$_templatePath',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _summary(AdjustParams p) {
    String f(double v) => v >= 0 ? '+${v.toInt()}' : '${v.toInt()}';
    return '亮${f(p.brightness)} 对${f(p.contrast)} 饱和${f(p.saturation)} '
        '温${f(p.temperature)} 锐${p.sharpen.toInt()} 高${f(p.highlights)} '
        '阴${f(p.shadows)} 调${f(p.tint)} 曝${f(p.exposure)} 褪${p.fade.toInt()}';
  }

  // ==========================================================================
  // 相簿模式
  // ==========================================================================

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    try {
      final XFile? picked = await _picker.pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) return;
      await _loadPhoto(picked.path);
      if (_mode != PreviewMode.album) {
        setState(() => _mode = PreviewMode.album);
        _teardownCamera();
      }
    } catch (e) {
      _toast('打开相册失败：$e');
    }
  }

  /// 载入一张原图：解码缩略图（原始颜色）+ 按原始文件派生预览
  Future<void> _loadPhoto(String path) async {
    setState(() => _busy = true);
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final ThumbResult thumb = await decodeThumbnail(bytes);
      if (!mounted) return;

      // 关键：_thumbSource 永远保存「原始颜色」，后续预览都是从它派生
      _thumbSource = thumb.rgba;
      _thumbW = thumb.width;
      _thumbH = thumb.height;
      _originalPath = path; // 导出时重新读这个文件，绝不读预览结果
      _lastCapturePath = null;

      final Uint8List preview = await renderThumbnailPreview(
        _thumbSource!,
        _thumbW,
        _thumbH,
        _params,
      );
      final ui.Image image = await _imageFromRgba(preview, _thumbW, _thumbH);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _previewImage?.dispose();
        _previewImage = image;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('载入图片失败：$e');
    }
  }

  void _schedulePreviewRender() {
    if (_mode != PreviewMode.album) return;
    _previewDebounce?.cancel();
    // 60ms 防抖：拖动滑块时只在停顿处重算，避免每像素一次 isolate
    _previewDebounce = Timer(
      const Duration(milliseconds: 60),
      _renderPreviewNow,
    );
  }

  Future<void> _renderPreviewNow() async {
    final Uint8List? src = _thumbSource;
    if (src == null) return;
    final int seq = ++_renderSeq;
    final AdjustParams snapshot = _params;
    try {
      final Uint8List rgba = await renderThumbnailPreview(
        src,
        _thumbW,
        _thumbH,
        snapshot,
      );
      if (!mounted || seq != _renderSeq) return; // 有更新的一轮，丢弃旧结果
      final ui.Image image = await _imageFromRgba(rgba, _thumbW, _thumbH);
      if (!mounted || seq != _renderSeq) {
        image.dispose();
        return;
      }
      setState(() {
        _previewImage?.dispose();
        _previewImage = image;
      });
    } catch (_) {
      // 预览失败静默处理，不打断调参
    }
  }

  Future<ui.Image> _imageFromRgba(Uint8List rgba, int w, int h) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      rgba,
    );
    final ui.ImageDescriptor desc = ui.ImageDescriptor.raw(
      buffer,
      width: w,
      height: h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final ui.Codec codec = await desc.instantiateCodec();
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    desc.dispose();
    buffer.dispose();
    return frame.image;
  }

  // ==========================================================================
  // 导出 / 保存
  // ==========================================================================

  Future<void> _exportCurrent() async {
    if (_busy) return;
    final String? sourcePath = _mode == PreviewMode.album
        ? _originalPath
        : _lastCapturePath;
    if (sourcePath == null) {
      _toast(_mode == PreviewMode.album ? '请先从相册导入一张图片' : '请先按快门拍一张照片');
      return;
    }
    setState(() => _busy = true);
    try {
      // 永远从「原始文件」重新计算，不会叠加已有调色
      final Uint8List bytes = await File(sourcePath).readAsBytes();
      final Uint8List jpg = await processPhotoBytes(bytes, _params);
      await _saveToGallery(jpg);
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('已导出到相册（$_kAlbumName）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('导出失败：$e');
    }
  }

  Future<void> _saveToGallery(Uint8List jpegBytes) async {
    final Directory dir = await getTemporaryDirectory();
    final File tmp = File(
      '${dir.path}/cg_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await tmp.writeAsBytes(jpegBytes, flush: true);
    try {
      if (!await Gal.hasAccess()) {
        await Gal.requestAccess();
      }
      await Gal.putImage(tmp.path, album: _kAlbumName);
    } finally {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  // ==========================================================================
  // 相机模式
  // ==========================================================================

  Future<void> _switchMode(PreviewMode mode) async {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (mode == PreviewMode.camera) {
      await _initCamera();
    } else {
      _teardownCamera();
      if (_thumbSource == null) {
        // 从相机切回相簿且没有图：保持空状态
      } else {
        _schedulePreviewRender();
      }
    }
  }

  Future<void> _initCamera() async {
    if (_cameraIniting) return;
    _cameraIniting = true;
    try {
      final PermissionStatus status = await Permission.camera.request();
      if (!status.isGranted) {
        _toast('需要相机权限才能使用实时取景');
        return;
      }
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }
      if (_cameras.isEmpty) {
        _toast('没有找到可用的摄像头');
        return;
      }
      if (_cameraIndex >= _cameras.length) _cameraIndex = 0;

      final CameraDescription desc = _cameras[_cameraIndex];
      final CameraController controller = CameraController(
        desc,
        ResolutionPreset.high, // 720p：兼顾拍照画质与逐帧处理开销
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();

      await _startFrameWorker(); // 常驻 worker，避免每帧新建 isolate
      _controller = controller;

      await controller.startImageStream(_onCameraFrame);
      _cameraStreaming = true;
      if (mounted) setState(() {});
    } catch (e) {
      _toast('相机初始化失败：$e');
    } finally {
      _cameraIniting = false;
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      _toast('设备只有一个摄像头');
      return;
    }
    _teardownCamera();
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initCamera();
  }

  void _teardownCamera({bool notifyUi = true}) {
    final CameraController? c = _controller;
    _controller = null;
    _cameraStreaming = false;
    _frameBusy = false;
    if (c != null) {
      // stopImageStream 可能因为已停止而抛，吞掉即可
      c.stopImageStream().catchError((Object _) {}).whenComplete(() {
        c.dispose();
      });
    }
    if (notifyUi && mounted && !_disposing) {
      setState(() {
        _frameImage?.dispose();
        _frameImage = null;
      });
    } else {
      _frameImage?.dispose();
      _frameImage = null;
    }
  }

  Future<void> _startFrameWorker() async {
    if (_workerSend != null) return;
    _workerPort?.close();
    _workerPort = ReceivePort();
    _workerPort!.listen(_onWorkerMessage);
    _workerIsolate = await Isolate.spawn<SendPort>(
      _frameWorkerEntry,
      _workerPort!.sendPort,
      debugName: 'color-frame-worker',
    );
  }

  void _onWorkerMessage(dynamic msg) {
    if (msg is SendPort) {
      _workerSend = msg;
      return;
    }
    if (msg is FrameResponse) {
      _frameBusy = false;
      if (msg.error != null || msg.rgba.isEmpty) return;
      // 丢弃过期帧：只显示最新一次请求的结果，防止画面"追帧"
      if (msg.seq != _latestSentSeq) return;
      if (_mode != PreviewMode.camera) return;
      _presentFrame(msg);
    }
  }

  Future<void> _presentFrame(FrameResponse res) async {
    if (_decodingFrame) return;
    _decodingFrame = true;
    try {
      final ui.Image image = await _imageFromRgba(
        res.rgba,
        res.width,
        res.height,
      );
      if (!mounted || _mode != PreviewMode.camera) {
        image.dispose();
        return;
      }
      setState(() {
        _frameImage?.dispose();
        _frameImage = image;
      });
    } catch (_) {
      // 单帧失败忽略
    } finally {
      _decodingFrame = false;
    }
  }

  /// 摄像头每一帧回调：只做内存拷贝 + 打包，真正的运算丢给 worker isolate
  void _onCameraFrame(CameraImage image) {
    if (!_cameraStreaming || _frameBusy || _workerSend == null) return;
    if (image.width <= 0 || image.height <= 0) return;

    final bool isBgra = image.format.group == ImageFormatGroup.bgra8888;
    if (image.planes.isEmpty) return;
    if (!isBgra && image.planes.length < 2) return;

    final int rotation =
        (((_controller?.description.sensorOrientation ?? 90) +
            _rotationOffset) %
        360);
    final bool mirror =
        _controller?.description.lensDirection == CameraLensDirection.front;

    // 平面数据必须在回调内拷走：插件可能会复用底层 buffer
    final Uint8List p0 = Uint8List.fromList(image.planes[0].bytes);
    final Uint8List p1 = image.planes.length > 1
        ? Uint8List.fromList(image.planes[1].bytes)
        : Uint8List(0);
    final Uint8List p2 = image.planes.length > 2
        ? Uint8List.fromList(image.planes[2].bytes)
        : Uint8List(0);

    final FrameRequest req = FrameRequest(
      seq: ++_frameSeq,
      isBgra: isBgra,
      yPlane: p0,
      uPlane: p1,
      vPlane: p2,
      yRowStride: image.planes[0].bytesPerRow,
      yPixelStride: image.planes[0].bytesPerPixel ?? 1,
      uvRowStride: image.planes.length > 1 ? image.planes[1].bytesPerRow : 1,
      uvPixelStride: image.planes.length > 1
          ? (image.planes[1].bytesPerPixel ?? 1)
          : 1,
      vRowStride: image.planes.length > 2 ? image.planes[2].bytesPerRow : 0,
      vPixelStride: image.planes.length > 2
          ? (image.planes[2].bytesPerPixel ?? 1)
          : 1,
      bgraRowStride: image.planes[0].bytesPerRow,
      bgraPixelStride: image.planes[0].bytesPerPixel ?? 4,
      srcW: image.width,
      srcH: image.height,
      rotation: rotation,
      mirror: mirror,
      maxEdge: _kFrameMaxEdge,
      params: _params, // 快照当前参数：滑块一动下一帧立刻生效
    );

    _frameBusy = true;
    _latestSentSeq = req.seq;
    _workerSend!.send(req);
  }

  /// 快门：先停流（Android 上 takePicture 与 imageStream 同时开会冲突），
  /// 拍下原始图，再对原始图应用当前参数并保存，最后恢复取景
  Future<void> _capture() async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized || _busy) {
      _toast('相机还没准备好');
      return;
    }
    setState(() => _busy = true);
    try {
      if (_cameraStreaming) {
        await c.stopImageStream();
        _cameraStreaming = false;
      }
      final XFile shot = await c.takePicture();
      _lastCapturePath = shot.path; // 原始文件，导出时仍可重新套参数
      final Uint8List raw = await File(shot.path).readAsBytes();
      final AdjustParams snapshot = _params;
      final Uint8List jpg = await processPhotoBytes(raw, snapshot);
      await _saveToGallery(jpg);
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('已拍照并保存到相册（$_kAlbumName）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('拍照失败：$e');
    } finally {
      // 恢复实时取景
      final CameraController? c2 = _controller;
      if (c2 != null && !_cameraStreaming && _mode == PreviewMode.camera) {
        try {
          await c2.startImageStream(_onCameraFrame);
          _cameraStreaming = true;
        } catch (_) {}
      }
    }
  }

  // ==========================================================================
  // 通用交互
  // ==========================================================================

  void _resetParams() {
    setState(() => _params = AdjustParams.neutral);
    _schedulePreviewRender();
    _toast('参数已重置');
  }

  void _toast(String text) {
    if (!mounted) return;
    final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ==========================================================================
  // UI
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ColorGrader 调色工坊', style: TextStyle(fontSize: 17)),
        centerTitle: true,
        backgroundColor: const Color(0xFF101114),
        actions: <Widget>[
          IconButton(
            tooltip: '模板列表',
            icon: const Icon(Icons.list_alt),
            onPressed: _showTemplateSheet,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(child: _buildPreview()),
            _buildModeBar(),
            _buildSliders(),
            _buildActions(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _mode == PreviewMode.camera ? _buildCameraView() : _buildAlbumView(),
          if (_busy)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 10),
                  Text(
                    '处理中…',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          Positioned(
            right: 8,
            top: 8,
            child: Row(
              children: <Widget>[
                if (_mode == PreviewMode.camera)
                  _miniButton(
                    icon: Icons.screen_rotation_alt,
                    tooltip: '画面方向校正（预览用）',
                    onTap: () => setState(
                      () => _rotationOffset = (_rotationOffset + 90) % 360,
                    ),
                  ),
                const SizedBox(width: 6),
                _miniButton(
                  icon: Icons.restart_alt,
                  tooltip: '重置全部参数',
                  onTap: _resetParams,
                ),
              ],
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  _mode == PreviewMode.camera ? '相机 · 实时滤镜' : '相簿 · 原图派生预览',
                  style: const TextStyle(fontSize: 10, color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumView() {
    final ui.Image? image = _previewImage;
    if (image == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.image_outlined, size: 42, color: Colors.white30),
            const SizedBox(height: 10),
            const Text(
              '点「相册导入」挑一张图片开始调色',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 6),
            TextButton(onPressed: _pickFromGallery, child: const Text('相册导入')),
          ],
        ),
      );
    }
    return RawImage(
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }

  Widget _buildCameraView() {
    final ui.Image? frame = _frameImage;
    if (frame == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            const Text(
              '正在启动取景器…',
              style: TextStyle(fontSize: 12, color: Colors.white54),
            ),
            if (!_cameraIniting && _controller == null)
              TextButton(onPressed: _initCamera, child: const Text('重试')),
          ],
        ),
      );
    }
    return RawImage(
      image: frame,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    );
  }

  Widget _miniButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 18, color: Colors.white70),
        ),
      ),
    );
  }

  Widget _buildModeBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SegmentedButton<PreviewMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll<TextStyle>(
                  TextStyle(fontSize: 12),
                ),
              ),
              segments: const <ButtonSegment<PreviewMode>>[
                ButtonSegment<PreviewMode>(
                  value: PreviewMode.album,
                  icon: Icon(Icons.image_outlined, size: 16),
                  label: Text('相簿图片'),
                ),
                ButtonSegment<PreviewMode>(
                  value: PreviewMode.camera,
                  icon: Icon(Icons.photo_camera_outlined, size: 16),
                  label: Text('摄像头取景'),
                ),
              ],
              selected: <PreviewMode>{_mode},
              onSelectionChanged: (Set<PreviewMode> v) => _switchMode(v.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliders() {
    return Container(
      height: 300,
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF17191E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _kSpecs.length,
        itemBuilder: (BuildContext c, int i) {
          final _ParamSpec spec = _kSpecs[i];
          return _ParamRow(
            spec: spec,
            value: spec.read(_params),
            onChanged: (double v) {
              setState(() => _params = spec.write(_params, v));
              _schedulePreviewRender();
            },
            onReset: () {
              setState(() => _params = spec.write(_params, 0));
              _schedulePreviewRender();
            },
          );
        },
      ),
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              _action(Icons.photo_library_outlined, '相册导入', _pickFromGallery),
              _action(
                Icons.flip_camera_android_outlined,
                '切换摄像头',
                _switchCamera,
              ),
              _action(
                Icons.camera_alt,
                '快门拍照',
                _mode == PreviewMode.camera
                    ? _capture
                    : _switchModeToCameraThenCapture,
                highlight: true,
              ),
              _action(Icons.download_outlined, '导出保存', _exportCurrent),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              _action(Icons.bookmark_add_outlined, '保存模板', _saveTemplateDialog),
              _action(Icons.list_alt, '模板列表', _showTemplateSheet),
              _action(Icons.settings_backup_restore, '重置参数', _resetParams),
              _action(Icons.info_outline, '使用说明', _showHelp),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _switchModeToCameraThenCapture() async {
    await _switchMode(PreviewMode.camera);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _capture();
  }

  Widget _action(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlight = false,
  }) {
    final Color fg = highlight ? const Color(0xFF9DB4FF) : Colors.white70;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 54,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: highlight
                ? const Color(0xFF23304F)
                : const Color(0xFF17191E),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 19, color: fg),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: 10.5, color: fg, height: 1.1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showHelp() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('使用说明'),
        content: const SingleChildScrollView(
          child: Text(
            '1. 相簿模式：导入图片后拖动滑块，或直接在右侧输入数值微调，'
            '预览由「原图缩略图」实时重算；'
            '点「导出保存」会重新读取原始文件、用当前参数算一遍，所以反复导出不会掉画质、'
            '也不会把调色叠起来。\n\n'
            '2. 相机模式：取景器每一帧都在后台 isolate 里套用当前参数，'
            '滑块一动画面立刻变化；按快门会先停流、拍下原始照片，'
            '再把整套参数应用到原始照片上保存。\n\n'
            '3. 模板分「内置预设」和「我的模板」：内置预设一键套用、不可删除；'
            '自定义模板只保存 10 个参数（JSON），不含任何图片，'
            '存放在应用沙盒的 templates/color_templates.json。\n\n'
            '4. 成片保存在系统相册的 $_kAlbumName 相簿里。',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

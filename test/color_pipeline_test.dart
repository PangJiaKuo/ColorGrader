// 调色管线单元测试：验证颜色数学在设备外也能跑通，且预览/导出共用同一套逻辑。
// 运行：flutter test

import 'dart:typed_data';

import 'package:color_grader/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一张 3x2 的 RGBA 测试图
Uint8List _makeRgba(List<List<int>> rgb) {
  final Uint8List px = Uint8List(rgb.length * 4);
  for (int i = 0; i < rgb.length; i++) {
    px[i * 4] = rgb[i][0];
    px[i * 4 + 1] = rgb[i][1];
    px[i * 4 + 2] = rgb[i][2];
    px[i * 4 + 3] = 255;
  }
  return px;
}

void main() {
  final List<List<int>> base = <List<int>>[
    <int>[10, 20, 30], // 暗
    <int>[128, 128, 128], // 中灰
    <int>[250, 240, 230], // 亮
    <int>[200, 50, 50],
    <int>[50, 200, 50],
    <int>[50, 50, 200],
  ];

  test('中性参数不改变任何像素（预览=原图）', () {
    final Uint8List px = _makeRgba(base);
    renderRgbaInPlace(px, 3, 2, AdjustParams.neutral);
    final Uint8List ref = _makeRgba(base);
    for (int i = 0; i < ref.length; i++) {
      expect(px[i], ref[i], reason: 'byte $i 被中性参数改动了');
    }
  });

  test('亮度 +100 提亮、-100 压暗，且 alpha 不变', () {
    final Uint8List up = _makeRgba(base);
    renderRgbaInPlace(up, 3, 2, AdjustParams.neutral.copyWith(brightness: 100));
    final Uint8List down = _makeRgba(base);
    renderRgbaInPlace(
      down,
      3,
      2,
      AdjustParams.neutral.copyWith(brightness: -100),
    );

    expect(up[0], greaterThan(base[0][0]));
    expect(down[0], lessThan(base[0][0]));
    for (int i = 3; i < up.length; i += 4) {
      expect(up[i], 255);
      expect(down[i], 255);
    }
  });

  test('饱和度 -100 得到纯灰（RGB 三通道相等）', () {
    final Uint8List px = _makeRgba(base);
    renderRgbaInPlace(
      px,
      3,
      2,
      AdjustParams.neutral.copyWith(saturation: -100),
    );
    for (int i = 0; i < px.length; i += 4) {
      expect(px[i], px[i + 1]);
      expect(px[i + 1], px[i + 2]);
    }
  });

  test('阴影只提亮暗部，高光只提亮亮部', () {
    // 暗像素索引 0，亮像素索引 2
    final Uint8List sh = _makeRgba(base);
    renderRgbaInPlace(sh, 3, 2, AdjustParams.neutral.copyWith(shadows: 100));
    final int darkGain = sh[0] - base[0][0];
    final int brightGain = sh[8] - base[2][0];
    expect(darkGain, greaterThan(brightGain), reason: '阴影权重应集中在暗部');

    final Uint8List hi = _makeRgba(base);
    renderRgbaInPlace(hi, 3, 2, AdjustParams.neutral.copyWith(highlights: 100));
    expect(
      hi[8] - base[2][0],
      greaterThan(hi[0] - base[0][0]),
      reason: '高光权重应集中在亮部',
    );
  });

  test('色温：正值偏暖（R↑ B↓），负值偏冷', () {
    final Uint8List warm = _makeRgba(base);
    renderRgbaInPlace(
      warm,
      3,
      2,
      AdjustParams.neutral.copyWith(temperature: 100),
    );
    expect(warm[4], greaterThan(base[1][0])); // R
    expect(warm[6], lessThan(base[1][2])); // B

    final Uint8List cool = _makeRgba(base);
    renderRgbaInPlace(
      cool,
      3,
      2,
      AdjustParams.neutral.copyWith(temperature: -100),
    );
    expect(cool[4], lessThan(base[1][0]));
    expect(cool[6], greaterThan(base[1][2]));
  });

  test('锐化：纯色块不应产生任何光晕/噪点', () {
    final List<List<int>> flat = List<List<int>>.generate(
      16,
      (_) => <int>[80, 80, 80],
    );
    final Uint8List px = _makeRgba(flat);
    applySharpen(px, 4, 4, 1.0);
    for (int i = 0; i < px.length; i += 4) {
      expect(px[i], 80);
    }
  });

  test('锐化：边缘对比被放大', () {
    // 4x3，左半暗右半亮（高度必须 >= 3，否则锐化直接跳过）
    final List<List<int>> edge = <List<int>>[
      for (int y = 0; y < 3; y++)
        for (int x = 0; x < 4; x++)
          x < 2 ? <int>[50, 50, 50] : <int>[200, 200, 200],
    ];
    final Uint8List px = _makeRgba(edge);
    final Uint8List before = Uint8List.fromList(px);
    applySharpen(px, 4, 3, 1.0);
    // 第 2 行跨边缘的第 1、2 个像素应被推得更开
    const int rowStart = 4 * 4; // y=1 起始字节
    expect(px[rowStart + 4], lessThan(before[rowStart + 4]));
    expect(px[rowStart + 8], greaterThan(before[rowStart + 8]));
    // 远离边缘的像素不应大幅变化
    expect(px[rowStart], 50);
    expect(px[rowStart + 12], 200);
  });

  test('参数 JSON 往返无损（模板只存 7 个数值）', () {
    const AdjustParams p = AdjustParams(
      brightness: 12,
      contrast: -34,
      saturation: 56,
      temperature: 7,
      sharpen: 88,
      highlights: -9,
      shadows: 41,
    );
    final AdjustParams back = AdjustParams.fromJson(p.toJson());
    expect(back, p);
    expect(p.toJson().length, 7);
  });

  test('相机帧渲染：旋转 90 会交换输出宽高，且不崩', () {
    // 造一个 8x4 的假 YUV420 帧（Y 全 128，UV 全 128 → 灰色）
    const int w = 8;
    const int h = 4;
    final FrameRequest req = FrameRequest(
      seq: 1,
      isBgra: false,
      yPlane: Uint8List(w * h)..fillRange(0, w * h, 128),
      uPlane: Uint8List(w ~/ 2 * (h ~/ 2))
        ..fillRange(0, w ~/ 2 * (h ~/ 2), 128),
      vPlane: Uint8List(w ~/ 2 * (h ~/ 2))
        ..fillRange(0, w ~/ 2 * (h ~/ 2), 128),
      yRowStride: w,
      yPixelStride: 1,
      uvRowStride: w ~/ 2,
      uvPixelStride: 1,
      vRowStride: w ~/ 2,
      vPixelStride: 1,
      bgraRowStride: 0,
      bgraPixelStride: 4,
      srcW: w,
      srcH: h,
      rotation: 90,
      mirror: false,
      maxEdge: 480,
      params: AdjustParams.neutral,
    );
    final FrameResponse res = renderCameraFrame(req);
    expect(res.error, isNull);
    expect(res.width, h); // 90° 旋转后宽高互换
    expect(res.height, w);
    expect(res.rgba.length, res.width * res.height * 4);
    // 中性参数下 128 的 YUV 应还原成接近 128 的灰
    expect(res.rgba[0], inInclusiveRange(120, 136));
    expect(res.rgba[3], 255);
  });
}

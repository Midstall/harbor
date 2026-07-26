import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _absd(int a, int b) => (a - b).abs();
int _clampS8(int x) => x < -128 ? -128 : (x > 127 ? 127 : x);

// libaom filter4 (narrow). px = [p3,p2,p1,p0,q0,q1,q2,q3]. Returns the inner
// four [op1, op0, oq0, oq1].
List<int> _filter4(List<int> px, int blimit, int limit, int thresh) {
  final p3 = px[0], p2 = px[1], p1 = px[2], p0 = px[3];
  final q0 = px[4], q1 = px[5], q2 = px[6], q3 = px[7];
  var mask = true;
  if (_absd(p3, p2) > limit) mask = false;
  if (_absd(p2, p1) > limit) mask = false;
  if (_absd(p1, p0) > limit) mask = false;
  if (_absd(q1, q0) > limit) mask = false;
  if (_absd(q2, q1) > limit) mask = false;
  if (_absd(q3, q2) > limit) mask = false;
  if (_absd(p0, q0) * 2 + (_absd(p1, q1) >> 1) > blimit) mask = false;
  if (!mask) return [p1, p0, q0, q1];
  final hev = _absd(p1, p0) > thresh || _absd(q1, q0) > thresh;
  final ps1 = p1 - 128, ps0 = p0 - 128, qs0 = q0 - 128, qs1 = q1 - 128;
  var filter = hev ? _clampS8(ps1 - qs1) : 0;
  filter = _clampS8(filter + 3 * (qs0 - ps0));
  final filter1 = _clampS8(filter + 4) >> 3;
  final filter2 = _clampS8(filter + 3) >> 3;
  final oq0 = _clampS8(qs0 - filter1) + 128;
  final op0 = _clampS8(ps0 + filter2) + 128;
  final f = hev ? 0 : (filter1 + 1) >> 1;
  final oq1 = _clampS8(qs1 - f) + 128;
  final op1 = _clampS8(ps1 + f) + 128;
  return [op1, op0, oq0, oq1];
}

List<List<int>> _deblock(
  List<List<int>> frame,
  int w,
  int h,
  int bl,
  int lim,
  int th,
) {
  final g = [
    for (final row in frame) [...row],
  ];
  // Vertical edges, in place, left to right.
  for (var x = 4; x < w; x += 4) {
    for (var y = 0; y < h; y++) {
      final line = [for (var k = -4; k < 4; k++) g[y][x + k]];
      final r = _filter4(line, bl, lim, th);
      g[y][x - 2] = r[0];
      g[y][x - 1] = r[1];
      g[y][x] = r[2];
      g[y][x + 1] = r[3];
    }
  }
  // Horizontal edges, reading the vertical result, writing a fresh grid.
  final g2 = [
    for (final row in g) [...row],
  ];
  for (var y = 4; y < h; y += 4) {
    for (var x = 0; x < w; x++) {
      final line = [for (var k = -4; k < 4; k++) g[y + k][x]];
      final r = _filter4(line, bl, lim, th);
      g2[y - 2][x] = r[0];
      g2[y - 1][x] = r[1];
      g2[y][x] = r[2];
      g2[y + 1][x] = r[3];
    }
  }
  return g2;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDeblockFramePass', () {
    test('deblocks a 12x12 frame with block-edge steps', () async {
      const w = 12, h = 12, bl = 32, lim = 8, th = 4;
      final p = HarborDeblockFramePass(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;
      final frame = Logic(name: 'frame', width: w * h * 8);
      final blimit = Logic(name: 'blimit', width: 8);
      final limit = Logic(name: 'limit', width: 8);
      final thresh = Logic(name: 'thresh', width: 8);
      final flatThresh = Logic(name: 'flat_thresh', width: 8);
      p.input('frame').srcConnection! <= frame;
      p.input('blimit').srcConnection! <= blimit;
      p.input('limit').srcConnection! <= limit;
      p.input('thresh').srcConnection! <= thresh;
      p.input('flat_thresh').srcConnection! <= flatThresh;
      await p.build();

      // A frame of 4x4 blocks each a smooth gradient, with a step between
      // blocks so the deblock filter activates.
      final img = [
        for (var y = 0; y < h; y++)
          [
            for (var x = 0; x < w; x++)
              (100 + (x ~/ 4) * 12 + (y ~/ 4) * 9 + (x % 4) + (y % 4)) & 0xFF,
          ],
      ];
      var fv = BigInt.zero;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          fv |= BigInt.from(img[y][x] & 0xFF) << ((y * w + x) * 8);
        }
      }

      frame.inject(fv);
      blimit.inject(bl);
      limit.inject(lim);
      thresh.inject(th);
      flatThresh.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;

      final exp = _deblock(img, w, h, bl, lim, th);
      final v = p.output('out').value.toBigInt();
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final got = ((v >> ((y * w + x) * 8)) & BigInt.from(0xFF)).toInt();
          expect(got, equals(exp[y][x]), reason: '($y,$x)');
        }
      }
      await Simulator.endSimulation();
    });

    test('stress: pseudo-random frames at thresholds 53/9/1', () async {
      const w = 12, h = 12, bl = 53, lim = 9, th = 1;
      final p = HarborDeblockFramePass(width: w, height: h);
      final clk = SimpleClockGenerator(10).clk;
      final frame = Logic(name: 'frame', width: w * h * 8);
      final blimit = Logic(name: 'blimit', width: 8);
      final limit = Logic(name: 'limit', width: 8);
      final thresh = Logic(name: 'thresh', width: 8);
      final flatThresh = Logic(name: 'flat_thresh', width: 8);
      p.input('frame').srcConnection! <= frame;
      p.input('blimit').srcConnection! <= blimit;
      p.input('limit').srcConnection! <= limit;
      p.input('thresh').srcConnection! <= thresh;
      p.input('flat_thresh').srcConnection! <= flatThresh;
      await p.build();
      blimit.inject(bl);
      limit.inject(lim);
      thresh.inject(th);
      flatThresh.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());

      for (var t = 0; t < 8; t++) {
        final img = [
          for (var y = 0; y < h; y++)
            [
              for (var x = 0; x < w; x++)
                (x * 13 + y * 29 + t * 101 + 60) & 0xFF,
            ],
        ];
        var fv = BigInt.zero;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            fv |= BigInt.from(img[y][x]) << ((y * w + x) * 8);
          }
        }
        frame.inject(fv);
        await clk.nextPosedge;
        final exp = _deblock(img, w, h, bl, lim, th);
        final v = p.output('out').value.toBigInt();
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            final got = ((v >> ((y * w + x) * 8)) & BigInt.from(0xFF)).toInt();
            expect(got, equals(exp[y][x]), reason: 't$t ($y,$x)');
          }
        }
      }
      await Simulator.endSimulation();
    });
  });
}

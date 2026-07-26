import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _absd(int a, int b) => (a - b).abs();
int _clampS8(int x) => x < -128 ? -128 : (x > 127 ? 127 : x);

// Reference single-line loop filter (filter4/filter8), returns the 6 inner
// pixels [op2,op1,op0,oq0,oq1,oq2].
List<int> _filter(List<int> px, int blimit, int limit, int thresh, int ft) {
  final p3 = px[0], p2 = px[1], p1 = px[2], p0 = px[3];
  final q0 = px[4], q1 = px[5], q2 = px[6], q3 = px[7];
  var nf = false;
  if (_absd(p3, p2) > limit) nf = true;
  if (_absd(p2, p1) > limit) nf = true;
  if (_absd(p1, p0) > limit) nf = true;
  if (_absd(q1, q0) > limit) nf = true;
  if (_absd(q2, q1) > limit) nf = true;
  if (_absd(q3, q2) > limit) nf = true;
  if (_absd(p0, q0) * 2 + (_absd(p1, q1) >> 1) > blimit) nf = true;
  final mask = !nf;
  final hev = _absd(p1, p0) > thresh || _absd(q1, q0) > thresh;
  final flat =
      _absd(p1, p0) <= ft &&
      _absd(q1, q0) <= ft &&
      _absd(p2, p0) <= ft &&
      _absd(q2, q0) <= ft &&
      _absd(p3, p0) <= ft &&
      _absd(q3, q0) <= ft;
  int r3(int s) => (s + 4) >> 3;
  if (mask && flat) {
    return [
      r3(3 * p3 + 2 * p2 + p1 + p0 + q0),
      r3(2 * p3 + p2 + 2 * p1 + p0 + q0 + q1),
      r3(p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2),
      r3(p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3),
      r3(p1 + p0 + q0 + 2 * q1 + q2 + 2 * q3),
      r3(p0 + q0 + q1 + 2 * q2 + 3 * q3),
    ];
  }
  var op1 = p1, op0 = p0, oq0 = q0, oq1 = q1;
  if (mask) {
    final ps1 = p1 - 128, ps0 = p0 - 128, qs0 = q0 - 128, qs1 = q1 - 128;
    var filter = hev ? _clampS8(ps1 - qs1) : 0;
    filter = _clampS8(filter + 3 * (qs0 - ps0));
    final f1 = _clampS8(filter + 4) >> 3;
    final f2 = _clampS8(filter + 3) >> 3;
    oq0 = _clampS8(qs0 - f1) + 128;
    op0 = _clampS8(ps0 + f2) + 128;
    final f = hev ? 0 : (f1 + 1) >> 1;
    oq1 = _clampS8(qs1 - f) + 128;
    op1 = _clampS8(ps1 + f) + 128;
  }
  return [p2, op1, op0, oq0, oq1, q2];
}

// Reference 8x8 frame deblock: vertical edge (cols 3|4) every row, then the
// horizontal edge (rows 3|4) every column.
List<int> _frameDeblock(
  List<int> frame,
  int blimit,
  int limit,
  int thresh,
  int ft,
) {
  final inter = List<int>.from(frame);
  for (var r = 0; r < 8; r++) {
    final line = [for (var c = 0; c < 8; c++) frame[r * 8 + c]];
    final f = _filter(line, blimit, limit, thresh, ft);
    for (var k = 0; k < 6; k++) {
      inter[r * 8 + 1 + k] = f[k];
    }
  }
  final out = List<int>.from(inter);
  for (var c = 0; c < 8; c++) {
    final line = [for (var r = 0; r < 8; r++) inter[r * 8 + c]];
    final f = _filter(line, blimit, limit, thresh, ft);
    for (var k = 0; k < 6; k++) {
      out[(1 + k) * 8 + c] = f[k];
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborFrameDeblock', () {
    test('deblocks an 8x8 frame (vertical then horizontal edges)', () async {
      final fd = HarborFrameDeblock();
      final clk = SimpleClockGenerator(10).clk;
      final frame = Logic(name: 'frame', width: 512);
      final blimit = Logic(name: 'blimit', width: 8);
      final limit = Logic(name: 'limit', width: 8);
      final thresh = Logic(name: 'thresh', width: 8);
      final flatThresh = Logic(name: 'flat_thresh', width: 8);

      fd.input('frame').srcConnection! <= frame;
      fd.input('blimit').srcConnection! <= blimit;
      fd.input('limit').srcConnection! <= limit;
      fd.input('thresh').srcConnection! <= thresh;
      fd.input('flat_thresh').srcConnection! <= flatThresh;

      await fd.build();

      // A frame with a block-boundary step at the col-3/4 and row-3/4 edges.
      final pix = [
        for (var r = 0; r < 8; r++)
          for (var c = 0; c < 8; c++)
            ((r < 4 ? 100 : 120) + (c < 4 ? 0 : 14) + r + c) & 0xFF,
      ];
      var fv = BigInt.zero;
      for (var i = 0; i < 64; i++) {
        fv |= BigInt.from(pix[i] & 0xFF) << (i * 8);
      }

      frame.inject(fv);
      blimit.inject(80);
      limit.inject(24);
      thresh.inject(8);
      flatThresh.inject(2);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;

      final v = fd.output('out').value.toBigInt();
      final got = [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
      final expected = _frameDeblock(pix, 80, 24, 8, 2);
      expect(got, equals(expected));
      await Simulator.endSimulation();
    });
  });
}

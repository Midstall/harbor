import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _absd(int a, int b) => (a - b).abs();
int _clampS8(int x) => x < -128 ? -128 : (x > 127 ? 127 : x);

// Reference VP9/AV1 loop filter (libaom filter4/filter8 + filter/flat/hev masks).
// px = [p3,p2,p1,p0,q0,q1,q2,q3], returns [op2,op1,op0,oq0,oq1,oq2].
List<int> _filter(List<int> px, int blimit, int limit, int thresh, int ft) {
  final p3 = px[0], p2 = px[1], p1 = px[2], p0 = px[3];
  final q0 = px[4], q1 = px[5], q2 = px[6], q3 = px[7];

  var notFilter = false;
  if (_absd(p3, p2) > limit) notFilter = true;
  if (_absd(p2, p1) > limit) notFilter = true;
  if (_absd(p1, p0) > limit) notFilter = true;
  if (_absd(q1, q0) > limit) notFilter = true;
  if (_absd(q2, q1) > limit) notFilter = true;
  if (_absd(q3, q2) > limit) notFilter = true;
  if (_absd(p0, q0) * 2 + (_absd(p1, q1) >> 1) > blimit) notFilter = true;
  final mask = !notFilter;
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
    final filter1 = _clampS8(filter + 4) >> 3;
    final filter2 = _clampS8(filter + 3) >> 3;
    oq0 = _clampS8(qs0 - filter1) + 128;
    op0 = _clampS8(ps0 + filter2) + 128;
    final f = hev ? 0 : (filter1 + 1) >> 1;
    oq1 = _clampS8(qs1 - f) + 128;
    op1 = _clampS8(ps1 + f) + 128;
  }
  return [p2, op1, op0, oq0, oq1, q2];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDeblockFilter', () {
    late HarborDeblockFilter flt;
    late Logic clk, line, blimit, limit, thresh, flatThresh;

    Future<void> setUpDut() async {
      flt = HarborDeblockFilter();
      clk = SimpleClockGenerator(10).clk;
      line = Logic(name: 'line', width: 64);
      blimit = Logic(name: 'blimit', width: 8);
      limit = Logic(name: 'limit', width: 8);
      thresh = Logic(name: 'thresh', width: 8);
      flatThresh = Logic(name: 'flat_thresh', width: 8);
      flt.input('line').srcConnection! <= line;
      flt.input('blimit').srcConnection! <= blimit;
      flt.input('limit').srcConnection! <= limit;
      flt.input('thresh').srcConnection! <= thresh;
      flt.input('flat_thresh').srcConnection! <= flatThresh;
      await flt.build();
      line.inject(0);
      blimit.inject(0);
      limit.inject(0);
      thresh.inject(0);
      flatThresh.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packLine(List<int> px) {
      var v = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        v |= BigInt.from(px[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    List<int> readFiltered() {
      final v = flt.output('filtered').value.toInt();
      return [for (var i = 0; i < 6; i++) (v >> (i * 8)) & 0xFF];
    }

    // (name, line, blimit, limit, thresh, flat_thresh)
    final cases = <(String, List<int>, int, int, int, int)>[
      (
        'smooth step (filter4)',
        [98, 100, 101, 103, 116, 118, 119, 121],
        40,
        12,
        4,
        1,
      ),
      ('hard edge masked', [40, 42, 44, 46, 200, 202, 204, 206], 16, 8, 4, 1),
      (
        'hev edge (filter4)',
        [90, 92, 95, 100, 130, 135, 137, 139],
        60,
        30,
        4,
        1,
      ),
      (
        'flat region (filter8)',
        [124, 125, 125, 126, 130, 131, 131, 132],
        60,
        16,
        4,
        4,
      ),
      ('gentle ramp (filter4)', [60, 64, 68, 72, 80, 84, 88, 92], 80, 20, 6, 1),
      (
        'flat step (filter8)',
        [118, 119, 120, 120, 136, 136, 137, 138],
        80,
        24,
        8,
        3,
      ),
    ];

    for (final c in cases) {
      test('matches the reference: ${c.$1}', () async {
        await setUpDut();
        line.inject(packLine(c.$2));
        blimit.inject(c.$3);
        limit.inject(c.$4);
        thresh.inject(c.$5);
        flatThresh.inject(c.$6);
        await clk.nextPosedge;

        final got = readFiltered();
        final expected = _filter(c.$2, c.$3, c.$4, c.$5, c.$6);
        expect(got, equals(expected), reason: c.$1);
        await Simulator.endSimulation();
      });
    }
  });
}

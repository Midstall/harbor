import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int _absd(int a, int b) => (a - b).abs();
int _clampS8(int x) => x < -128 ? -128 : (x > 127 ? 127 : x);

(int, int, int) _limits(int lvl, int sharpness) {
  var bil = sharpness != 0 ? lvl >> (1 + (sharpness > 4 ? 1 : 0)) : lvl;
  final cap = 9 - sharpness;
  if (bil > cap) bil = cap;
  if (bil < 1) bil = 1;
  return (2 * (lvl + 2) + bil, bil, lvl >> 4);
}

// libaom filter4/filter8 reference: px=[p3,p2,p1,p0,q0,q1,q2,q3] ->
// [op2,op1,op0,oq0,oq1,oq2].
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

List<int> _edge(List<int> px, int level, int sharpness, int ft) {
  // The unit derives thresholds and always runs the filter, a level of 0 yields
  // limit=1/blimit=5/thresh=0 so the mask rejects all but near-flat edges
  // (callers gate the whole edge on level != 0).
  final (blimit, limit, thresh) = _limits(level, sharpness);
  return _filter(px, blimit, limit, thresh, ft);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborDeblockEdge', () {
    late HarborDeblockEdge de;
    late Logic clk, line, level, sharp, flatThresh;

    Future<void> setUpDut() async {
      de = HarborDeblockEdge();
      clk = SimpleClockGenerator(10).clk;
      line = Logic(name: 'line', width: 64);
      level = Logic(name: 'filter_level', width: 6);
      sharp = Logic(name: 'sharpness', width: 3);
      flatThresh = Logic(name: 'flat_thresh', width: 8);
      de.input('line').srcConnection! <= line;
      de.input('filter_level').srcConnection! <= level;
      de.input('sharpness').srcConnection! <= sharp;
      de.input('flat_thresh').srcConnection! <= flatThresh;
      await de.build();
      line.inject(0);
      level.inject(0);
      sharp.inject(0);
      flatThresh.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt packLine(List<int> p) {
      var v = BigInt.zero;
      for (var i = 0; i < 8; i++) {
        v |= BigInt.from(p[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    // (name, px, level, sharpness, flat_thresh).
    final cases = <(String, List<int>, int, int, int)>[
      ('level 0 = passthrough', [50, 60, 70, 80, 130, 140, 150, 160], 0, 0, 1),
      ('smooth step strong', [70, 74, 78, 82, 120, 124, 128, 132], 32, 0, 1),
      ('mid level sharp 3', [70, 74, 78, 82, 120, 124, 128, 132], 16, 3, 1),
      ('flat region wide', [100, 101, 100, 102, 103, 102, 101, 100], 24, 0, 4),
      ('high level sharp 7', [40, 60, 90, 110, 115, 95, 70, 45], 50, 7, 1),
      ('big gradient masked off', [10, 80, 30, 200, 5, 240, 60, 120], 20, 0, 1),
    ];

    for (final c in cases) {
      test('matches limits+filter: ${c.$1}', () async {
        await setUpDut();
        line.inject(packLine(c.$2));
        level.inject(c.$3);
        sharp.inject(c.$4);
        flatThresh.inject(c.$5);
        await clk.nextPosedge;
        final v = de.output('filtered').value.toBigInt();
        final got = [
          for (var i = 0; i < 6; i++)
            ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
        ];
        expect(got, equals(_edge(c.$2, c.$3, c.$4, c.$5)), reason: c.$1);
        await Simulator.endSimulation();
      });
    }
  });
}

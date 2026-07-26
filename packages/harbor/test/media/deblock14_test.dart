import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 deblock WIDEST (filter14) luma edge filter, vs a golden
// mirroring libaom filter_mask + flat_mask4 + flat2 + filter14 (with the
// filter8/filter4 fallbacks).
int _scc(int x) => x.clamp(-128, 127);
int _rp(int v, int n) => (v + (1 << (n - 1))) >> n;

bool _mask(
  int limit,
  int blimit,
  int p3,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int q3,
) {
  var m = 0;
  if ((p3 - p2).abs() > limit) m = -1;
  if ((p2 - p1).abs() > limit) m = -1;
  if ((p1 - p0).abs() > limit) m = -1;
  if ((q1 - q0).abs() > limit) m = -1;
  if ((q2 - q1).abs() > limit) m = -1;
  if ((q3 - q2).abs() > limit) m = -1;
  if ((p0 - q0).abs() * 2 + (p1 - q1).abs() ~/ 2 > blimit) m = -1;
  return ((~m) & 0xFF) != 0;
}

bool _flat4(int p3, int p2, int p1, int p0, int q0, int q1, int q2, int q3) {
  const t = 1;
  var m = 0;
  if ((p1 - p0).abs() > t) m = -1;
  if ((q1 - q0).abs() > t) m = -1;
  if ((p2 - p0).abs() > t) m = -1;
  if ((q2 - q0).abs() > t) m = -1;
  if ((p3 - p0).abs() > t) m = -1;
  if ((q3 - q0).abs() > t) m = -1;
  return ((~m) & 0xFF) != 0;
}

List<int> _filter4(bool maskOn, int thresh, int p1, int p0, int q0, int q1) {
  final ps1 = p1 - 128, ps0 = p0 - 128, qs0 = q0 - 128, qs1 = q1 - 128;
  final hevOn = (p1 - p0).abs() > thresh || (q1 - q0).abs() > thresh;
  var filter = hevOn ? _scc(ps1 - qs1) : 0;
  filter = maskOn ? _scc(filter + 3 * (qs0 - ps0)) : 0;
  final filter1 = _scc(filter + 4) >> 3;
  final filter2 = _scc(filter + 3) >> 3;
  final oq0 = _scc(qs0 - filter1) + 128;
  final op0 = _scc(ps0 + filter2) + 128;
  final f = hevOn ? 0 : _rp(filter1, 1);
  final oq1 = _scc(qs1 - f) + 128;
  final op1 = _scc(ps1 + f) + 128;
  return [op1, op0, oq0, oq1];
}

// returns full 14-sample row op6..oq6.
List<int> golden(List<int> s, int limit, int blimit, int thresh) {
  final p6 = s[0],
      p5 = s[1],
      p4 = s[2],
      p3 = s[3],
      p2 = s[4],
      p1 = s[5],
      p0 = s[6];
  final q0 = s[7],
      q1 = s[8],
      q2 = s[9],
      q3 = s[10],
      q4 = s[11],
      q5 = s[12],
      q6 = s[13];
  final maskOn = _mask(limit, blimit, p3, p2, p1, p0, q0, q1, q2, q3);
  final flat = _flat4(p3, p2, p1, p0, q0, q1, q2, q3);
  final flat2 = _flat4(p6, p5, p4, p0, q0, q4, q5, q6);

  final out = List<int>.from(s);
  if (flat2 && flat && maskOn) {
    out[1] = _rp(p6 * 7 + p5 * 2 + p4 * 2 + p3 + p2 + p1 + p0 + q0, 4);
    out[2] = _rp(p6 * 5 + p5 * 2 + p4 * 2 + p3 * 2 + p2 + p1 + p0 + q0 + q1, 4);
    out[3] = _rp(
      p6 * 4 + p5 + p4 * 2 + p3 * 2 + p2 * 2 + p1 + p0 + q0 + q1 + q2,
      4,
    );
    out[4] = _rp(
      p6 * 3 + p5 + p4 + p3 * 2 + p2 * 2 + p1 * 2 + p0 + q0 + q1 + q2 + q3,
      4,
    );
    out[5] = _rp(
      p6 * 2 + p5 + p4 + p3 + p2 * 2 + p1 * 2 + p0 * 2 + q0 + q1 + q2 + q3 + q4,
      4,
    );
    out[6] = _rp(
      p6 +
          p5 +
          p4 +
          p3 +
          p2 +
          p1 * 2 +
          p0 * 2 +
          q0 * 2 +
          q1 +
          q2 +
          q3 +
          q4 +
          q5,
      4,
    );
    out[7] = _rp(
      p5 +
          p4 +
          p3 +
          p2 +
          p1 +
          p0 * 2 +
          q0 * 2 +
          q1 * 2 +
          q2 +
          q3 +
          q4 +
          q5 +
          q6,
      4,
    );
    out[8] = _rp(
      p4 + p3 + p2 + p1 + p0 + q0 * 2 + q1 * 2 + q2 * 2 + q3 + q4 + q5 + q6 * 2,
      4,
    );
    out[9] = _rp(
      p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 * 2 + q3 * 2 + q4 + q5 + q6 * 3,
      4,
    );
    out[10] = _rp(
      p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 * 2 + q4 * 2 + q5 + q6 * 4,
      4,
    );
    out[11] = _rp(
      p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 * 2 + q5 * 2 + q6 * 5,
      4,
    );
    out[12] = _rp(p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 * 2 + q6 * 7, 4);
    return out;
  }
  // filter8 fallback.
  if (flat && maskOn) {
    out[4] = _rp(p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0, 3);
    out[5] = _rp(p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1, 3);
    out[6] = _rp(p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2, 3);
    out[7] = _rp(p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3, 3);
    out[8] = _rp(p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3, 3);
    out[9] = _rp(p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3, 3);
    return out;
  }
  final f4 = _filter4(maskOn, thresh, p1, p0, q0, q1);
  out[5] = f4[0];
  out[6] = f4[1];
  out[7] = f4[2];
  out[8] = f4[3];
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborDeblock14 matches libaom filter14', () async {
    final t = HarborDeblock14();
    final clk = SimpleClockGenerator(10).clk;
    const names = [
      'p6', 'p5', 'p4', 'p3', 'p2', 'p1', 'p0', //
      'q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6',
    ];
    final pins = <String, Logic>{};
    for (final n in [...names, 'limit', 'blimit', 'thresh']) {
      final l = Logic(name: n, width: 8);
      pins[n] = l;
      t.input(n).srcConnection! <= l;
    }
    await t.build();
    Simulator.setMaxSimTime(80000000);
    unawaited(Simulator.run());

    final rng = Random(0xDEB14);
    const outs = [
      'op6', 'op5', 'op4', 'op3', 'op2', 'op1', 'op0', //
      'oq0', 'oq1', 'oq2', 'oq3', 'oq4', 'oq5', 'oq6',
    ];
    for (var iter = 0; iter < 4000; iter++) {
      final flatRow = iter % 2 == 0;
      final base = rng.nextInt(240) + 8;
      final s = List<int>.generate(14, (_) {
        if (!flatRow) return rng.nextInt(256);
        return (base + rng.nextInt(5) - 2).clamp(0, 255);
      });
      final lim = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      final bli = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(80);
      final thr = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      for (var i = 0; i < 14; i++) {
        pins[names[i]]!.put(s[i]);
      }
      pins['limit']!.put(lim);
      pins['blimit']!.put(bli);
      pins['thresh']!.put(thr);
      await clk.nextPosedge;

      final want = golden(s, lim, bli, thr);
      final got = [for (final o in outs) t.output(o).value.toInt()];
      expect(got, equals(want), reason: 'iter=$iter s=$s l=$lim b=$bli t=$thr');
    }
    await Simulator.endSimulation();
  });
}

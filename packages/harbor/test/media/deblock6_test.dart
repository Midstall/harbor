import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 deblock chroma WIDE (filter6) edge filter, vs a golden
// mirroring libaom filter_mask3_chroma + flat_mask3_chroma(thresh=1) + filter6
// (5-tap [1,2,2,2,1], else filter4).
int _scc(int x) => x.clamp(-128, 127);
int _rp(int v, int n) => (v + (1 << (n - 1))) >> n;

bool _mask(
  int limit,
  int blimit,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
) {
  var m = 0;
  if ((p2 - p1).abs() > limit) m = -1;
  if ((p1 - p0).abs() > limit) m = -1;
  if ((q1 - q0).abs() > limit) m = -1;
  if ((q2 - q1).abs() > limit) m = -1;
  if ((p0 - q0).abs() * 2 + (p1 - q1).abs() ~/ 2 > blimit) m = -1;
  return ((~m) & 0xFF) != 0;
}

bool _flat(int p2, int p1, int p0, int q0, int q1, int q2) {
  const t = 1;
  var m = 0;
  if ((p1 - p0).abs() > t) m = -1;
  if ((q1 - q0).abs() > t) m = -1;
  if ((p2 - p0).abs() > t) m = -1;
  if ((q2 - q0).abs() > t) m = -1;
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

// returns [op2, op1, op0, oq0, oq1, oq2]
List<int> golden(
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int limit,
  int blimit,
  int thresh,
) {
  final maskOn = _mask(limit, blimit, p2, p1, p0, q0, q1, q2);
  final flat = _flat(p2, p1, p0, q0, q1, q2);
  if (flat && maskOn) {
    final op1 = _rp(p2 * 3 + p1 * 2 + p0 * 2 + q0, 3);
    final op0 = _rp(p2 + p1 * 2 + p0 * 2 + q0 * 2 + q1, 3);
    final oq0 = _rp(p1 + p0 * 2 + q0 * 2 + q1 * 2 + q2, 3);
    final oq1 = _rp(p0 + q0 * 2 + q1 * 2 + q2 * 3, 3);
    return [p2, op1, op0, oq0, oq1, q2];
  }
  final f4 = _filter4(maskOn, thresh, p1, p0, q0, q1);
  return [p2, f4[0], f4[1], f4[2], f4[3], q2];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborDeblock6 matches libaom filter6', () async {
    final t = HarborDeblock6();
    final clk = SimpleClockGenerator(10).clk;
    const names = ['p2', 'p1', 'p0', 'q0', 'q1', 'q2'];
    final pins = <String, Logic>{};
    for (final n in [...names, 'limit', 'blimit', 'thresh']) {
      final l = Logic(name: n, width: 8);
      pins[n] = l;
      t.input(n).srcConnection! <= l;
    }
    await t.build();
    Simulator.setMaxSimTime(60000000);
    unawaited(Simulator.run());

    final rng = Random(0xDEB6);
    const outs = ['op2', 'op1', 'op0', 'oq0', 'oq1', 'oq2'];
    for (var iter = 0; iter < 3000; iter++) {
      final flatRow = iter % 2 == 0;
      final base = rng.nextInt(240) + 8;
      final s = List<int>.generate(6, (_) {
        if (!flatRow) return rng.nextInt(256);
        return (base + rng.nextInt(5) - 2).clamp(0, 255);
      });
      final lim = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      final bli = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(80);
      final thr = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      for (var i = 0; i < 6; i++) {
        pins[names[i]]!.put(s[i]);
      }
      pins['limit']!.put(lim);
      pins['blimit']!.put(bli);
      pins['thresh']!.put(thr);
      await clk.nextPosedge;

      final want = golden(s[0], s[1], s[2], s[3], s[4], s[5], lim, bli, thr);
      final got = [for (final o in outs) t.output(o).value.toInt()];
      expect(got, equals(want), reason: 'iter=$iter s=$s l=$lim b=$bli t=$thr');
    }
    await Simulator.endSimulation();
  });
}

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 deblock WIDE (filter8) luma edge filter, vs a golden mirroring
// libaom filter_mask + flat_mask4(thresh=1) + filter8 (7-tap, else filter4).
int _scc(int x) => x.clamp(-128, 127);
int _rp(int v, int n) => (v + (1 << (n - 1))) >> n;

bool _filterMask(
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

bool _flatMask4(
  int p3,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int q3,
) {
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

// returns [op3, op2, op1, op0, oq0, oq1, oq2, oq3]
List<int> golden(
  int p3,
  int p2,
  int p1,
  int p0,
  int q0,
  int q1,
  int q2,
  int q3,
  int limit,
  int blimit,
  int thresh,
) {
  final maskOn = _filterMask(limit, blimit, p3, p2, p1, p0, q0, q1, q2, q3);
  final flat = _flatMask4(p3, p2, p1, p0, q0, q1, q2, q3);
  if (flat && maskOn) {
    final op2 = _rp(p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0, 3);
    final op1 = _rp(p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1, 3);
    final op0 = _rp(p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2, 3);
    final oq0 = _rp(p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3, 3);
    final oq1 = _rp(p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3, 3);
    final oq2 = _rp(p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3, 3);
    return [p3, op2, op1, op0, oq0, oq1, oq2, q3];
  }
  final f4 = _filter4(maskOn, thresh, p1, p0, q0, q1);
  return [p3, p2, f4[0], f4[1], f4[2], f4[3], q2, q3];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborDeblock8 matches libaom filter8', () async {
    final t = HarborDeblock8();
    final clk = SimpleClockGenerator(10).clk;
    final pins = <String, Logic>{};
    for (final n in [
      'p3', 'p2', 'p1', 'p0', 'q0', 'q1', 'q2', 'q3', //
      'limit', 'blimit', 'thresh',
    ]) {
      final l = Logic(name: n, width: 8);
      pins[n] = l;
      t.input(n).srcConnection! <= l;
    }
    await t.build();
    Simulator.setMaxSimTime(40000000);
    unawaited(Simulator.run());

    final rng = Random(0xDEB8);
    for (var iter = 0; iter < 3000; iter++) {
      // Bias toward flat regions (cluster around a base) so the wide kernel
      // fires often, but also throw in fully random rows.
      final flatRow = iter % 2 == 0;
      int s() {
        if (!flatRow) return rng.nextInt(256);
        final base = rng.nextInt(240) + 8;
        return (base + rng.nextInt(5) - 2).clamp(0, 255);
      }

      final v = {
        'p3': s(),
        'p2': s(),
        'p1': s(),
        'p0': s(),
        'q0': s(),
        'q1': s(),
        'q2': s(),
        'q3': s(),
        'limit': iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40),
        'blimit': iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(80),
        'thresh': iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40),
      };
      v.forEach((k, val) => pins[k]!.put(val));
      await clk.nextPosedge;

      final want = golden(
        v['p3']!,
        v['p2']!,
        v['p1']!,
        v['p0']!,
        v['q0']!,
        v['q1']!,
        v['q2']!,
        v['q3']!,
        v['limit']!,
        v['blimit']!,
        v['thresh']!,
      );
      final got = [
        t.output('op3').value.toInt(),
        t.output('op2').value.toInt(),
        t.output('op1').value.toInt(),
        t.output('op0').value.toInt(),
        t.output('oq0').value.toInt(),
        t.output('oq1').value.toInt(),
        t.output('oq2').value.toInt(),
        t.output('oq3').value.toInt(),
      ];
      expect(got, equals(want), reason: 'iter=$iter v=$v');
    }
    await Simulator.endSimulation();
  });
}

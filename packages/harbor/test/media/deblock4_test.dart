import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact AV1 deblock narrow (filter4) edge filter, vs a golden mirroring
// libaom filter_mask2 + hev_mask + filter4.
int _scc(int x) => x.clamp(-128, 127);
int _rp2(int v, int n) => (v + (1 << (n - 1))) >> n;

List<int> golden(
  int p1,
  int p0,
  int q0,
  int q1,
  int limit,
  int blimit,
  int thresh,
) {
  var m = 0;
  if ((p1 - p0).abs() > limit) m = -1;
  if ((q1 - q0).abs() > limit) m = -1;
  if ((p0 - q0).abs() * 2 + (p1 - q1).abs() ~/ 2 > blimit) m = -1;
  final maskOn = ((~m) & 0xFF) != 0;
  var hev = 0;
  if ((p1 - p0).abs() > thresh) hev = -1;
  if ((q1 - q0).abs() > thresh) hev = -1;
  final hevOn = (hev & 0xFF) != 0;

  final ps1 = p1 - 128, ps0 = p0 - 128, qs0 = q0 - 128, qs1 = q1 - 128;
  var filter = hevOn ? _scc(ps1 - qs1) : 0;
  filter = maskOn ? _scc(filter + 3 * (qs0 - ps0)) : 0;
  final filter1 = _scc(filter + 4) >> 3;
  final filter2 = _scc(filter + 3) >> 3;
  final oq0 = _scc(qs0 - filter1) + 128;
  final op0 = _scc(ps0 + filter2) + 128;
  final f = hevOn ? 0 : _rp2(filter1, 1);
  final oq1 = _scc(qs1 - f) + 128;
  final op1 = _scc(ps1 + f) + 128;
  return [op1, op0, oq0, oq1];
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('HarborDeblock4 matches libaom filter4', () async {
    final t = HarborDeblock4();
    final clk = SimpleClockGenerator(10).clk;
    final p1 = Logic(name: 'p1', width: 8);
    final p0 = Logic(name: 'p0', width: 8);
    final q0 = Logic(name: 'q0', width: 8);
    final q1 = Logic(name: 'q1', width: 8);
    final limit = Logic(name: 'limit', width: 8);
    final blimit = Logic(name: 'blimit', width: 8);
    final thresh = Logic(name: 'thresh', width: 8);
    t.input('p1').srcConnection! <= p1;
    t.input('p0').srcConnection! <= p0;
    t.input('q0').srcConnection! <= q0;
    t.input('q1').srcConnection! <= q1;
    t.input('limit').srcConnection! <= limit;
    t.input('blimit').srcConnection! <= blimit;
    t.input('thresh').srcConnection! <= thresh;
    await t.build();
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    final rng = Random(0xDEB1);
    for (var iter = 0; iter < 2000; iter++) {
      final vp1 = rng.nextInt(256), vp0 = rng.nextInt(256);
      final vq0 = rng.nextInt(256), vq1 = rng.nextInt(256);
      // bias params small (real filter levels) but also some large.
      final lim = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      final bli = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(80);
      final thr = iter % 3 == 0 ? rng.nextInt(256) : rng.nextInt(40);
      p1.put(vp1);
      p0.put(vp0);
      q0.put(vq0);
      q1.put(vq1);
      limit.put(lim);
      blimit.put(bli);
      thresh.put(thr);
      await clk.nextPosedge;
      final want = golden(vp1, vp0, vq0, vq1, lim, bli, thr);
      final got = [
        t.output('op1').value.toInt(),
        t.output('op0').value.toInt(),
        t.output('oq0').value.toInt(),
        t.output('oq1').value.toInt(),
      ];
      expect(
        got,
        equals(want),
        reason: 'iter=$iter p=$vp1,$vp0 q=$vq0,$vq1 l=$lim b=$bli t=$thr',
      );
    }
    await Simulator.endSimulation();
  });
}

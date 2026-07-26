import 'dart:async';

import 'package:harbor/src/media/deblock_edge_select.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Tables copied verbatim from the SW reference deblock model.
const List<int> kTxSizeWideUnitLog2 = [
  0, 1, 2, 3, 4, 0, 1, 1, 2, 2, 3, 3, 4, 0, 2, 1, 3, 2, 4, //
];
const List<int> kTxSizeHighUnitLog2 = [
  0, 1, 2, 3, 4, 1, 0, 2, 1, 3, 2, 4, 3, 2, 0, 3, 1, 4, 2, //
];
const List<int> kTxDimToFilterLength = [4, 8, 14, 14, 14];

const int kVertEdge = 0;
const int kPlaneY = 0;

// Golden mirroring the filter-length derivation in `_setLpfParameters`
// (the SW reference deblock model), reduced to its inputs: the current and
// across-edge transform sizes, the plane, the edge direction and the filter
// level. filterLength == 0 means no filtering.
int golden(int ts, int pvTs, int planeIdx, int edgeDir, int level) {
  var filterLength = 0;
  if (level != 0) {
    final dim = (edgeDir == kVertEdge)
        ? (kTxSizeWideUnitLog2[ts] < kTxSizeWideUnitLog2[pvTs]
              ? kTxSizeWideUnitLog2[ts]
              : kTxSizeWideUnitLog2[pvTs])
        : (kTxSizeHighUnitLog2[ts] < kTxSizeHighUnitLog2[pvTs]
              ? kTxSizeHighUnitLog2[ts]
              : kTxSizeHighUnitLog2[pvTs]);
    if (planeIdx != kPlaneY) {
      filterLength = (dim == 0) ? 4 : 6;
    } else {
      filterLength = kTxDimToFilterLength[dim];
    }
  }
  return filterLength;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'HarborDeblockEdgeSelect matches _setLpfParameters filter length',
    () async {
      final t = HarborDeblockEdgeSelect();
      final clk = SimpleClockGenerator(10).clk;
      final ts = Logic(name: 'ts', width: 5);
      final pvTs = Logic(name: 'pv_ts', width: 5);
      final plane = Logic(name: 'plane', width: 1);
      final edgeDir = Logic(name: 'edge_dir', width: 1);
      final level = Logic(name: 'level', width: 6);
      final thresh = Logic(name: 'thresh', width: 8);
      t.input('ts').srcConnection! <= ts;
      t.input('pv_ts').srcConnection! <= pvTs;
      t.input('plane').srcConnection! <= plane;
      t.input('edge_dir').srcConnection! <= edgeDir;
      t.input('level').srcConnection! <= level;
      t.input('thresh').srcConnection! <= thresh;

      await t.build();
      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());

      // Exhaustive over all valid tx-size pairs (0..18) x plane x edge_dir, plus
      // a couple of representative levels and a thresh pass-through check.
      for (var a = 0; a <= 18; a++) {
        for (var b = 0; b <= 18; b++) {
          for (var pl = 0; pl <= 1; pl++) {
            for (var ed = 0; ed <= 1; ed++) {
              for (final lvl in [0, 1, 37, 63]) {
                const thr = 0x5A;
                ts.put(a);
                pvTs.put(b);
                plane.put(pl);
                edgeDir.put(ed);
                level.put(lvl);
                thresh.put(thr);
                await clk.nextPosedge;
                final want = golden(a, b, pl, ed, lvl);
                final got = t.output('filter_length').value.toInt();
                expect(
                  got,
                  equals(want),
                  reason: 'ts=$a pvTs=$b plane=$pl edgeDir=$ed level=$lvl',
                );
                expect(
                  t.output('thresh_o').value.toInt(),
                  equals(thr),
                  reason: 'thresh pass-through',
                );
              }
            }
          }
        }
      }
      await Simulator.endSimulation();
    },
  );
}

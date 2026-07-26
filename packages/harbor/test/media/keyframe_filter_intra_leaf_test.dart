@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// FILTER_INTRA leaf-diff. Two REAL aomenc 3.12.1 keyframes (64x64, 4:2:0,
// --sb-size=64 => ONE interior 64x64 superblock uniformly SPLIT into sixteen
// 16x16 PARTITION_NONE luma leaves, TX_16X16 / TX_MODE_LARGEST, per-leaf 4:2:0
// chroma) encoded with --enable-filter-intra=1 (palette / angle-delta / cdef /
// restoration OFF). The RDO picks the FILTER_INTRA predictor for several of the
// DC leaves. The HW HarborKeyframeModeWalk decodes the tile on its shared od_ec
// window and exposes the per-leaf leaf_use_filter_intra / leaf_filter_intra_modes
// arrays.
//
// This is an entropy/leaf verification (no recon pixels): it proves the HW reads
// use_filter_intra + filter_intra_mode in the exact SW bitstream position (after
// the chroma mode info, before tx_size) AND that the filter_intra ->
// fimode_to_intradir ext-tx bank switch keeps the luma coeff stream aligned.
//
// The tile bytes, dc_q/ac_q/qband/tx_mode scalars and per-leaf SW goldens
// (use_filter_intra + filter_intra_mode + y_mode, in DFS/HW-emit order) below are
// captured from the conformant SW reference decoder (bit-exact vs aomdec).
// cq=30: filter_intra on leaves with modes {0,1,3}. cq=50: modes {1,3}.

const _tileBytesCq30 = <int>[
  216,
  3,
  109,
  69,
  238,
  157,
  95,
  177,
  44,
  215,
  9,
  139,
  62,
  241,
  94,
  166,
  176,
  183,
  8,
  171,
  27,
  81,
  16,
  41,
  4,
  89,
  151,
  45,
  227,
  2,
  172,
  224,
  189,
  179,
  192,
  161,
  203,
  251,
  14,
  138,
  134,
  32,
  206,
  116,
  24,
  70,
  132,
  33,
  167,
  117,
  36,
  231,
  192,
];
const _dcQCq30 = 123, _acQCq30 = 152, _qbandCq30 = 2, _txModeCq30 = 1;
const _fiCq30 = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0];
const _fiModeCq30 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0];
const _ymCq30 = [0, 11, 9, 12, 2, 2, 9, 9, 0, 9, 9, 9, 9, 0, 0, 9];

const _tileBytesCq50 = <int>[
  219,
  8,
  209,
  47,
  65,
  173,
  153,
  246,
  220,
  25,
  99,
  248,
  55,
  8,
  173,
  40,
  63,
  59,
  167,
  233,
  144,
  247,
  156,
  254,
  198,
  142,
  122,
  252,
  226,
  138,
];
const _dcQCq50 = 389, _acQCq50 = 639, _qbandCq50 = 3, _txModeCq50 = 1;
const _fiCq50 = [0, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1];
const _fiModeCq50 = [0, 0, 0, 3, 3, 0, 0, 0, 3, 0, 0, 0, 0, 1, 1, 3];
const _ymCq50 = [12, 0, 0, 0, 0, 12, 9, 0, 0, 9, 9, 0, 0, 0, 0, 0];

BigInt _pack(List<int> b) {
  var v = BigInt.zero;
  for (var i = 0; i < b.length; i++) {
    v |= BigInt.from(b[i] & 0xff) << (i * 8);
  }
  return v;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runCase(
    String label,
    List<int> tileBytes,
    int dcQv,
    int acQv,
    int qband,
    int txMode,
    List<int> swFi,
    List<int> swFiMode,
    List<int> swYm,
  ) async {
    expect(txMode, equals(1), reason: '$label: TX_MODE_LARGEST');
    expect(swYm.length, equals(16), reason: '$label: sixteen 16x16 leaves');
    // sanity: this stream really exercises filter_intra.
    expect(
      swFi.where((v) => v == 1).length,
      greaterThan(0),
      reason: '$label: stream must contain filter_intra leaves',
    );

    const maxBytes = 128;
    final dut = HarborKeyframeModeWalk(
      rootBsize: 12,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 256,
      chroma: true,
      chromaLeaf16: true,
      maxLeafOut: 16,
      qband: qband,
      txModeSelect: false,
      enableFilterIntra: true,
      name: 'fi_walk',
    );
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final bytes = Logic(name: 'bytes', width: maxBytes * 8);
    final dcQ = Logic(name: 'dc_q', width: 16);
    final acQ = Logic(name: 'ac_q', width: 16);
    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('start').srcConnection! <= start;
    dut.input('bytes').srcConnection! <= bytes;
    dut.input('dc_q').srcConnection! <= dcQ;
    dut.input('ac_q').srcConnection! <= acQ;
    await dut.build();

    reset.inject(1);
    start.inject(0);
    bytes.inject(_pack(tileBytes));
    dcQ.inject(dcQv);
    acQ.inject(acQv);
    Simulator.setMaxSimTime(20000000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);
    var guard = 0;
    while (dut.output('done').value.toInt() != 1) {
      await clk.nextPosedge;
      if (++guard > 5000000) fail('$label: mode-walk timeout');
    }

    expect(
      dut.output('leaf_count').value.toInt(),
      equals(16),
      reason: '$label: leaf_count',
    );
    final fiPacked = dut.output('leaf_use_filter_intra').value.toBigInt();
    final fiModePacked = dut.output('leaf_filter_intra_modes').value.toBigInt();
    final ymPacked = dut.output('leaf_ymodes').value.toBigInt();
    final hwFi = [
      for (var i = 0; i < 16; i++) ((fiPacked >> i) & BigInt.one).toInt(),
    ];
    final hwFiMode = [
      for (var i = 0; i < 16; i++)
        ((fiModePacked >> (i * 3)) & BigInt.from(7)).toInt(),
    ];
    final hwYm = [
      for (var i = 0; i < 16; i++)
        ((ymPacked >> (i * 4)) & BigInt.from(15)).toInt(),
    ];
    await Simulator.endSimulation();

    // filter_intra_mode is only meaningful where use_filter_intra == 1.
    final swFiModeMasked = [
      for (var i = 0; i < 16; i++) swFi[i] == 1 ? swFiMode[i] : 0,
    ];
    final hwFiModeMasked = [
      for (var i = 0; i < 16; i++) hwFi[i] == 1 ? hwFiMode[i] : 0,
    ];
    expect(hwYm, equals(swYm), reason: '$label: leaf y_modes');
    expect(hwFi, equals(swFi), reason: '$label: leaf use_filter_intra');
    expect(
      hwFiModeMasked,
      equals(swFiModeMasked),
      reason: '$label: leaf filter_intra_mode',
    );
  }

  test(
    'real 64x64 4:2:0 keyframe (cq30): HW filter_intra leaves == SW',
    timeout: const Timeout(Duration(minutes: 40)),
    () => runCase(
      'cq30',
      _tileBytesCq30,
      _dcQCq30,
      _acQCq30,
      _qbandCq30,
      _txModeCq30,
      _fiCq30,
      _fiModeCq30,
      _ymCq30,
    ),
  );

  test(
    'real 64x64 4:2:0 keyframe (cq50): HW filter_intra leaves == SW',
    timeout: const Timeout(Duration(minutes: 40)),
    () => runCase(
      'cq50',
      _tileBytesCq50,
      _dcQCq50,
      _acQCq50,
      _qbandCq50,
      _txModeCq50,
      _fiCq50,
      _fiModeCq50,
      _ymCq50,
    ),
  );
}

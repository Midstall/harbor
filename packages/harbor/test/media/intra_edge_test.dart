import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/intra_edge.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Golden: verbatim copies of the SW reference intra prediction (bd8).
// These mirror _filterIntraEdge, _upsampleIntraEdge,
// _intraEdgeFilterStrength and _useIntraEdgeUpsample exactly.

const int _intraEdgeFiltTaps = 5;
const int _maxUpsampleSz = 16;

int _clipPixel(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// av1_filter_intra_edge_c. Operates in-place over p[off .. off+sz-1].
void goldFilterIntraEdge(List<int> p, int off, int sz, int strength) {
  if (strength == 0) return;
  const kernel = [
    [0, 4, 8, 4, 0],
    [0, 5, 6, 5, 0],
    [2, 4, 4, 4, 2],
  ];
  final filt = strength - 1;
  final edge = List<int>.filled(sz, 0);
  for (var i = 0; i < sz; i++) {
    edge[i] = p[off + i];
  }
  for (var i = 1; i < sz; i++) {
    var s = 0;
    for (var j = 0; j < _intraEdgeFiltTaps; j++) {
      var k = i - 2 + j;
      if (k < 0) k = 0;
      if (k > sz - 1) k = sz - 1;
      s += edge[k] * kernel[filt][j];
    }
    s = (s + 8) >> 4;
    p[off + i] = s;
  }
}

// av1_upsample_intra_edge_c. Operates over p[off-2 .. off+2*sz-2] in place,
// reading p[off-1 .. off+sz-1].
void goldUpsampleIntraEdge(List<int> p, int off, int sz) {
  final inp = List<int>.filled(_maxUpsampleSz + 3, 0);
  inp[0] = p[off - 1];
  inp[1] = p[off - 1];
  for (var i = 0; i < sz; i++) {
    inp[i + 2] = p[off + i];
  }
  inp[sz + 2] = p[off + sz - 1];

  p[off - 2] = inp[0];
  for (var i = 0; i < sz; i++) {
    var s = -inp[i] + (9 * inp[i + 1]) + (9 * inp[i + 2]) - inp[i + 3];
    s = _clipPixel((s + 8) >> 4);
    p[off + 2 * i - 1] = s;
    p[off + 2 * i] = inp[i + 2];
  }
}

int goldStrength(int bs0, int bs1, int delta, int type) {
  final d = delta.abs();
  var strength = 0;
  final blkWh = bs0 + bs1;
  if (type == 0) {
    if (blkWh <= 8) {
      if (d >= 56) strength = 1;
    } else if (blkWh <= 12) {
      if (d >= 40) strength = 1;
    } else if (blkWh <= 16) {
      if (d >= 40) strength = 1;
    } else if (blkWh <= 24) {
      if (d >= 8) strength = 1;
      if (d >= 16) strength = 2;
      if (d >= 32) strength = 3;
    } else if (blkWh <= 32) {
      if (d >= 1) strength = 1;
      if (d >= 4) strength = 2;
      if (d >= 32) strength = 3;
    } else {
      if (d >= 1) strength = 3;
    }
  } else {
    if (blkWh <= 8) {
      if (d >= 40) strength = 1;
      if (d >= 64) strength = 2;
    } else if (blkWh <= 16) {
      if (d >= 20) strength = 1;
      if (d >= 48) strength = 2;
    } else if (blkWh <= 24) {
      if (d >= 4) strength = 3;
    } else {
      if (d >= 1) strength = 3;
    }
  }
  return strength;
}

bool goldUseUpsample(int bs0, int bs1, int delta, int type) {
  final d = delta.abs();
  final blkWh = bs0 + bs1;
  if (d == 0 || d >= 40) return false;
  return type != 0 ? (blkWh <= 8) : (blkWh <= 16);
}

// Pack a list of bytes LSB-first: sample i at bit i*8.
BigInt packBytes(List<int> bytes) {
  var packed = BigInt.zero;
  for (var i = 0; i < bytes.length; i++) {
    packed |= BigInt.from(bytes[i] & 0xFF) << (i * 8);
  }
  return packed;
}

int unpackByte(LogicValue v, int i) => v.getRange(i * 8, i * 8 + 8).toInt();

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('intraEdgeFilterStrength matches golden exhaustively', () {
    for (final bs0 in [4, 8, 16, 32, 64]) {
      for (final bs1 in [4, 8, 16, 32, 64]) {
        for (var delta = -90; delta <= 90; delta++) {
          for (final type in [0, 1]) {
            expect(
              intraEdgeFilterStrength(bs0, bs1, delta, type),
              equals(goldStrength(bs0, bs1, delta, type)),
              reason: 'bs0=$bs0 bs1=$bs1 delta=$delta type=$type',
            );
          }
        }
      }
    }
  });

  test('useIntraEdgeUpsample matches golden exhaustively', () {
    for (final bs0 in [4, 8, 16, 32, 64]) {
      for (final bs1 in [4, 8, 16, 32, 64]) {
        for (var delta = -90; delta <= 90; delta++) {
          for (final type in [0, 1]) {
            expect(
              useIntraEdgeUpsample(bs0, bs1, delta, type),
              equals(goldUseUpsample(bs0, bs1, delta, type)),
              reason: 'bs0=$bs0 bs1=$bs1 delta=$delta type=$type',
            );
          }
        }
      }
    }
  });

  for (final sz in [4, 8, 16, 33]) {
    test(
      'HarborIntraEdgeFilter matches golden (sz=$sz, all strengths)',
      () async {
        final dut = HarborIntraEdgeFilter(sz: sz);
        final clk = SimpleClockGenerator(10).clk;
        final edge = Logic(name: 'edge_in', width: sz * 8);
        final strength = Logic(name: 'strength', width: 2);
        dut.input('edge_in').srcConnection! <= edge;
        dut.input('strength').srcConnection! <= strength;
        await dut.build();
        Simulator.setMaxSimTime(200000000);
        unawaited(Simulator.run());

        final rng = Random(0x5E + sz);
        for (var iter = 0; iter < 400; iter++) {
          final px = [for (var i = 0; i < sz; i++) rng.nextInt(256)];
          final st = rng.nextInt(4); // 0..3
          edge.put(packBytes(px));
          strength.put(st);
          await clk.nextPosedge;

          final gold = List<int>.of(px);
          goldFilterIntraEdge(gold, 0, sz, st);

          final out = dut.output('out').value;
          for (var i = 0; i < sz; i++) {
            expect(
              unpackByte(out, i),
              equals(gold[i]),
              reason: 'sz=$sz iter=$iter st=$st i=$i',
            );
          }
        }
        await Simulator.endSimulation();
      },
    );
  }

  for (final sz in [4, 8, 16]) {
    test('HarborIntraEdgeUpsample matches golden (sz=$sz)', () async {
      final dut = HarborIntraEdgeUpsample(sz: sz);
      final clk = SimpleClockGenerator(10).clk;
      // Input edge is p[off-1 .. off+sz-1] = sz+1 samples (includes the
      // corner sample before the edge). Output is p[off-2 .. off+2*sz-2]
      // = 2*sz+1 samples.
      final edge = Logic(name: 'edge_in', width: (sz + 1) * 8);
      dut.input('edge_in').srcConnection! <= edge;
      await dut.build();
      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());

      final rng = Random(0xA0 + sz);
      for (var iter = 0; iter < 400; iter++) {
        // p buffer with off=1 so p[off-1]=p[0] exists. Build sz+1 samples.
        final inEdge = [for (var i = 0; i < sz + 1; i++) rng.nextInt(256)];
        // Golden buffer: needs p[off-2..off+2sz-2]. Use off=2 in a big buffer.
        const off = 2;
        final p = List<int>.filled(off + 2 * sz, 0);
        // p[off-1] = inEdge[0], p[off+i] = inEdge[i+1].
        p[off - 1] = inEdge[0];
        for (var i = 0; i < sz; i++) {
          p[off + i] = inEdge[i + 1];
        }
        goldUpsampleIntraEdge(p, off, sz);

        edge.put(packBytes(inEdge));
        await clk.nextPosedge;

        final out = dut.output('out').value;
        // out sample k corresponds to p[off-2+k], k=0..2*sz.
        for (var k = 0; k <= 2 * sz; k++) {
          expect(
            unpackByte(out, k),
            equals(p[off - 2 + k]),
            reason: 'sz=$sz iter=$iter k=$k',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }
}

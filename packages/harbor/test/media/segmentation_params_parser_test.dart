import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const featBits = [8, 6, 6, 6, 6, 3, 0, 0];
const featSigned = [1, 1, 1, 1, 1, 0, 0, 0];
const featMax = [255, 63, 63, 63, 63, 7, 0, 0];

int _clip3(int lo, int hi, int v) => v < lo ? lo : (v > hi ? hi : v);

class _Seg {
  _Seg({
    required this.enabled,
    required this.primNone,
    this.updateMap = 0,
    this.temporal = 0,
    this.updateData = 0,
    // featEnabled[i][j], featValue[i][j]
    this.featEnabled = const [],
    this.featValue = const [],
  });
  final int enabled, primNone, updateMap, temporal, updateData;
  final List<List<int>> featEnabled, featValue;
}

(List<int>, Map<String, int>) _build(_Seg s) {
  final bits = <int>[];
  void f(int v, int n) {
    for (var k = n - 1; k >= 0; k--) {
      bits.add((v >> k) & 1);
    }
  }

  final exp = <String, int>{};
  f(s.enabled, 1);
  var updateMap = 0, temporal = 0, updateData = 0;
  if (s.enabled == 1) {
    if (s.primNone == 1) {
      updateMap = 1;
      temporal = 0;
      updateData = 1;
    } else {
      f(s.updateMap, 1);
      updateMap = s.updateMap;
      if (updateMap == 1) {
        f(s.temporal, 1);
        temporal = s.temporal;
      }
      f(s.updateData, 1);
      updateData = s.updateData;
    }
  }

  final dataOut = [for (var i = 0; i < 8; i++) List.filled(8, 0)];
  final enOut = [for (var i = 0; i < 8; i++) List.filled(8, 0)];
  if (updateData == 1) {
    for (var i = 0; i < 8; i++) {
      for (var j = 0; j < 8; j++) {
        final fe = s.featEnabled[i][j];
        f(fe, 1);
        enOut[i][j] = fe;
        if (fe == 1 && featBits[j] > 0) {
          final v = s.featValue[i][j];
          if (featSigned[j] == 1) {
            f(v & ((1 << (1 + featBits[j])) - 1), 1 + featBits[j]);
            dataOut[i][j] = _clip3(-featMax[j], featMax[j], v);
          } else {
            f(v, featBits[j]);
            dataOut[i][j] = _clip3(0, featMax[j], v);
          }
        }
      }
    }
  }

  exp['segmentation_enabled'] = s.enabled;
  exp['update_map'] = updateMap;
  exp['temporal_update'] = temporal;
  exp['update_data'] = updateData;
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 8; j++) {
      exp['feature_enabled_${i}_$j'] = enOut[i][j];
      exp['feature_data_${i}_$j'] = dataOut[i][j] & 0xffff;
    }
  }
  exp['bits_consumed'] = bits.length;
  return (bits, exp);
}

List<int> _bytes(List<int> bits) {
  final out = List.filled(64, 0);
  for (var i = 0; i < bits.length && i < 512; i++) {
    if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSegmentationParamsParser', () {
    late HarborSegmentationParamsParser p;
    late Logic clk, bytes, primNone;

    Future<void> setUpDut() async {
      p = HarborSegmentationParamsParser();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 64 * 8);
      primNone = Logic(name: 'primary_ref_none', width: 1);
      p.input('bytes').srcConnection! <= bytes;
      p.input('primary_ref_none').srcConnection! <= primNone;
      await p.build();
      bytes.inject(0);
      primNone.inject(1);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
    }

    BigInt pack(List<int> b) {
      var v = BigInt.zero;
      for (var i = 0; i < b.length; i++) {
        v |= BigInt.from(b[i] & 0xFF) << (i * 8);
      }
      return v;
    }

    List<List<int>> grid(int Function(int, int) gen) => [
      for (var i = 0; i < 8; i++) [for (var j = 0; j < 8; j++) gen(i, j)],
    ];

    final cases = <(String, _Seg)>[
      ('disabled', _Seg(enabled: 0, primNone: 1)),
      (
        'enabled, no features',
        _Seg(
          enabled: 1,
          primNone: 1,
          featEnabled: grid((i, j) => 0),
          featValue: grid((i, j) => 0),
        ),
      ),
      (
        'one feature seg0 altq',
        _Seg(
          enabled: 1,
          primNone: 1,
          featEnabled: grid((i, j) => (i == 0 && j == 0) ? 1 : 0),
          featValue: grid((i, j) => -40),
        ),
      ),
      (
        'clip min altq',
        _Seg(
          enabled: 1,
          primNone: 1,
          featEnabled: grid((i, j) => (i == 1 && j == 0) ? 1 : 0),
          featValue: grid((i, j) => -256),
        ),
      ), // clips to -255
      (
        'ref+skip flags',
        _Seg(
          enabled: 1,
          primNone: 1,
          featEnabled: grid((i, j) => (i == 2 && (j == 5 || j == 6)) ? 1 : 0),
          featValue: grid((i, j) => j == 5 ? 5 : 0),
        ),
      ),
      (
        'with primary ref reads flags',
        _Seg(
          enabled: 1,
          primNone: 0,
          updateMap: 1,
          temporal: 1,
          updateData: 1,
          featEnabled: grid((i, j) => (i == 3 && j == 1) ? 1 : 0),
          featValue: grid((i, j) => 30),
        ),
      ),
      (
        'update_data off',
        _Seg(
          enabled: 1,
          primNone: 0,
          updateMap: 1,
          temporal: 0,
          updateData: 0,
          featEnabled: grid((i, j) => 0),
          featValue: grid((i, j) => 0),
        ),
      ),
      (
        'many features',
        _Seg(
          enabled: 1,
          primNone: 1,
          featEnabled: grid(
            (i, j) => ((i + j) % 3 == 0 && featBits[j] > 0) ? 1 : 0,
          ),
          featValue: grid((i, j) => featSigned[j] == 1 ? (i - j) * 3 : (i % 8)),
        ),
      ),
    ];

    for (final c in cases) {
      test('parses ${c.$1}', () async {
        await setUpDut();
        final (bits, exp) = _build(c.$2);
        bytes.inject(pack(_bytes(bits)));
        primNone.inject(c.$2.primNone);
        await clk.nextPosedge;
        for (final key in exp.keys) {
          expect(
            p.output(key).value.toInt(),
            equals(exp[key]),
            reason: '${c.$1}: $key',
          );
        }
        await Simulator.endSimulation();
      });
    }
  });
}

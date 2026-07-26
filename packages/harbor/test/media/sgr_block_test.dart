import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Per-pixel SGR reference (matches the RTL fixed-point exactly).
int _sgr(List<int> win, int s, int radius) {
  final side = 2 * radius + 1;
  final n = side * side;
  final centre = n ~/ 2;
  const recipBits = 12;
  const mtableBits = 20;
  final oneOverN = ((1 << recipBits) + n ~/ 2) ~/ n;

  var sum = 0, sumsq = 0;
  for (final p in win) {
    sum += p;
    sumsq += p * p;
  }
  final varNum = sumsq * n - sum * sum;
  var z = (varNum * s) >> mtableBits;
  if (z > 255) z = 255;
  final a2 = (256 * z + (z + 1) ~/ 2) ~/ (z + 1);
  final mean = (sum * oneOverN + (1 << (recipBits - 1))) >> recipBits;
  final blend = a2 * win[centre] + (256 - a2) * mean;
  var out = (blend + 128) >> 8;
  if (out > 255) out = 255;
  return out;
}

// Filter a 10x10 padded region (radius 1) -> 8x8 block.
List<int> _sgrBlock(List<List<int>> padded, int s, int radius) {
  final winSide = 2 * radius + 1;
  final out = <int>[];
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      final win = <int>[
        for (var dr = 0; dr < winSide; dr++)
          for (var dc = 0; dc < winSide; dc++) padded[r + dr][c + dc],
      ];
      out.add(_sgr(win, s, radius));
    }
  }
  return out;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSgrBlock', () {
    test('restores an 8x8 block (radius 1)', () async {
      final sb = HarborSgrBlock();
      final clk = SimpleClockGenerator(10).clk;
      final padded = Logic(name: 'padded', width: 10 * 10 * 8);
      final s = Logic(name: 's', width: 8);
      sb.input('padded').srcConnection! <= padded;
      sb.input('s').srcConnection! <= s;
      await sb.build();

      // A 10x10 region: diagonal edge plus a little texture.
      final pad = [
        for (var r = 0; r < 10; r++)
          [
            for (var c = 0; c < 10; c++)
              (((r + c) < 9 ? 70 : 190) + (r * 5 + c * 3) % 13 - 6) & 0xFF,
          ],
      ];
      var pv = BigInt.zero;
      for (var r = 0; r < 10; r++) {
        for (var c = 0; c < 10; c++) {
          pv |= BigInt.from(pad[r][c] & 0xFF) << ((r * 10 + c) * 8);
        }
      }

      padded.inject(pv);
      s.inject(40);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;

      final v = sb.output('out').value.toBigInt();
      final got = [
        for (var i = 0; i < 64; i++)
          ((v >> (i * 8)) & BigInt.from(0xFF)).toInt(),
      ];
      expect(got, equals(_sgrBlock(pad, 40, 1)));
      await Simulator.endSimulation();
    });
  });
}

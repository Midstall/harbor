@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/media/inter_convolve_scaled.dart';
import 'package:harbor/src/media/inter_scale_setup.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Filter tables, copied EXACTLY from the SW reference interp filters. The golden
// below mirrors the SW tile decode `_scaledConvolve` / `_refScale` / `_scaledPos`
// verbatim (the SW oracle, kept untouched).
const List<List<int>> _regular = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, -6, 126, 8, -2, 0, 0],
  [0, 2, -10, 122, 18, -4, 0, 0],
  [0, 2, -12, 116, 28, -8, 2, 0],
  [0, 2, -14, 110, 38, -10, 2, 0],
  [0, 2, -14, 102, 48, -12, 2, 0],
  [0, 2, -16, 94, 58, -12, 2, 0],
  [0, 2, -14, 84, 66, -12, 2, 0],
  [0, 2, -14, 76, 76, -14, 2, 0],
  [0, 2, -12, 66, 84, -14, 2, 0],
  [0, 2, -12, 58, 94, -16, 2, 0],
  [0, 2, -12, 48, 102, -14, 2, 0],
  [0, 2, -10, 38, 110, -14, 2, 0],
  [0, 2, -8, 28, 116, -12, 2, 0],
  [0, 0, -4, 18, 122, -10, 2, 0],
  [0, 0, -2, 8, 126, -6, 2, 0],
];

const List<List<int>> _smooth = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, 28, 62, 34, 2, 0, 0],
  [0, 0, 26, 62, 36, 4, 0, 0],
  [0, 0, 22, 62, 40, 4, 0, 0],
  [0, 0, 20, 60, 42, 6, 0, 0],
  [0, 0, 18, 58, 44, 8, 0, 0],
  [0, 0, 16, 56, 46, 10, 0, 0],
  [0, -2, 16, 54, 48, 12, 0, 0],
  [0, -2, 14, 52, 52, 14, -2, 0],
  [0, 0, 12, 48, 54, 16, -2, 0],
  [0, 0, 10, 46, 56, 16, 0, 0],
  [0, 0, 8, 44, 58, 18, 0, 0],
  [0, 0, 6, 42, 60, 20, 0, 0],
  [0, 0, 4, 40, 62, 22, 0, 0],
  [0, 0, 4, 36, 62, 26, 0, 0],
  [0, 0, 2, 34, 62, 28, 2, 0],
];

const List<List<int>> _sharp = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [-2, 2, -6, 126, 8, -2, 2, 0],
  [-2, 6, -12, 124, 16, -6, 4, -2],
  [-2, 8, -18, 120, 26, -10, 6, -2],
  [-4, 10, -22, 116, 38, -14, 6, -2],
  [-4, 10, -22, 108, 48, -18, 8, -2],
  [-4, 10, -24, 100, 60, -20, 8, -2],
  [-4, 10, -24, 90, 70, -22, 10, -2],
  [-4, 12, -24, 80, 80, -24, 12, -4],
  [-2, 10, -22, 70, 90, -24, 10, -4],
  [-2, 8, -20, 60, 100, -24, 10, -4],
  [-2, 8, -18, 48, 108, -22, 10, -4],
  [-2, 6, -14, 38, 116, -22, 10, -4],
  [-2, 6, -10, 26, 120, -18, 8, -2],
  [-2, 4, -6, 16, 124, -12, 6, -2],
  [0, 2, -2, 8, 126, -6, 2, -2],
];

const _bd = 8;
const _pixMax = (1 << _bd) - 1; // 255
const _fo = 3;

int _clip(int v) => v < 0 ? 0 : (v > _pixMax ? _pixMax : v);

int _refAt(List<List<int>> ref, int y, int x) {
  final h = ref.length, w = ref[0].length;
  return ref[y < 0 ? 0 : (y >= h ? h - 1 : y)][x < 0
      ? 0
      : (x >= w ? w - 1 : x)];
}

// _refScale, verbatim.
(int, int, int, int, bool) _refScale(int refW, int refH, int thisW, int thisH) {
  final xfp = ((refW << 14) + thisW ~/ 2) ~/ thisW;
  final yfp = ((refH << 14) + thisH ~/ 2) ~/ thisH;
  final xStep = (xfp + 8) >> 4;
  final yStep = (yfp + 8) >> 4;
  const noScale = 1 << 14;
  return (xfp, yfp, xStep, yStep, xfp != noScale || yfp != noScale);
}

// _scaledPos, verbatim.
int _scaledPos(int val, int fp) {
  final t = val * fp + (fp - (1 << 14)) * 8;
  return t < 0 ? -((-t + 128) >> 8) : ((t + 128) >> 8);
}

class _Setup {
  final int subX, subY, bx0, by0, xStep, yStep;
  _Setup(this.subX, this.subY, this.bx0, this.by0, this.xStep, this.yStep);
}

// The position / phase setup from _scaledConvolve (posX/posY + clamp + split).
_Setup _setup(
  int refW,
  int refH,
  int thisW,
  int thisH,
  int mvR,
  int mvC,
  int px,
  int py,
  int sx,
  int sy,
) {
  final (xfp, yfp, xStep, yStep, _) = _refScale(refW, refH, thisW, thisH);
  final origX = (px << 4) + mvC * (1 << (1 - sx));
  final origY = (py << 4) + mvR * (1 << (1 - sy));
  var posX = _scaledPos(origX, xfp) + 32;
  var posY = _scaledPos(origY, yfp) + 32;
  final left = -(((288 >> sx) - 4) << 10), top = -(((288 >> sy) - 4) << 10);
  final right = (((refW + sx) >> sx) + 4) << 10;
  final bottom = (((refH + sy) >> sy) + 4) << 10;
  if (posX < left) {
    posX = left;
  } else if (posX > right) {
    posX = right;
  }
  if (posY < top) {
    posY = top;
  } else if (posY > bottom) {
    posY = bottom;
  }
  return _Setup(posX & 1023, posY & 1023, posX >> 10, posY >> 10, xStep, yStep);
}

// Golden scaled convolve, verbatim from _scaledConvolve (bd8), single or
// compound. Writes single/avg pixels into `pl` (size h x w) and, when
// isCompound && !doAverage, the CONV_BUF into `conv` (size w*h). `dst16` is the
// other reference's CONV_BUF for the doAverage blend.
void _goldScaled(
  List<List<int>> ref,
  int refW,
  int refH,
  int thisW,
  int thisH,
  int mvR,
  int mvC,
  int px,
  int py,
  int w,
  int h,
  int sx,
  int sy,
  List<List<int>> fx,
  List<List<int>> fy, {
  required bool isCompound,
  bool doAverage = false,
  List<int>? dst16,
  List<List<int>>? pl,
  List<int>? conv,
  int fwdOff = 0,
  int bckOff = 0,
  int useDistWtd = 0,
}) {
  const bd = _bd;
  final s = _setup(refW, refH, thisW, thisH, mvR, mvC, px, py, sx, sy);
  final subX = s.subX, subY = s.subY, bx0 = s.bx0, by0 = s.by0;
  final xStep = s.xStep, yStep = s.yStep;
  const filterBits = 7, fo = _fo;
  var round0 = 3;
  final intbufrange = bd + filterBits - round0 + 2;
  if (intbufrange > 16) round0 += intbufrange - 16;
  final round1 = isCompound ? 7 : 2 * filterBits - round0;
  final offsetBits = bd + 2 * filterBits - round0;
  final roundOffset =
      (1 << (offsetBits - round1)) + (1 << (offsetBits - round1 - 1));
  final roundBits = 2 * filterBits - round0 - round1;
  final imH = (((h - 1) * yStep + subY) >> 10) + 8;
  final im = List<int>.filled(imH * w, 0);
  for (var iy = 0; iy < imH; iy++) {
    final refRow = by0 - fo + iy;
    var xqn = subX;
    for (var x = 0; x < w; x++) {
      final col = bx0 + (xqn >> 10);
      final f = fx[(xqn & 1023) >> 6];
      var sum = 1 << (bd + filterBits - 1);
      for (var k = 0; k < 8; k++) {
        sum += f[k] * _refAt(ref, refRow, col + k - fo);
      }
      im[iy * w + x] = (sum + (1 << (round0 - 1))) >> round0;
      xqn += xStep;
    }
  }
  for (var x = 0; x < w; x++) {
    var yqn = subY;
    for (var y = 0; y < h; y++) {
      final baseIdx = yqn >> 10;
      final f = fy[(yqn & 1023) >> 6];
      var sum = 1 << offsetBits;
      for (var k = 0; k < 8; k++) {
        sum += f[k] * im[(baseIdx + k) * w + x];
      }
      final res = (sum + (1 << (round1 - 1))) >> round1;
      if (isCompound) {
        if (!doAverage) {
          conv![y * w + x] = res;
        } else {
          var tmp = dst16![y * w + x];
          if (useDistWtd != 0) {
            tmp = (tmp * fwdOff + res * bckOff) >> 4;
          } else {
            tmp = (tmp + res) >> 1;
          }
          tmp -= roundOffset;
          pl![y][x] = _clip((tmp + (1 << (roundBits - 1))) >> roundBits);
        }
      } else {
        pl![y][x] = _clip(res - roundOffset);
      }
      yqn += yStep;
    }
  }
}

List<List<int>> _tableOf(InterConvolveScaledFilter f) {
  switch (f) {
    case InterConvolveScaledFilter.regular:
      return _regular;
    case InterConvolveScaledFilter.smooth:
      return _smooth;
    case InterConvolveScaledFilter.sharp:
      return _sharp;
  }
}

// Build the module patch (pr x pc) from a reference frame, edge-replicated via
// _refAt exactly as the SW oracle reads it: patch[pr][pc] = ref sample at
// (by0 - fo + pr, bx0 - fo + pc). Returns the LSB-first packed BigInt.
BigInt _packPatch(List<List<int>> ref, int bx0, int by0, int pw, int ph) {
  var packed = BigInt.zero;
  for (var pr = 0; pr < ph; pr++) {
    for (var pc = 0; pc < pw; pc++) {
      final v = _refAt(ref, by0 - _fo + pr, bx0 - _fo + pc);
      packed |= BigInt.from(v) << ((pr * pw + pc) * _bd);
    }
  }
  return packed;
}

int _s32(LogicValue v) {
  final u = v.toInt();
  return u >= 0x80000000 ? u - 0x100000000 : u;
}

// Scale scenarios: (refW, refH, thisW, thisH, sx, sy, label). Ratios stay <= 2
// so xStep/yStep <= 2048 (the module's maxStepQ10).
class _Scn {
  final int refW, refH, thisW, thisH, sx, sy;
  final String label;
  const _Scn(
    this.refW,
    this.refH,
    this.thisW,
    this.thisH,
    this.sx,
    this.sy,
    this.label,
  );
}

const _scenarios = <_Scn>[
  _Scn(64, 32, 48, 32, 0, 0, 'horiz-1.33 (superres-like)'),
  _Scn(64, 48, 32, 32, 0, 0, 'horiz-2.0 vert-1.5 (both, near max)'),
  _Scn(48, 48, 40, 40, 0, 0, 'both-1.2'),
  _Scn(64, 32, 48, 32, 1, 1, 'chroma 4:2:0 horiz-1.33'),
];

// A handful of MVs (1/8-pel) to spread the q10 sub-phases.
const _mvs = <List<int>>[
  [0, 0],
  [3, 5],
  [-7, 11],
  [13, -2],
  [-9, -14],
  [21, 4],
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const w = 8, h = 8;

  for (final family in InterConvolveScaledFilter.values) {
    test('HarborInterConvolveScaled single-ref bit-exact vs _scaledConvolve '
        '(${family.name})', () async {
      final dut = HarborInterConvolveScaled(
        width: w,
        height: h,
        filter: family,
      );
      final clk = SimpleClockGenerator(10).clk;
      final patch = Logic(name: 'patch', width: dut.pw * dut.ph * _bd);
      final subXp = Logic(name: 'sub_x', width: dut.input('sub_x').width);
      final subYp = Logic(name: 'sub_y', width: dut.input('sub_y').width);
      final xStepP = Logic(name: 'x_step', width: dut.input('x_step').width);
      final yStepP = Logic(name: 'y_step', width: dut.input('y_step').width);
      dut.input('patch').srcConnection! <= patch;
      dut.input('sub_x').srcConnection! <= subXp;
      dut.input('sub_y').srcConnection! <= subYp;
      dut.input('x_step').srcConnection! <= xStepP;
      dut.input('y_step').srcConnection! <= yStepP;
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      final table = _tableOf(family);
      final rng = Random(0x5CA1 + family.index);
      var vectors = 0, diffs = 0;
      final stepsSeen = <int>{};

      for (final scn in _scenarios) {
        // A random reference frame for this scenario.
        final ref = [
          for (var r = 0; r < scn.refH; r++)
            [for (var c = 0; c < scn.refW; c++) rng.nextInt(256)],
        ];
        for (final mv in _mvs) {
          final px = 4 + rng.nextInt(scn.thisW - w - 8);
          final py = 4 + rng.nextInt(scn.thisH - h - 8);
          final s = _setup(
            scn.refW,
            scn.refH,
            scn.thisW,
            scn.thisH,
            mv[0],
            mv[1],
            px,
            py,
            scn.sx,
            scn.sy,
          );
          stepsSeen.add(s.xStep);

          final pl = [for (var y = 0; y < h; y++) List<int>.filled(w, 0)];
          _goldScaled(
            ref,
            scn.refW,
            scn.refH,
            scn.thisW,
            scn.thisH,
            mv[0],
            mv[1],
            px,
            py,
            w,
            h,
            scn.sx,
            scn.sy,
            table,
            table,
            isCompound: false,
            pl: pl,
          );

          patch.put(_packPatch(ref, s.bx0, s.by0, dut.pw, dut.ph));
          subXp.put(s.subX);
          subYp.put(s.subY);
          xStepP.put(s.xStep);
          yStepP.put(s.yStep);
          await clk.nextPosedge;

          final out = dut.output('pred').value;
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final idx = y * w + x;
              final got = out.getRange(idx * _bd, idx * _bd + _bd).toInt();
              if (got != pl[y][x]) {
                diffs++;
                expect(
                  got,
                  equals(pl[y][x]),
                  reason: '${family.name} ${scn.label} mv=$mv ($x,$y)',
                );
              }
            }
          }
          vectors++;
        }
      }
      expect(diffs, equals(0));
      expect(vectors, greaterThanOrEqualTo(20));
      // Confirm actual scaling occurred (steps other than 1024 exercised).
      expect(stepsSeen.any((s) => s != 1024), isTrue);
      // ignore: avoid_print
      print(
        '[scaled single ${family.name}] vectors=$vectors diffs=$diffs '
        'steps=${(stepsSeen.toList()..sort())}',
      );
      await Simulator.endSimulation();
    });
  }

  test('HarborInterConvolveScaled compound conv-buf bit-exact', () async {
    final dut = HarborInterConvolveScaled(
      width: w,
      height: h,
      isCompound: true,
      doAverage: false,
    );
    final clk = SimpleClockGenerator(10).clk;
    final patch = Logic(name: 'patch', width: dut.pw * dut.ph * _bd);
    final subXp = Logic(name: 'sub_x', width: dut.input('sub_x').width);
    final subYp = Logic(name: 'sub_y', width: dut.input('sub_y').width);
    final xStepP = Logic(name: 'x_step', width: dut.input('x_step').width);
    final yStepP = Logic(name: 'y_step', width: dut.input('y_step').width);
    dut.input('patch').srcConnection! <= patch;
    dut.input('sub_x').srcConnection! <= subXp;
    dut.input('sub_y').srcConnection! <= subYp;
    dut.input('x_step').srcConnection! <= xStepP;
    dut.input('y_step').srcConnection! <= yStepP;
    await dut.build();
    Simulator.setMaxSimTime(600000000);
    unawaited(Simulator.run());

    final table = _regular;
    final rng = Random(0xC0FFEE);
    var vectors = 0, diffs = 0;
    for (final scn in _scenarios) {
      final ref = [
        for (var r = 0; r < scn.refH; r++)
          [for (var c = 0; c < scn.refW; c++) rng.nextInt(256)],
      ];
      for (final mv in _mvs) {
        final px = 4 + rng.nextInt(scn.thisW - w - 8);
        final py = 4 + rng.nextInt(scn.thisH - h - 8);
        final s = _setup(
          scn.refW,
          scn.refH,
          scn.thisW,
          scn.thisH,
          mv[0],
          mv[1],
          px,
          py,
          scn.sx,
          scn.sy,
        );
        final conv = List<int>.filled(w * h, 0);
        _goldScaled(
          ref,
          scn.refW,
          scn.refH,
          scn.thisW,
          scn.thisH,
          mv[0],
          mv[1],
          px,
          py,
          w,
          h,
          scn.sx,
          scn.sy,
          table,
          table,
          isCompound: true,
          conv: conv,
        );
        patch.put(_packPatch(ref, s.bx0, s.by0, dut.pw, dut.ph));
        subXp.put(s.subX);
        subYp.put(s.subY);
        xStepP.put(s.xStep);
        yStepP.put(s.yStep);
        await clk.nextPosedge;
        final out = dut.output('conv').value;
        for (var i = 0; i < w * h; i++) {
          final got = _s32(out.getRange(i * 32, i * 32 + 32));
          if (got != conv[i]) {
            diffs++;
            expect(
              got,
              equals(conv[i]),
              reason: 'conv ${scn.label} mv=$mv i=$i',
            );
          }
        }
        vectors++;
      }
    }
    expect(diffs, equals(0));
    // ignore: avoid_print
    print('[scaled compound conv] vectors=$vectors diffs=$diffs');
    await Simulator.endSimulation();
  });

  for (final distWtd in [false, true]) {
    test('HarborInterConvolveScaled compound doAverage bit-exact '
        '(${distWtd ? 'dist-wtd' : 'straight'})', () async {
      final dut = HarborInterConvolveScaled(
        width: w,
        height: h,
        isCompound: true,
        doAverage: true,
        useDistWtd: distWtd,
      );
      final clk = SimpleClockGenerator(10).clk;
      final patch = Logic(name: 'patch', width: dut.pw * dut.ph * _bd);
      final subXp = Logic(name: 'sub_x', width: dut.input('sub_x').width);
      final subYp = Logic(name: 'sub_y', width: dut.input('sub_y').width);
      final xStepP = Logic(name: 'x_step', width: dut.input('x_step').width);
      final yStepP = Logic(name: 'y_step', width: dut.input('y_step').width);
      final dst16 = Logic(name: 'dst16', width: dut.input('dst16').width);
      dut.input('patch').srcConnection! <= patch;
      dut.input('sub_x').srcConnection! <= subXp;
      dut.input('sub_y').srcConnection! <= subYp;
      dut.input('x_step').srcConnection! <= xStepP;
      dut.input('y_step').srcConnection! <= yStepP;
      dut.input('dst16').srcConnection! <= dst16;
      Logic? fwd, bck;
      if (distWtd) {
        fwd = Logic(name: 'fwd_off', width: 8);
        bck = Logic(name: 'bck_off', width: 8);
        dut.input('fwd_off').srcConnection! <= fwd;
        dut.input('bck_off').srcConnection! <= bck;
      }
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      final table = _regular;
      final rng = Random(distWtd ? 0xD157 : 0xA7E7);
      // AV1 quant_dist_lookup fwd/bck pairs (sum to 16).
      const wtds = <List<int>>[
        [9, 7],
        [11, 5],
        [12, 4],
      ];
      var vectors = 0, diffs = 0;
      for (final scn in _scenarios) {
        final ref0 = [
          for (var r = 0; r < scn.refH; r++)
            [for (var c = 0; c < scn.refW; c++) rng.nextInt(256)],
        ];
        final ref1 = [
          for (var r = 0; r < scn.refH; r++)
            [for (var c = 0; c < scn.refW; c++) rng.nextInt(256)],
        ];
        for (final mv in _mvs) {
          final px = 4 + rng.nextInt(scn.thisW - w - 8);
          final py = 4 + rng.nextInt(scn.thisH - h - 8);
          // ref0 contributes the stored CONV_BUF (mv0), ref1 the second pass.
          final mv0 = [mv[1], mv[0]]; // a distinct MV for the first ref
          final conv0 = List<int>.filled(w * h, 0);
          _goldScaled(
            ref0,
            scn.refW,
            scn.refH,
            scn.thisW,
            scn.thisH,
            mv0[0],
            mv0[1],
            px,
            py,
            w,
            h,
            scn.sx,
            scn.sy,
            table,
            table,
            isCompound: true,
            conv: conv0,
          );

          final wt = wtds[vectors % wtds.length];
          final fwdOff = distWtd ? wt[0] : 0, bckOff = distWtd ? wt[1] : 0;
          final pl = [for (var y = 0; y < h; y++) List<int>.filled(w, 0)];
          _goldScaled(
            ref1,
            scn.refW,
            scn.refH,
            scn.thisW,
            scn.thisH,
            mv[0],
            mv[1],
            px,
            py,
            w,
            h,
            scn.sx,
            scn.sy,
            table,
            table,
            isCompound: true,
            doAverage: true,
            dst16: conv0,
            pl: pl,
            fwdOff: fwdOff,
            bckOff: bckOff,
            useDistWtd: distWtd ? 1 : 0,
          );

          final s = _setup(
            scn.refW,
            scn.refH,
            scn.thisW,
            scn.thisH,
            mv[0],
            mv[1],
            px,
            py,
            scn.sx,
            scn.sy,
          );
          patch.put(_packPatch(ref1, s.bx0, s.by0, dut.pw, dut.ph));
          subXp.put(s.subX);
          subYp.put(s.subY);
          xStepP.put(s.xStep);
          yStepP.put(s.yStep);
          var packedDst = BigInt.zero;
          for (var i = 0; i < w * h; i++) {
            packedDst |= BigInt.from(conv0[i] & 0xFFFFFFFF) << (i * 32);
          }
          dst16.put(packedDst);
          if (distWtd) {
            fwd!.put(fwdOff);
            bck!.put(bckOff);
          }
          await clk.nextPosedge;
          final out = dut.output('pred').value;
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final idx = y * w + x;
              final got = out.getRange(idx * _bd, idx * _bd + _bd).toInt();
              if (got != pl[y][x]) {
                diffs++;
                expect(
                  got,
                  equals(pl[y][x]),
                  reason: '${scn.label} mv=$mv ($x,$y)',
                );
              }
            }
          }
          vectors++;
        }
      }
      expect(diffs, equals(0));
      // ignore: avoid_print
      print(
        '[scaled compound avg ${distWtd ? 'dist' : 'straight'}] '
        'vectors=$vectors diffs=$diffs',
      );
      await Simulator.endSimulation();
    });
  }

  for (final ss in [0, 1]) {
    test('HarborInterScaleSetupScaled matches _refScale/_scaledPos '
        '(subsampling=$ss)', () async {
      final dut = HarborInterScaleSetupScaled(sx: ss, sy: ss);
      final refW = Logic(name: 'ref_w', width: 16);
      final refH = Logic(name: 'ref_h', width: 16);
      final thisW = Logic(name: 'this_w', width: 16);
      final thisH = Logic(name: 'this_h', width: 16);
      final mvR = Logic(name: 'mv_row', width: 16);
      final mvC = Logic(name: 'mv_col', width: 16);
      final posX = Logic(name: 'pos_x', width: 16);
      final posY = Logic(name: 'pos_y', width: 16);
      dut.input('ref_w').srcConnection! <= refW;
      dut.input('ref_h').srcConnection! <= refH;
      dut.input('this_w').srcConnection! <= thisW;
      dut.input('this_h').srcConnection! <= thisH;
      dut.input('mv_row').srcConnection! <= mvR;
      dut.input('mv_col').srcConnection! <= mvC;
      dut.input('pos_x').srcConnection! <= posX;
      dut.input('pos_y').srcConnection! <= posY;
      await dut.build();
      Simulator.setMaxSimTime(600000000);
      unawaited(Simulator.run());

      int toS(LogicValue v) {
        final bl = v.width;
        final u = v.toBigInt();
        final signBit = BigInt.one << (bl - 1);
        return (u >= signBit ? u - (BigInt.one << bl) : u).toInt();
      }

      var vectors = 0, diffs = 0;
      final cfgs = <List<int>>[
        [64, 32, 48, 32],
        [64, 48, 32, 32],
        [48, 48, 40, 40],
        [128, 96, 96, 96],
        [64, 64, 64, 64], // no scale
      ];
      for (final c in cfgs) {
        final rW = c[0], rH = c[1], tW = c[2], tH = c[3];
        for (final mv in _mvs) {
          for (final pos in [
            [4, 4],
            [20, 12],
            [tW - w - 4, tH - h - 4],
          ]) {
            final s = _setup(
              rW,
              rH,
              tW,
              tH,
              mv[0],
              mv[1],
              pos[0],
              pos[1],
              ss,
              ss,
            );
            final (xfp, yfp, xStep, yStep, isScaled) = _refScale(
              rW,
              rH,
              tW,
              tH,
            );
            refW.put(rW);
            refH.put(rH);
            thisW.put(tW);
            thisH.put(tH);
            mvR.put(LogicValue.ofInt(mv[0], 16));
            mvC.put(LogicValue.ofInt(mv[1], 16));
            posX.put(pos[0]);
            posY.put(pos[1]);
            await Simulator.tick();

            void chk(String port, int want) {
              final got = dut.output(port).value.toInt();
              if (got != want) {
                diffs++;
                expect(got, equals(want), reason: 'cfg=$c mv=$mv $port');
              }
            }

            chk('x_scale_fp', xfp & 0xFFFF);
            chk('y_scale_fp', yfp & 0xFFFF);
            chk('x_step', xStep);
            chk('y_step', yStep);
            chk('is_scaled', isScaled ? 1 : 0);
            chk('sub_x', s.subX);
            chk('sub_y', s.subY);
            final gotBx0 = toS(dut.output('bx0').value);
            final gotBy0 = toS(dut.output('by0').value);
            if (gotBx0 != s.bx0) {
              diffs++;
              expect(gotBx0, equals(s.bx0), reason: 'cfg=$c mv=$mv bx0');
            }
            if (gotBy0 != s.by0) {
              diffs++;
              expect(gotBy0, equals(s.by0), reason: 'cfg=$c mv=$mv by0');
            }
            vectors++;
          }
        }
      }
      expect(diffs, equals(0));
      // ignore: avoid_print
      print('[scaled setup ss=$ss] vectors=$vectors diffs=$diffs');
      await Simulator.endSimulation();
    });
  }
}

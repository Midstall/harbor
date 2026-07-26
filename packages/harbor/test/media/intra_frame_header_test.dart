import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborIntraFrameHeader', () {
    late HarborIntraFrameHeader p;
    late Logic clk, bytes;
    final ctx = <String, Logic>{};

    Future<void> setUpDut() async {
      p = HarborIntraFrameHeader();
      clk = SimpleClockGenerator(10).clk;
      bytes = Logic(name: 'bytes', width: 128 * 8);
      p.input('bytes').srcConnection! <= bytes;
      for (final spec in [
        ('frame_size_override', 1),
        ('frame_width_bits_minus_1', 4),
        ('frame_height_bits_minus_1', 4),
        ('max_frame_width_minus_1', 16),
        ('max_frame_height_minus_1', 16),
        ('enable_superres', 1),
        ('num_planes', 2),
        ('separate_uv_delta_q', 1),
        ('subsampling_x', 1),
        ('subsampling_y', 1),
        ('use_128x128_superblock', 1),
        ('enable_cdef', 1),
        ('enable_restoration', 1),
        ('coded_lossless', 1),
        ('allow_intrabc', 1),
      ]) {
        final l = Logic(name: spec.$1, width: spec.$2);
        ctx[spec.$1] = l;
        p.input(spec.$1).srcConnection! <= l;
      }
      await p.build();
      bytes.inject(0);
      ctx.forEach((_, l) => l.inject(0));
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

    List<int> bytesOf(List<int> bits) {
      final out = List.filled(128, 0);
      for (var i = 0; i < bits.length && i < 1024; i++) {
        if (bits[i] != 0) out[i >> 3] |= 1 << (7 - (i & 7));
      }
      return out;
    }

    test('parses a full 1080p intra frame header', () async {
      await setUpDut();

      // Sequence context: 1080p, profile-0 4:2:0, 64-SB, all tools on.
      const maxWm1 = 1919, maxHm1 = 1079;
      ctx['frame_size_override']!.inject(0);
      ctx['frame_width_bits_minus_1']!.inject(10);
      ctx['frame_height_bits_minus_1']!.inject(10);
      ctx['max_frame_width_minus_1']!.inject(maxWm1);
      ctx['max_frame_height_minus_1']!.inject(maxHm1);
      ctx['enable_superres']!.inject(0);
      ctx['num_planes']!.inject(3);
      ctx['separate_uv_delta_q']!.inject(0);
      ctx['subsampling_x']!.inject(1);
      ctx['subsampling_y']!.inject(1);
      ctx['use_128x128_superblock']!.inject(0);
      ctx['enable_cdef']!.inject(1);
      ctx['enable_restoration']!.inject(1);
      ctx['coded_lossless']!.inject(0);
      ctx['allow_intrabc']!.inject(0);

      final bits = <int>[];
      void f(int v, int n) {
        for (var k = n - 1; k >= 0; k--) {
          bits.add((v >> k) & 1);
        }
      }

      // frame_size(): override 0, superres off -> 0 bits.
      // render_size(): different = 0 -> 1 bit.
      f(0, 1);
      // tile_info(): uniform=1, col break (0), row break (0). Single tile.
      f(1, 1);
      f(0, 1); // col increment break
      f(0, 1); // row increment break
      // quantization_params(): base_q=128, no deltas, no qmatrix.
      f(128, 8);
      f(0, 1); // y_dc delta_coded
      f(0, 1); // u_dc delta_coded
      f(0, 1); // u_ac delta_coded
      f(0, 1); // using_qmatrix
      // segmentation_enabled = 0.
      f(0, 1);
      // delta_q_params: base_q>0 -> delta_q_present = 0.
      f(0, 1);
      // loop_filter_params: levels + sharpness, delta disabled.
      f(32, 6);
      f(28, 6);
      f(20, 6);
      f(18, 6);
      f(1, 3); // sharpness
      f(0, 1); // delta_enabled
      // cdef_params: damping_m3=1, cdef_bits=0, one set.
      f(1, 2);
      f(0, 2);
      f(5, 4); // y_pri
      f(2, 2); // y_sec
      f(3, 4); // uv_pri
      f(1, 2); // uv_sec
      // lr_params: wiener luma, shift 0.
      f(2, 2); // plane 0 lr_type -> WIENER
      f(0, 2); // plane 1
      f(0, 2); // plane 2
      f(0, 1); // lr_unit_shift bit
      // read_tx_mode: tx_mode_select = 1 -> TX_MODE_SELECT.
      f(1, 1);

      bytes.inject(pack(bytesOf(bits)));
      await clk.nextPosedge;

      final miCols = 2 * ((1920 + 7) >> 3);
      final miRows = 2 * ((1080 + 7) >> 3);

      expect(p.output('frame_width').value.toInt(), equals(1920));
      expect(p.output('frame_height').value.toInt(), equals(1080));
      expect(p.output('mi_cols').value.toInt(), equals(miCols));
      expect(p.output('mi_rows').value.toInt(), equals(miRows));
      expect(p.output('render_width').value.toInt(), equals(1920));
      expect(p.output('render_height').value.toInt(), equals(1080));
      expect(p.output('tile_cols').value.toInt(), equals(1));
      expect(p.output('tile_rows').value.toInt(), equals(1));
      expect(p.output('base_q_idx').value.toInt(), equals(128));
      expect(p.output('segmentation_enabled').value.toInt(), equals(0));
      expect(p.output('delta_q_present').value.toInt(), equals(0));
      expect(p.output('loop_filter_level_0').value.toInt(), equals(32));
      expect(p.output('loop_filter_level_1').value.toInt(), equals(28));
      expect(p.output('cdef_bits').value.toInt(), equals(0));
      expect(p.output('cdef_damping').value.toInt(), equals(4));
      expect(p.output('frame_restoration_type_0').value.toInt(), equals(1));
      expect(p.output('uses_lr').value.toInt(), equals(1));
      expect(p.output('tx_mode').value.toInt(), equals(2));
      expect(p.output('bits_consumed').value.toInt(), equals(bits.length));
      await Simulator.endSimulation();
    });
  });
}

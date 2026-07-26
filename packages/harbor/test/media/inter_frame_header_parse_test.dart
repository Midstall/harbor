import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Bit-exact field-level check of HarborFrameHeaderParse on a REAL aomenc INTER
// frame (Phase 3, gate G1: inter uncompressed_header). The stream is a 2-frame
// 64x64 4:2:0 8-bit OBU: frame 0 = KEY, frame 1 = a single-reference INTER
// frame (single 64x64 NEWMV block, LAST_FRAME ref, SIMPLE motion, no
// compound / OBMC / warp / global-motion, use_ref_frame_mvs = 0). The golden
// below was captured from the conformant SW parseFrameHeader for the inter
// frame, the HDL must reproduce every bit-derived header field plus the exact
// bit cursor after the header.
//
// aomenc 3.12.1 invocation (single-ref, simple-motion inter):
//   aomenc --obu --cpu-used=4 --end-usage=q --cq-level=32 --limit=2 --passes=1
//     --kf-max-dist=30 --lag-in-frames=0 --enable-cdef=0 --enable-restoration=0
//     --enable-obmc=0 --enable-warped-motion=0 --enable-global-motion=0
//     --enable-ref-frame-mvs=0 --max-reference-frames=3
//   (source: a 64x64 gradient shifted by (dx=3,dy=2) between the two frames.)

// The inter frame OBU payload window fed to the HW parser (starts at the
// uncompressed_header), zero-padded to maxBytes.
const _window = [
  48,
  3,
  128,
  128,
  0,
  0,
  65,
  81,
  0,
  0,
  4,
  0,
  0,
  28,
  193,
  113,
  0,
  192,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
];

// Sequence-header parameters (SW-captured), injected as HW inputs.
const _seq = {
  'reduced': 0,
  'frameId': 0,
  'deltaIdM2': 0,
  'addIdM1': 0,
  'forceScreen': 2,
  'forceIntMv': 2,
  'orderHintBits': 7,
  'enableOrderHint': 1,
  'decModel': 0,
  'wBitsM1': 5,
  'hBitsM1': 5,
  'maxWM1': 63,
  'maxHM1': 63,
  'enableSuperres': 0,
  'use128': 0,
  'numPlanes': 3,
  'sepUv': 0,
  'enableCdef': 0,
  'enableRestoration': 0,
  'subX': 1,
  'subY': 1,
  'filmGrain': 0,
  'enableRefFrameMvs': 0,
  'enableWarpedMotion': 0,
};

// Golden inter-frame header fields, captured from the SW parseFrameHeader.
// Booleans are stored as 0/1.
const _exp = {
  'frame_type': 1,
  'frame_is_intra': 0,
  'show_frame': 1,
  'showable_frame': 1,
  'error_resilient_mode': 0,
  'disable_cdf_update': 0,
  'allow_screen_content_tools': 0,
  'force_integer_mv': 0,
  'order_hint': 1,
  'primary_ref_frame': 6,
  'refresh_frame_flags': 2,
  'frame_width': 64,
  'frame_height': 64,
  'upscaled_width': 64,
  'render_width': 64,
  'render_height': 64,
  'allow_high_precision_mv': 1,
  'is_filter_switchable': 0,
  'interpolation_filter': 0,
  'is_motion_mode_switchable': 0,
  'use_ref_frame_mvs': 0,
  'tile_cols_log2': 0,
  'tile_rows_log2': 0,
  'base_q_idx': 81,
  'segmentation_enabled': 0,
  'delta_q_present': 0,
  'coded_lossless': 0,
  'tx_mode': 1,
  'reduced_tx_set': 0,
  'reference_select': 0,
  'skip_mode_present': 0,
  'allow_warped_motion': 0,
};

const _refFrameIdx = [0, 0, 0, 0, 0, 0, 0];
const _bitsConsumed = 97;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const maxBytes = 64;

  test(
    'HarborFrameHeaderParse: bit-exact vs SW on a real INTER frame header',
    () async {
      final p = HarborFrameHeaderParse(maxBytes: maxBytes);
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final start = Logic(name: 'start');
      final bytes = Logic(name: 'bytes', width: maxBytes * 8);

      Logic li(String s, [int w = 1]) => Logic(name: s, width: w);
      final iReduced = li('i_reduced');
      final iFrameId = li('i_frame_id');
      final iDeltaIdM2 = li('i_delta_id', 4);
      final iAddIdM1 = li('i_add_id', 3);
      final iForceScreen = li('i_force_screen', 2);
      final iForceIntMv = li('i_force_int_mv', 2);
      final iOrderHintBits = li('i_order_hint_bits', 4);
      final iEnableOrderHint = li('i_enable_order_hint');
      final iDecModel = li('i_dec_model');
      final iWBitsM1 = li('i_w_bits', 4);
      final iHBitsM1 = li('i_h_bits', 4);
      final iMaxWM1 = li('i_max_w', 32);
      final iMaxHM1 = li('i_max_h', 32);
      final iEnableSuperres = li('i_enable_superres');
      final iUse128 = li('i_use128');
      final iNumPlanes = li('i_num_planes', 2);
      final iSepUv = li('i_sep_uv');
      final iEnableCdef = li('i_enable_cdef');
      final iEnableRestoration = li('i_enable_restoration');
      final iSubX = li('i_sub_x');
      final iSubY = li('i_sub_y');
      final iFilmGrain = li('i_film_grain');
      final iEnableRefFrameMvs = li('i_enable_ref_frame_mvs');
      final iEnableWarpedMotion = li('i_enable_warped_motion');

      void conn(String port, Logic sig) => p.input(port).srcConnection! <= sig;
      conn('clk', clk);
      conn('reset', reset);
      conn('start', start);
      conn('bytes', bytes);
      conn('seq_reduced_still_picture', iReduced);
      conn('seq_frame_id_numbers_present', iFrameId);
      conn('seq_delta_frame_id_length_minus2', iDeltaIdM2);
      conn('seq_additional_frame_id_length_minus1', iAddIdM1);
      conn('seq_force_screen_content_tools', iForceScreen);
      conn('seq_force_integer_mv', iForceIntMv);
      conn('seq_order_hint_bits', iOrderHintBits);
      conn('seq_enable_order_hint', iEnableOrderHint);
      conn('seq_decoder_model_info_present', iDecModel);
      conn('seq_frame_width_bits_minus1', iWBitsM1);
      conn('seq_frame_height_bits_minus1', iHBitsM1);
      conn('seq_max_frame_width_minus1', iMaxWM1);
      conn('seq_max_frame_height_minus1', iMaxHM1);
      conn('seq_enable_superres', iEnableSuperres);
      conn('seq_use_128x128_superblock', iUse128);
      conn('seq_num_planes', iNumPlanes);
      conn('seq_separate_uv_delta_q', iSepUv);
      conn('seq_enable_cdef', iEnableCdef);
      conn('seq_enable_restoration', iEnableRestoration);
      conn('seq_subsampling_x', iSubX);
      conn('seq_subsampling_y', iSubY);
      conn('seq_film_grain_params_present', iFilmGrain);
      conn('seq_enable_ref_frame_mvs', iEnableRefFrameMvs);
      conn('seq_enable_warped_motion', iEnableWarpedMotion);

      await p.build();

      BigInt pack(List<int> b) {
        var v = BigInt.zero;
        for (var i = 0; i < b.length; i++) {
          v |= BigInt.from(b[i] & 0xFF) << (i * 8);
        }
        return v;
      }

      reset.inject(1);
      start.inject(0);
      bytes.inject(pack(_window));
      iReduced.inject(_seq['reduced']!);
      iFrameId.inject(_seq['frameId']!);
      iDeltaIdM2.inject(_seq['deltaIdM2']!);
      iAddIdM1.inject(_seq['addIdM1']!);
      iForceScreen.inject(_seq['forceScreen']!);
      iForceIntMv.inject(_seq['forceIntMv']!);
      iOrderHintBits.inject(_seq['orderHintBits']!);
      iEnableOrderHint.inject(_seq['enableOrderHint']!);
      iDecModel.inject(_seq['decModel']!);
      iWBitsM1.inject(_seq['wBitsM1']!);
      iHBitsM1.inject(_seq['hBitsM1']!);
      iMaxWM1.inject(_seq['maxWM1']!);
      iMaxHM1.inject(_seq['maxHM1']!);
      iEnableSuperres.inject(_seq['enableSuperres']!);
      iUse128.inject(_seq['use128']!);
      iNumPlanes.inject(_seq['numPlanes']!);
      iSepUv.inject(_seq['sepUv']!);
      iEnableCdef.inject(_seq['enableCdef']!);
      iEnableRestoration.inject(_seq['enableRestoration']!);
      iSubX.inject(_seq['subX']!);
      iSubY.inject(_seq['subY']!);
      iFilmGrain.inject(_seq['filmGrain']!);
      iEnableRefFrameMvs.inject(_seq['enableRefFrameMvs']!);
      iEnableWarpedMotion.inject(_seq['enableWarpedMotion']!);

      Simulator.setMaxSimTime(200000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      await clk.nextPosedge;
      start.inject(0);
      var guard = 0;
      while (p.output('done').value.toInt() != 1) {
        await clk.nextPosedge;
        if (++guard > 4000) fail('inter header parse timeout');
      }

      int o(String name) => p.output(name).value.toInt();
      expect(
        o('unsupported'),
        equals(0),
        reason: 'inter header must be supported',
      );

      void chk(String name, int want, String label) =>
          expect(o(name), equals(want), reason: label);

      chk('frame_type', _exp['frame_type']!, 'frame_type');
      chk('frame_is_intra', _exp['frame_is_intra']!, 'frame_is_intra');
      chk('show_frame', _exp['show_frame']!, 'show_frame');
      chk('showable_frame', _exp['showable_frame']!, 'showable_frame');
      chk(
        'error_resilient_mode',
        _exp['error_resilient_mode']!,
        'error_resilient',
      );
      chk('disable_cdf_update', _exp['disable_cdf_update']!, 'disable_cdf');
      chk(
        'allow_screen_content_tools',
        _exp['allow_screen_content_tools']!,
        'screen',
      );
      chk('force_integer_mv', _exp['force_integer_mv']!, 'force_integer_mv');
      chk('order_hint', _exp['order_hint']!, 'order_hint');
      chk('primary_ref_frame', _exp['primary_ref_frame']!, 'primary_ref_frame');
      chk(
        'refresh_frame_flags',
        _exp['refresh_frame_flags']!,
        'refresh_frame_flags',
      );
      final refIdxPacked = p.output('ref_frame_idx').value.toBigInt();
      for (var i = 0; i < 7; i++) {
        final got = ((refIdxPacked >> (i * 3)) & BigInt.from(0x7)).toInt();
        expect(got, equals(_refFrameIdx[i]), reason: 'ref_frame_idx[$i]');
      }
      chk('frame_width', _exp['frame_width']!, 'frame_width');
      chk('frame_height', _exp['frame_height']!, 'frame_height');
      chk('upscaled_width', _exp['upscaled_width']!, 'upscaled_width');
      chk('render_width', _exp['render_width']!, 'render_width');
      chk('render_height', _exp['render_height']!, 'render_height');
      chk(
        'allow_high_precision_mv',
        _exp['allow_high_precision_mv']!,
        'high_prec_mv',
      );
      chk(
        'is_filter_switchable',
        _exp['is_filter_switchable']!,
        'is_filter_switchable',
      );
      chk(
        'interpolation_filter',
        _exp['interpolation_filter']!,
        'interp_filter',
      );
      chk(
        'is_motion_mode_switchable',
        _exp['is_motion_mode_switchable']!,
        'motion_mode_sw',
      );
      chk('use_ref_frame_mvs', _exp['use_ref_frame_mvs']!, 'use_ref_frame_mvs');
      chk('tile_cols_log2', _exp['tile_cols_log2']!, 'tile_cols_log2');
      chk('tile_rows_log2', _exp['tile_rows_log2']!, 'tile_rows_log2');
      chk('base_q_idx', _exp['base_q_idx']!, 'base_q_idx');
      chk(
        'segmentation_enabled',
        _exp['segmentation_enabled']!,
        'segmentation',
      );
      chk('delta_q_present', _exp['delta_q_present']!, 'delta_q_present');
      chk('coded_lossless', _exp['coded_lossless']!, 'coded_lossless');
      chk('tx_mode', _exp['tx_mode']!, 'tx_mode');
      chk('reduced_tx_set', _exp['reduced_tx_set']!, 'reduced_tx_set');
      chk('reference_select', _exp['reference_select']!, 'ref_select');
      chk('skip_mode_present', _exp['skip_mode_present']!, 'skip_mode_present');
      chk('allow_warped_motion', _exp['allow_warped_motion']!, 'allow_warped');
      expect(
        o('bits_consumed'),
        equals(_bitsConsumed),
        reason: 'bits_consumed after inter header',
      );

      await Simulator.endSimulation();
    },
  );
}

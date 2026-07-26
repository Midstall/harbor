import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cfl_predict.dart';
import 'intra_pred_avail.dart';
import 'inv_txfm.dart';
import 'recon_add.dart';

/// Harbor bit-exact AV1 chroma (U or V) intra reconstruction of ONE block.
///
/// Composes the intra predictor, the CfL apply step, the inverse transform and
/// the reconstruction add into the per-plane chroma reconstruction path:
///
///   1. `pred = predictIntraRaw(mode=uv_mode, ...)` - the chroma plane uses the
///      SAME intra prediction modes as luma. For CfL the base prediction is the
///      DC mode (UV_CFL_PRED maps to DC before predicting).
///   2. `if use_cfl: cflApply(pred, luma_ac, ...)` - CfL adds the luma AC
///      contribution onto the DC prediction.
///   3. `if !skip && eob>0: pred[i] = clip(pred[i] + resid[i])` where resid is
///      the inverse transform of the dequantized coeffs.
///
/// The intra predictor and CfL apply are combinational. The inverse transform
/// is the only clocked element (start/done handshake), so the block presents the
/// same interface: pulse `start` with all inputs valid, `done` asserts when
/// `recon` holds the reconstructed chroma block. When `skip`/`eob_zero` is set
/// no residual is added, but the transform still drives `done` (its result is
/// muxed out), so the handshake is uniform.
///
/// Ports (blocks packed row-major, LSB-first: pixel (r,c) at bit
/// `(r*bs + c)*8`):
///   in  clk / reset / start
///   out done
///   in  uv_mode        4b      chroma intra mode 0..12 (y-mode-like)
///   in  use_cfl        1b      1 => UV_CFL_PRED (base pred is DC + CfL AC)
///   in  have_above     1b      above neighbour availability
///   in  have_left      1b      left neighbour availability
///   in  above          bs*8    above neighbour pixels
///   in  left           bs*8    left neighbour pixels
///   in  above_left     8b      corner neighbour pixel
///   in  cfl_luma_ac    bs*bs*8 luma AC recon source for CfL (8b unsigned)
///   in  cfl_alpha_idx  8b      CfL alpha index (U in [7:4], V in [3:0])
///   in  cfl_signs      3b      CfL signs symbol (0..7)
///   in  plane          1b      0 => U (predType 0), 1 => V (predType 1)
///   in  tx_type        4b      TX_TYPE for the inverse transform
///   in  coeffs         bs*bs*16  dequantized residual (signed 16b)
///   in  skip           1b      block skip (no residual)
///   in  eob_zero       1b      no coded coeffs (no residual)
///   out recon          bs*bs*8 reconstructed chroma block (8b unsigned)
class HarborChromaReconBlock extends BridgeModule {
  /// Square chroma block size (4 or 8).
  final int bs;

  /// Sample bit depth (8/10/12): sets the chroma pixel width, the inverse-
  /// transform / dequant-coeff datapaths and the recon clip. bd 8 is
  /// byte-identical to the original.
  final int bitDepth;

  /// Per-pixel bit width of the CfL luma-AC source. The real 4:2:0 CfL AC is
  /// `(a+b+c+d) << 1` over the collocated 2x2 luma (up to 2040 at bd8, i.e. 11
  /// bits), so a real chroma path drives `cflAcBits` >= 11. Defaults to 8 (the
  /// historical width, exercised by chroma_recon_block_test with 8-bit AC).
  final int cflAcBits;

  HarborChromaReconBlock({
    this.bs = 4,
    this.bitDepth = 8,
    this.cflAcBits = 8,
    String? name,
  }) : assert(bs == 4 || bs == 8 || bs == 16, 'bs must be 4, 8 or 16'),
       assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
       assert(cflAcBits >= 8, 'cflAcBits must be >= 8'),
       super(
         'HarborChromaReconBlock',
         name: name ?? 'chroma_recon_block_${bs}_$bitDepth',
       ) {
    final n = bs * bs;
    final pw = bitDepth; // chroma pixel width
    final cw = bitDepth + 8; // dequant-coeff / residual element width
    // bs 4 -> TX_4X4 (0), bs 8 -> TX_8X8 (1), bs 16 -> TX_16X16 (2). All square
    // sizes the runtime-typed inverse transform supports (intra ext-tx set, no
    // flips). bs 16 is the full-resolution 4:4:4 chroma of a 16x16 luma leaf.
    final txSize = bs == 4 ? 0 : (bs == 8 ? 1 : 2);

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    addOutput('done');
    createPort('uv_mode', PortDirection.input, width: 4);
    createPort('use_cfl', PortDirection.input);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    createPort('cfl_luma_ac', PortDirection.input, width: n * cflAcBits);
    createPort('cfl_alpha_idx', PortDirection.input, width: 8);
    createPort('cfl_signs', PortDirection.input, width: 3);
    createPort('plane', PortDirection.input);
    createPort('tx_type', PortDirection.input, width: 4);
    createPort('coeffs', PortDirection.input, width: n * cw);
    createPort('skip', PortDirection.input);
    createPort('eob_zero', PortDirection.input);
    addOutput('recon', width: n * pw);

    final useCfl = input('use_cfl');

    // intra prediction
    // The base prediction mode is the chroma uv_mode, except for CfL which
    // predicts with DC mode (and then adds the CfL AC). So feed DC (0) when
    // use_cfl is set.
    final predMode = mux(useCfl, Const(0, width: 4), input('uv_mode'));
    final pred = HarborIntraPredAvail(
      bs: bs,
      bitDepth: bitDepth,
      name: 'intra',
    );
    addSubModule(pred);
    pred.input('mode').srcConnection! <= predMode;
    pred.input('have_above').srcConnection! <= input('have_above');
    pred.input('have_left').srcConnection! <= input('have_left');
    pred.input('above').srcConnection! <= input('above');
    pred.input('left').srcConnection! <= input('left');
    pred.input('above_left').srcConnection! <= input('above_left');
    final predPlain = pred.output('pred'); // n*8

    // CfL apply
    // dc_pred = the DC-mode prediction (== predPlain when use_cfl, since
    // predMode is DC then). recon = the luma AC source block.
    final cfl = HarborCflPredict(
      width: bs,
      height: bs,
      reconBits: cflAcBits,
      bitDepth: bitDepth,
      name: 'cfl',
    );
    addSubModule(cfl);
    cfl.input('dc_pred').srcConnection! <= predPlain;
    cfl.input('recon').srcConnection! <= input('cfl_luma_ac');
    cfl.input('alpha_idx').srcConnection! <= input('cfl_alpha_idx');
    cfl.input('signs').srcConnection! <= input('cfl_signs');
    cfl.input('plane').srcConnection! <= input('plane');
    final predCfl = cfl.output('pred'); // n*8

    // Final prediction: CfL-adjusted when use_cfl, else the plain mode predict.
    final prediction = mux(useCfl, predCfl, predPlain); // n*8

    // inverse transform
    final itx = HarborInvTxfm(
      txSize: txSize,
      txType: 0,
      runtimeTxType: true,
      bitDepth: bitDepth,
      name: 'itx',
    );
    addSubModule(itx);
    itx.input('clk').srcConnection! <= input('clk');
    itx.input('reset').srcConnection! <= input('reset');
    itx.input('start').srcConnection! <= input('start');
    itx.input('coeffs').srcConnection! <= input('coeffs');
    itx.input('tx_type').srcConnection! <= input('tx_type');
    output('done') <= itx.output('done');
    final residual = itx.output('residual'); // n*(bitDepth+8)

    // reconstruction add
    // recon = clip(prediction + residual). Gate the residual to zero when the
    // block is skipped / has no coded coeffs, so recon == prediction.
    final addResidual = ~(input('skip') | input('eob_zero'));
    final gatedResidual = mux(
      addResidual,
      residual,
      Const(0, width: residual.width),
    );
    final add = HarborReconAdd(n: n, bitDepth: bitDepth, name: 'add');
    addSubModule(add);
    add.input('pred').srcConnection! <= prediction;
    add.input('residual').srcConnection! <= gatedResidual;
    output('recon') <= add.output('recon');
  }
}

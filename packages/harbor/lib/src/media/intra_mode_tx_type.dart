import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 intra-mode -> transform-type mapping.
///
/// For intra blocks with the default (mode-dependent) transform, the TX_TYPE is
/// looked up from the prediction mode. This module returns the AV1 `tx_type`
/// (0=DCT_DCT, 1=ADST_DCT, 2=DCT_ADST, 3=ADST_ADST) and splits it into the
/// per-direction transform selects the transform engine uses: `v_type` (vertical
/// / column transform) and `h_type` (horizontal / row transform), where 0=DCT,
/// 1=ADST. So a decoded intra mode drives the inverse transform directly.
///
/// Combinational. Mapping (DC,V,H,D45,D135,D113,D157,D203,D67,SMOOTH,SMOOTH_V,
/// SMOOTH_H,PAETH) -> {DCT_DCT, ADST_DCT, DCT_ADST, DCT_DCT, ADST_ADST,
/// ADST_DCT, DCT_ADST, DCT_ADST, ADST_DCT, ADST_ADST, ADST_DCT, DCT_ADST,
/// ADST_ADST}.
class HarborIntraModeTxType extends BridgeModule {
  static const _txType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];

  HarborIntraModeTxType({String? name})
    : super('HarborIntraModeTxType', name: name ?? 'intra_mode_tx_type') {
    createPort('intra_mode', PortDirection.input, width: 4);
    addOutput('tx_type', width: 2);
    addOutput('v_type', width: 2); // 0=DCT, 1=ADST
    addOutput('h_type', width: 2);

    final mode = input('intra_mode');
    Logic tt = Const(0, width: 2);
    for (var m = _txType.length - 1; m >= 0; m--) {
      tt = mux(mode.eq(Const(m, width: 4)), Const(_txType[m], width: 2), tt);
    }
    output('tx_type') <= tt;
    output('v_type') <=
        tt[0].zeroExtend(2); // ADST_DCT / ADST_ADST -> vertical ADST
    output('h_type') <=
        tt[1].zeroExtend(2); // DCT_ADST / ADST_ADST -> horizontal ADST
  }
}

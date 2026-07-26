import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_mode_tx_type.dart';
import 'max_tx_size.dart';
import 'tx_size_geom.dart';

/// Harbor AV1 per-block attribute derivation.
///
/// Once the partition tree emits a leaf block (size) and its intra mode is
/// decoded, the reconstruct path needs the transform attributes. This composes
/// the verified lookups into one unit: the block's maximum transform size
/// ([HarborMaxTxSize]), that transform's pixel geometry and log2s
/// ([HarborTxSizeGeom]), and the mode-derived transform type with the per-
/// direction DCT/ADST selects ([HarborIntraModeTxType]) that drive the inverse
/// transform. Combinational.
///
/// (Uses the largest transform for the block. Per-block tx-size signalling
/// under TX_MODE_SELECT is a follow-up that overrides `tx_size` before geometry.)
class HarborBlockAttributes extends BridgeModule {
  HarborBlockAttributes({String? name})
    : super('HarborBlockAttributes', name: name ?? 'block_attrs') {
    createPort('bsize', PortDirection.input, width: 5);
    createPort('intra_mode', PortDirection.input, width: 4);
    addOutput('tx_size', width: 5);
    addOutput('tx_width', width: 8);
    addOutput('tx_height', width: 8);
    addOutput('tx_width_log2', width: 3);
    addOutput('tx_height_log2', width: 3);
    addOutput('tx_type', width: 2);
    addOutput('v_type', width: 2);
    addOutput('h_type', width: 2);

    final maxTx = HarborMaxTxSize(name: 'max_tx');
    addSubModule(maxTx);
    maxTx.input('bsize').srcConnection! <= input('bsize');
    final txSize = maxTx.output('tx_size');

    final geom = HarborTxSizeGeom(name: 'geom');
    addSubModule(geom);
    geom.input('tx_size').srcConnection! <= txSize;

    final txType = HarborIntraModeTxType(name: 'tx_type');
    addSubModule(txType);
    txType.input('intra_mode').srcConnection! <= input('intra_mode');

    output('tx_size') <= txSize;
    output('tx_width') <= geom.output('tx_width');
    output('tx_height') <= geom.output('tx_height');
    output('tx_width_log2') <= geom.output('tx_width_log2');
    output('tx_height_log2') <= geom.output('tx_height_log2');
    output('tx_type') <= txType.output('tx_type');
    output('v_type') <= txType.output('v_type');
    output('h_type') <= txType.output('h_type');
  }
}

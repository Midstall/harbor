import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';

/// Harbor AV1 intra mode-info decoder (keyframe block: skip + Y/UV mode).
///
/// Decodes the per-block intra mode_info syntax with the real od_ec arithmetic
/// coder: a `skip` flag (2 symbols), the luma `y_mode` (13 symbols), then the
/// chroma `uv_mode` (13 symbols), each from its own adaptive CDF context. The
/// CDF *values* are runtime data loaded into the od_ec context memory (here the
/// defaults are uniform, the real AV1 default CDFs + the neighbour-derived
/// context selection are loaded by the frame setup). The decode *syntax*, which
/// symbols, in what order, from which contexts, with the issue/capture timing
/// the od_ec needs, is what this module implements and is verified against an
/// od_ec reference.
///
/// FSM: sIdle -> sLoad (load the 3 CDFs + init the window) -> per symbol
/// sIssue (pulse decode) / sCapture (read the registered symbol) -> sDone.
/// `bytes_in` (3 bytes, MSB first) feeds the coder. The environment advances by
/// `byte_pop`. SCOPE: angle deltas, palette, CfL, filter-intra and tx_size are
/// follow-ups, one context per element (no neighbour context yet).
class HarborIntraModeInfo extends BridgeModule {
  HarborIntraModeInfo({String? name})
    : super('HarborIntraModeInfo', name: name ?? 'intra_mode_info') {
    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('bytes_in', PortDirection.input, width: 24);
    addOutput('byte_pop', width: 2);
    addOutput('skip', width: 1);
    addOutput('y_mode', width: 4);
    addOutput('uv_mode', width: 4);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

    // Default CDFs (uniform) packed as 16 symbols x 16 bits = 256 bits.
    BigInt packIcdf(List<int> icdf) {
      var v = BigInt.zero;
      for (var s = 0; s < 16; s++) {
        v |= BigInt.from((s < icdf.length ? icdf[s] : 0) & 0xFFFF) << (s * 16);
      }
      return v;
    }

    List<int> uniform(int n) => [
      for (var i = 0; i < n; i++) 32768 - ((i + 1) * 32768 / n).round(),
    ];

    final cdfs = [
      packIcdf(uniform(2)), // skip
      packIcdf(uniform(13)), // y_mode
      packIcdf(uniform(13)), // uv_mode
    ];
    final numSyms = [2, 13, 13];

    final state = Logic(name: 'state', width: 3);
    final loadIdx = Logic(name: 'load_idx', width: 2);
    final symIdx = Logic(name: 'sym_idx', width: 2);
    final skipReg = Logic(name: 'skip_r');
    final yReg = Logic(name: 'y_r', width: 4);
    final uvReg = Logic(name: 'uv_r', width: 4);

    const sIdle = 0, sLoad = 1, sIssue = 2, sCapture = 3, sDone = 4;

    final od = HarborOdEcDecoder(name: 'od');
    addSubModule(od);

    final inLoad = state.eq(Const(sLoad, width: 3));
    final issuing = state.eq(Const(sIssue, width: 3));

    Logic mux3(Logic sel, List<int> vals, int w) {
      Logic out = Const(vals[0], width: w);
      for (var i = 1; i < vals.length; i++) {
        out = mux(sel.eq(Const(i, width: 2)), Const(vals[i], width: w), out);
      }
      return out;
    }

    od.input('clk').srcConnection! <= clk;
    od.input('reset').srcConnection! <= reset;
    od.input('init').srcConnection! <=
        (inLoad & loadIdx.eq(Const(0, width: 2)));
    od.input('load').srcConnection! <= inLoad;
    od.input('decode').srcConnection! <= issuing;
    // Context: the load index while loading, else the current symbol index.
    od.input('ctx').srcConnection! <=
        mux(inLoad, loadIdx, symIdx).zeroExtend(od.input('ctx').width);
    Logic cdfMux(Logic sel) {
      Logic out = Const(cdfs[0], width: 256);
      for (var i = 1; i < cdfs.length; i++) {
        out = mux(sel.eq(Const(i, width: 2)), Const(cdfs[i], width: 256), out);
      }
      return out;
    }

    od.input('cdf').srcConnection! <= cdfMux(loadIdx);
    od.input('num_syms').srcConnection! <= mux3(loadIdx, numSyms, 5);
    od.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= od.output('byte_pop');

    final sym = od.output('symbol');

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          loadIdx < Const(0, width: 2),
          symIdx < Const(0, width: 2),
          skipReg < Const(0),
          yReg < Const(0, width: 4),
          uvReg < Const(0, width: 4),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  loadIdx < Const(0, width: 2),
                  symIdx < Const(0, width: 2),
                  state < Const(sLoad, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 3), [
              If(
                loadIdx.eq(Const(2, width: 2)),
                then: [state < Const(sIssue, width: 3)],
                orElse: [
                  loadIdx < (loadIdx + Const(1, width: 2)).getRange(0, 2),
                ],
              ),
            ]),
            CaseItem(Const(sIssue, width: 3), [
              state < Const(sCapture, width: 3),
            ]),
            CaseItem(Const(sCapture, width: 3), [
              // Symbol is registered now. Store by current symIdx.
              If(
                symIdx.eq(Const(0, width: 2)),
                then: [skipReg < sym.getRange(0, 1)],
              ),
              If(
                symIdx.eq(Const(1, width: 2)),
                then: [yReg < sym.getRange(0, 4)],
              ),
              If(
                symIdx.eq(Const(2, width: 2)),
                then: [uvReg < sym.getRange(0, 4)],
              ),
              If(
                symIdx.eq(Const(2, width: 2)),
                then: [state < Const(sDone, width: 3)],
                orElse: [
                  symIdx < (symIdx + Const(1, width: 2)).getRange(0, 2),
                  state < Const(sIssue, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 3), [state < Const(sDone, width: 3)]),
          ]),
        ],
      ),
    ]);

    output('skip') <= skipReg;
    output('y_mode') <= yReg;
    output('uv_mode') <= uvReg;
    output('done') <= state.eq(Const(sDone, width: 3));
  }
}

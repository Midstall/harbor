import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';
import 'partition_tree.dart';

/// Harbor AV1 decode_tile: partition + per-block mode/coeff over ONE od_ec.
///
/// This is the unified tile-decode core. A single arithmetic-coder window drives
/// the whole tile: the partition tree walks the superblock, and every partition
/// symbol AND every leaf block's syntax (skip, y_mode, uv_mode, eob, per-coeff
/// base + sign) are decoded from the same window in stream order, with all the
/// CDFs persisting and adapting across the tile. When the tree presents a block
/// (`query`) the engine decodes its partition. When the tree emits a leaf it
/// decodes that block (stalling the tree via emit_ack) before the next
/// partition, exactly AV1's interleaving.
///
/// Each completed leaf pulses `block_valid` with its position/size and decoded
/// skip/mode/eob, coefficients read via `coeff_addr`. CDF values are runtime
/// data (uniform defaults, real AV1 defaults + neighbour contexts load as data),
/// the decode structure is the verified logic. Simplifications (raster coeffs,
/// one context per element, no range/golomb tail, no tx_size/angle/cfl) match
/// the standalone block decoder and are follow-ups.
class HarborDecodeTile extends BridgeModule {
  HarborDecodeTile({int maxCoeffs = 16, int depth = 32, String? name})
    : super('HarborDecodeTile', name: name ?? 'decode_tile') {
    final addrW = maxCoeffs.bitLength;

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('sb_r', PortDirection.input, width: 16);
    createPort('sb_c', PortDirection.input, width: 16);
    createPort('sb_size', PortDirection.input, width: 5);
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort('bytes_in', PortDirection.input, width: 24);
    createPort('coeff_addr', PortDirection.input, width: addrW);
    addOutput('byte_pop', width: 2);
    addOutput('block_valid', width: 1);
    addOutput('blk_r', width: 16);
    addOutput('blk_c', width: 16);
    addOutput('blk_bsize', width: 5);
    addOutput('skip', width: 1);
    addOutput('y_mode', width: 4);
    addOutput('uv_mode', width: 4);
    addOutput('eob', width: addrW + 1);
    addOutput('coeff_out', width: 8);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

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

    // Contexts: 0 partition(10), 1 skip(2), 2 y(13), 3 uv(13), 4 eob(maxCoeffs),
    // 5 base(4), 6 sign(2).
    final ctxCdf = [
      uniform(10),
      uniform(2),
      uniform(13),
      uniform(13),
      uniform(maxCoeffs),
      uniform(4),
      uniform(2),
    ];
    final ctxNsyms = [10, 2, 13, 13, maxCoeffs, 4, 2];
    final numCtx = ctxCdf.length;

    final state = Logic(name: 'state', width: 3);
    final loadIdx = Logic(name: 'load_idx', width: 3);
    final op = Logic(name: 'op'); // 0 = partition, 1 = block
    final phase = Logic(name: 'phase', width: 3); // 0 skip..5 sign
    final coeffIdx = Logic(name: 'coeff_idx', width: addrW + 1);
    final skipReg = Logic(name: 'skip_r');
    final yReg = Logic(name: 'y_r', width: 4);
    final uvReg = Logic(name: 'uv_r', width: 4);
    final eobReg = Logic(name: 'eob_r', width: addrW + 1);
    final baseReg = Logic(name: 'base_r', width: 3);
    final blkR = Logic(name: 'blk_r_r', width: 16);
    final blkC = Logic(name: 'blk_c_r', width: 16);
    final blkB = Logic(name: 'blk_b_r', width: 5);
    final coeffs = [
      for (var i = 0; i < maxCoeffs; i++) Logic(name: 'coeff$i', width: 8),
    ];

    const sIdle = 0,
        sLoad = 1,
        sStart = 2,
        sRun = 3,
        sIssue = 4,
        sCap = 5,
        sBlockDone = 6,
        sDone = 7;
    const pSkip = 0, pY = 1, pUv = 2, pEob = 3, pBase = 4, pSign = 5;

    final od = HarborOdEcDecoder(name: 'od');
    addSubModule(od);
    final tree = HarborPartitionTree(depth: depth, name: 'pt');
    addSubModule(tree);

    final queryValid = tree.output('query_valid');
    final emitValidT = tree.output('emit_valid');
    final treeDone = tree.output('done');
    final sym = od.output('symbol');

    final inLoad = state.eq(Const(sLoad, width: 3));
    final issuing = state.eq(Const(sIssue, width: 3));
    final isPart = ~op; // op == 0
    // Context to decode: partition (0) or the block phase (phase + 1).
    final decCtx = mux(
      inLoad,
      loadIdx,
      mux(
        isPart,
        Const(0, width: 3),
        (phase + Const(1, width: 3)).getRange(0, 3),
      ),
    );

    Logic muxN(Logic sel, List<int> vals, int w) {
      Logic out = Const(vals[0], width: w);
      for (var i = 1; i < vals.length; i++) {
        out = mux(sel.eq(Const(i, width: 3)), Const(vals[i], width: w), out);
      }
      return out;
    }

    Logic cdfMux(Logic sel) {
      Logic out = Const(packIcdf(ctxCdf[0]), width: 256);
      for (var i = 1; i < numCtx; i++) {
        out = mux(
          sel.eq(Const(i, width: 3)),
          Const(packIcdf(ctxCdf[i]), width: 256),
          out,
        );
      }
      return out;
    }

    od.input('clk').srcConnection! <= clk;
    od.input('reset').srcConnection! <= reset;
    od.input('init').srcConnection! <=
        (inLoad & loadIdx.eq(Const(0, width: 3)));
    od.input('load').srcConnection! <= inLoad;
    od.input('decode').srcConnection! <= issuing;
    od.input('ctx').srcConnection! <= decCtx.zeroExtend(od.input('ctx').width);
    od.input('cdf').srcConnection! <= cdfMux(loadIdx);
    od.input('num_syms').srcConnection! <= muxN(loadIdx, ctxNsyms, 5);
    od.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= od.output('byte_pop');

    final lastCoeff = (coeffIdx + Const(1, width: addrW + 1))
        .getRange(0, addrW + 1)
        .eq(eobReg);
    // A block finishes in sBlockDone (one cycle after the final register write),
    // so all outputs are committed when block_valid / emit_ack fire.
    final blockDone = state.eq(Const(sBlockDone, width: 3));

    final signedLevel = baseReg.zeroExtend(8);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          loadIdx < Const(0, width: 3),
          op < Const(0),
          phase < Const(0, width: 3),
          coeffIdx < Const(0, width: addrW + 1),
          skipReg < Const(0),
          yReg < Const(0, width: 4),
          uvReg < Const(0, width: 4),
          eobReg < Const(0, width: addrW + 1),
          baseReg < Const(0, width: 3),
          blkR < Const(0, width: 16),
          blkC < Const(0, width: 16),
          blkB < Const(0, width: 5),
          for (final c in coeffs) c < Const(0, width: 8),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  loadIdx < Const(0, width: 3),
                  state < Const(sLoad, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 3), [
              If(
                loadIdx.eq(Const(numCtx - 1, width: 3)),
                then: [state < Const(sStart, width: 3)],
                orElse: [
                  loadIdx < (loadIdx + Const(1, width: 3)).getRange(0, 3),
                ],
              ),
            ]),
            CaseItem(Const(sStart, width: 3), [state < Const(sRun, width: 3)]),
            CaseItem(Const(sRun, width: 3), [
              If(
                treeDone,
                then: [state < Const(sDone, width: 3)],
                orElse: [
                  If(
                    queryValid,
                    then: [
                      op < Const(0), // partition
                      state < Const(sIssue, width: 3),
                    ],
                    orElse: [
                      If(
                        emitValidT,
                        then: [
                          op < Const(1), // block
                          phase < Const(pSkip, width: 3),
                          coeffIdx < Const(0, width: addrW + 1),
                          eobReg <
                              Const(
                                0,
                                width: addrW + 1,
                              ), // skipped blocks -> eob 0
                          blkR < tree.output('emit_r'),
                          blkC < tree.output('emit_c'),
                          blkB < tree.output('emit_bsize'),
                          for (final c in coeffs) c < Const(0, width: 8),
                          state < Const(sIssue, width: 3),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sIssue, width: 3), [state < Const(sCap, width: 3)]),
            CaseItem(Const(sCap, width: 3), [
              If(
                ~op,
                then: [
                  // Partition symbol captured, tree consumes via partition_valid.
                  state < Const(sRun, width: 3),
                ],
                orElse: [
                  // Block phase.
                  Case(phase, [
                    CaseItem(Const(pSkip, width: 3), [
                      skipReg < sym.getRange(0, 1),
                      phase < Const(pY, width: 3),
                      state < Const(sIssue, width: 3),
                    ]),
                    CaseItem(Const(pY, width: 3), [
                      yReg < sym.getRange(0, 4),
                      phase < Const(pUv, width: 3),
                      state < Const(sIssue, width: 3),
                    ]),
                    CaseItem(Const(pUv, width: 3), [
                      uvReg < sym.getRange(0, 4),
                      If(
                        skipReg,
                        then: [state < Const(sBlockDone, width: 3)],
                        orElse: [
                          phase < Const(pEob, width: 3),
                          state < Const(sIssue, width: 3),
                        ],
                      ),
                    ]),
                    CaseItem(Const(pEob, width: 3), [
                      eobReg < sym.zeroExtend(addrW + 1),
                      If(
                        ~sym.or(),
                        then: [state < Const(sBlockDone, width: 3)],
                        orElse: [
                          coeffIdx < Const(0, width: addrW + 1),
                          phase < Const(pBase, width: 3),
                          state < Const(sIssue, width: 3),
                        ],
                      ),
                    ]),
                    CaseItem(Const(pBase, width: 3), [
                      baseReg < sym.getRange(0, 3),
                      If(
                        sym.getRange(0, 3).or(),
                        then: [
                          phase < Const(pSign, width: 3),
                          state < Const(sIssue, width: 3),
                        ],
                        orElse: [
                          If(
                            lastCoeff,
                            then: [state < Const(sBlockDone, width: 3)],
                            orElse: [
                              coeffIdx <
                                  (coeffIdx + Const(1, width: addrW + 1))
                                      .getRange(0, addrW + 1),
                              phase < Const(pBase, width: 3),
                              state < Const(sIssue, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ]),
                    CaseItem(Const(pSign, width: 3), [
                      for (var i = 0; i < maxCoeffs; i++)
                        If(
                          coeffIdx.eq(Const(i, width: addrW + 1)),
                          then: [
                            coeffs[i] <
                                mux(
                                  sym.getRange(0, 1),
                                  (Const(0, width: 8) - signedLevel).getRange(
                                    0,
                                    8,
                                  ),
                                  signedLevel,
                                ),
                          ],
                        ),
                      If(
                        lastCoeff,
                        then: [state < Const(sBlockDone, width: 3)],
                        orElse: [
                          coeffIdx <
                              (coeffIdx + Const(1, width: addrW + 1)).getRange(
                                0,
                                addrW + 1,
                              ),
                          phase < Const(pBase, width: 3),
                          state < Const(sIssue, width: 3),
                        ],
                      ),
                    ]),
                  ]),
                ],
              ),
            ]),
            CaseItem(Const(sBlockDone, width: 3), [
              state < Const(sRun, width: 3),
            ]),
            CaseItem(Const(sDone, width: 3), [state < Const(sDone, width: 3)]),
          ]),
        ],
      ),
    ]);

    // Tree wiring.
    tree.input('clk').srcConnection! <= clk;
    tree.input('reset').srcConnection! <= reset;
    tree.input('start').srcConnection! <= state.eq(Const(sStart, width: 3));
    tree.input('sb_r').srcConnection! <= input('sb_r');
    tree.input('sb_c').srcConnection! <= input('sb_c');
    tree.input('sb_size').srcConnection! <= input('sb_size');
    tree.input('mi_rows').srcConnection! <= input('mi_rows');
    tree.input('mi_cols').srcConnection! <= input('mi_cols');
    tree.input('partition_in').srcConnection! <= sym.getRange(0, 4);
    tree.input('partition_valid').srcConnection! <=
        (state.eq(Const(sCap, width: 3)) & ~op);
    tree.input('emit_ack').srcConnection! <= blockDone;

    // coeff read.
    Logic coeffRead = Const(0, width: 8);
    for (var i = 0; i < maxCoeffs; i++) {
      coeffRead = mux(
        input('coeff_addr').eq(Const(i, width: addrW)),
        coeffs[i],
        coeffRead,
      );
    }

    output('block_valid') <= blockDone;
    output('blk_r') <= blkR;
    output('blk_c') <= blkC;
    output('blk_bsize') <= blkB;
    output('skip') <= skipReg;
    output('y_mode') <= yReg;
    output('uv_mode') <= uvReg;
    output('eob') <= eobReg;
    output('coeff_out') <= coeffRead;
    output('done') <= state.eq(Const(sDone, width: 3));
  }
}

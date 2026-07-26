library;

import 'package:rohd/rohd.dart';

/// Balanced mux-tree select: `entries[index]`.
Logic _sel(Logic index, List<Logic> entries) {
  if (entries.length == 1) return entries[0];
  final next = <Logic>[];
  for (var i = 0; i < entries.length; i += 2) {
    next.add(
      i + 1 < entries.length
          ? mux(index[0], entries[i + 1], entries[i])
          : entries[i],
    );
  }
  return _sel(index.getRange(1, index.width), next);
}

/// A single-write-port, single-registered-read-port block RAM: the raw dual-port
/// primitive (direct wr/rd ports, NOT a Wishbone peripheral like [HarborSram]),
/// sized for on-chip buffers such as a KV cache, an accumulator bank, or a result
/// FIFO.
///
/// It uses the `Module with SystemVerilog` split so it both SIMULATES and maps to
/// a real block RAM per FPGA vendor:
///   * the ROHD body is a behavioral flop-array memory with a REGISTERED read
///     (read data lands one cycle after the address: readLatency == 1), which
///     runs in the ROHD Simulator so tests exercise the exact hardware latency.
///   * [definitionVerilog] emits a plain INFERRABLE SystemVerilog memory
///     (`logic [W-1:0] mem [0:D-1]` with a synchronous write and a registered
///     read). The registered read is the block-RAM inference template on both
///     families, so yosys `synth_ecp5` infers a Lattice DP16KD and `synth_xilinx`
///     infers a Xilinx RAMB. The flop array never reaches silicon, only the
///     block RAM does. The emitted SV is vendor-neutral, so this primitive is
///     multitarget without a per-vendor branch.
///
/// Read/write share one clock. On a same-address, same-cycle read+write the read
/// returns the OLD value in both the sim model and the emitted always_ff, so the
/// two stay consistent. EXCEPT that an inferred block RAM returns UNDEFINED on
/// that collision on real silicon. A read-modify-write bank whose ports can hit
/// the same address in one cycle (e.g. a fp32 accumulator when a slow memory read
/// stalls the pipeline) must set [useFlops] to keep the deterministic flop body.
class HarborBram extends Module with SystemVerilog {
  final int width;
  final int depth;
  final int addrWidth;

  /// When true, DO NOT emit the inferrable [definitionVerilog]. Keep the flop-
  /// array body so synth maps this to fabric FLOPS. Needed for a read-modify-
  /// write bank whose read and write ports can hit the SAME address in one cycle:
  /// an inferred block RAM returns UNDEFINED on that collision while the flop
  /// model (and the required silicon behavior) is deterministic.
  final bool useFlops;

  /// Registered read data, one cycle behind [rd_addr] (readLatency == 1).
  Logic get rdData => output('rd_data');

  HarborBram(
    Logic clk, {
    required this.width,
    required this.depth,
    required Logic wrEn,
    required Logic wrAddr,
    required Logic wrData,
    required Logic rdAddr,
    String? name,
    this.useFlops = false,
  }) : addrWidth = (depth - 1).bitLength.clamp(1, 32),
       super(
         name: name ?? 'harbor_bram',
         // Distinct stable definition name per shape so the emitted SV file name
         // and the instantiation agree (two different-shaped RAMs are different
         // modules, same-shape RAMs dedupe to one).
         definitionName: 'HarborBram_${width}x$depth',
         reserveDefinitionName: true,
       ) {
    final aw = addrWidth;
    clk = addInput('clk', clk);
    wrEn = addInput('wr_en', wrEn);
    wrAddr = addInput('wr_addr', wrAddr, width: aw);
    wrData = addInput('wr_data', wrData, width: width);
    rdAddr = addInput('rd_addr', rdAddr, width: aw);
    final rd = addOutput('rd_data', width: width);

    // Replaced wholesale by [definitionVerilog] in synth, so these flops never
    // reach the netlist. They only give the Simulator a correct 1-cycle-latency
    // memory to verify the replay timing against.
    final cells = [
      for (var i = 0; i < depth; i++) Logic(name: 'cell$i', width: width),
    ];
    final rdReg = Logic(name: 'rd_reg', width: width);
    final rdSel = _sel(rdAddr, cells);
    Sequential(clk, [
      rdReg < rdSel,
      for (var i = 0; i < depth; i++)
        If(wrEn & wrAddr.eq(Const(i, width: aw)), then: [cells[i] < wrData]),
    ]);
    rd <= rdReg;
  }

  @override
  String? definitionVerilog(String definitionType) => useFlops
      ? null // keep the flop-array body -> synth maps to fabric flops (no BRAM)
      : '''
module $definitionType (
  input logic clk,
  input logic wr_en,
  input logic [${addrWidth - 1}:0] wr_addr,
  input logic [${width - 1}:0] wr_data,
  input logic [${addrWidth - 1}:0] rd_addr,
  output logic [${width - 1}:0] rd_data
);
  // Simple dual-port RAM: one synchronous write, one registered read
  // (readLatency == 1). yosys infers this as a block RAM (DP16KD on ECP5,
  // RAMB on Xilinx).
  logic [${width - 1}:0] mem [0:${depth - 1}];
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
    rd_data <= mem[rd_addr];
  end
endmodule''';
}

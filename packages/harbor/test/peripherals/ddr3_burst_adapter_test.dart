import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_burst_adapter.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Unit-tests the 32<->128 burst adapter against a procedural mock of the
/// [Ddr3Controller]'s wide pipelined side (always-accept, byte-masked backing
/// store, fixed read-ack latency). Verifies narrow words land in / come from the
/// correct lane of the wide burst without clobbering neighbours (DM masking).
void main() {
  tearDown(() async => Simulator.reset());

  test('narrow 32b writes/reads map to the right 128b burst lane', () async {
    const busAddrW = 24, ddrAddrW = 24;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final sCyc = Logic()..inject(0);
    final sStb = Logic()..inject(0);
    final sWe = Logic()..inject(0);
    final sAddr = Logic(width: busAddrW)..inject(0);
    final sData = Logic(width: 32)..inject(0);
    final sSel = Logic(width: 4)..inject(0);
    final mStall = Logic()..inject(0); // always accept
    final mAck = Logic()..inject(0);
    final mData = Logic(width: 128)..inject(0);

    final dut = Ddr3BurstAdapter(
      busAddrWidth: busAddrW,
      ddrAddrWidth: ddrAddrW,
      clk: clk,
      reset: reset,
      sCyc: sCyc,
      sStb: sStb,
      sWe: sWe,
      sAddr: sAddr,
      sData: sData,
      sSel: sSel,
      mStall: mStall,
      mAck: mAck,
      mData: mData,
    );
    await dut.build();

    // Procedural mock of the wide controller side.
    final mem = <int, BigInt>{}; // burst addr -> 128-bit word
    final pendingReads = <List<int>>[]; // [addr, cyclesLeft]
    // Models the controller's write pipeline: a write only reaches DRAM if cyc
    // stays asserted long enough for it to flush; if cyc drops early the
    // controller ABORTS it (o_wb_cyc gates s1/s2 pending). This is exactly the
    // regression the WRITE_DRAIN state fixes - without cyc held, writes abort.
    const wrDrainNeeded = 4;
    Map<String, dynamic>? pendingWrite;
    Timer? _; // silence unused

    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());

    // Mock: every posedge, service the adapter's wide master port.
    clk.posedge.listen((_) {
      // default: no ack this cycle unless a pending read matures.
      mAck.inject(0);
      final cyc = dut.output('m_cyc').value.toInt();
      // accept a command (mStall held 0).
      if (cyc == 1 && dut.output('m_stb').value.toInt() == 1) {
        final addr = dut.output('m_addr').value.toInt();
        if (dut.output('m_we').value.toInt() == 1) {
          // capture the write, but DON'T commit yet: it must survive the drain.
          pendingWrite ??= {
            'addr': addr,
            'data': dut.output('m_data_out').value.toBigInt(),
            'sel': dut.output('m_sel').value.toInt(),
            'left': wrDrainNeeded,
          };
        } else {
          pendingReads.add([addr, 3]); // 3-cycle read latency
        }
      }
      // in-flight write: commit iff cyc stays high through the drain; else abort.
      if (pendingWrite != null) {
        if (cyc == 0) {
          pendingWrite =
              null; // cyc dropped early -> controller aborts the write
        } else {
          pendingWrite!['left'] = (pendingWrite!['left'] as int) - 1;
          if ((pendingWrite!['left'] as int) <= 0) {
            final addr = pendingWrite!['addr'] as int;
            final wdata = pendingWrite!['data'] as BigInt;
            final sel = pendingWrite!['sel'] as int;
            var mask = BigInt.zero;
            for (var b = 0; b < 16; b++) {
              if ((sel >> b) & 1 == 1) mask |= BigInt.from(0xff) << (b * 8);
            }
            mem[addr] = ((mem[addr] ?? BigInt.zero) & ~mask) | (wdata & mask);
            pendingWrite = null;
          }
        }
      }
      // mature pending reads.
      for (final r in pendingReads) {
        r[1]--;
      }
      final ready = pendingReads.where((r) => r[1] <= 0).toList();
      if (ready.isNotEmpty) {
        final r = ready.first;
        pendingReads.remove(r);
        mData.inject(mem[r[0]] ?? BigInt.zero);
        mAck.inject(1);
      }
    });

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;

    Future<void> busWrite(int addr, int data, {int sel = 0xF}) async {
      sCyc.inject(1);
      sStb.inject(1);
      sWe.inject(1);
      sAddr.inject(addr);
      sData.inject(data);
      sSel.inject(sel);
      // wait for ack
      var guard = 0;
      do {
        await clk.nextPosedge;
        guard++;
      } while (dut.output('s_ack').value.toInt() != 1 && guard < 100);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      sCyc.inject(1);
      sStb.inject(1);
      sWe.inject(0);
      sAddr.inject(addr);
      var guard = 0;
      do {
        await clk.nextPosedge;
        guard++;
      } while (dut.output('s_ack').value.toInt() != 1 && guard < 100);
      final v = dut.output('s_data_out').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    // BYTE addresses: burst = addr>>4, word-in-burst = addr[3:2]. byte 0 and byte
    // 4 are words 0/1 of burst 0; byte 0x14 is word 1 of burst 1.
    await busWrite(0x0, 0xAABBCCDD);
    await busWrite(0x4, 0x11223344);
    await busWrite(0x14, 0xDEADBEEF);

    expect(await busRead(0x0), 0xAABBCCDD, reason: 'burst0 word0');
    expect(
      await busRead(0x4),
      0x11223344,
      reason: 'burst0 word1 (neighbour not clobbered)',
    );
    expect(await busRead(0x8), 0, reason: 'burst0 word2 never written');
    expect(await busRead(0x14), 0xDEADBEEF, reason: 'burst1 word1');

    // partial byte write into an existing word must not disturb other bytes.
    await busWrite(0x0, 0x000000FF, sel: 0x1); // low byte only
    expect(await busRead(0x0), 0xAABBCCFF, reason: 'byte-masked write');

    await Simulator.endSimulation();
  });
}

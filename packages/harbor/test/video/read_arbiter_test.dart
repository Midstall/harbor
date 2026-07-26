import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Two always-requesting read masters share one memory through the arbiter.
/// Fake memory acks combinationally and returns address-as-data, so a granted
/// master's data equals its address. With round-robin, grant alternates each
/// served word, and each master only sees ack/data on its own grant cycles.
class _Harness extends Module {
  Logic get dAdr => output('d_adr');
  Logic get ack0 => output('ack0');
  Logic get ack1 => output('ack1');
  Logic get dat0 => output('dat0');
  Logic get dat1 => output('dat1');

  _Harness(Logic clk, Logic reset, Logic adr0, Logic adr1)
    : super(definitionName: 'ArbHarness') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    adr0 = addInput('adr0', adr0, width: 32);
    adr1 = addInput('adr1', adr1, width: 32);
    addOutput('d_adr', width: 32);
    addOutput('ack0');
    addOutput('ack1');
    addOutput('dat0', width: 32);
    addOutput('dat1', width: 32);

    final one = Const(1);
    final dAck = Logic(name: 'd_ack');
    final dDataIn = Logic(name: 'd_dat_i', width: 32);

    final arb = HarborReadArbiter(
      clk: clk,
      reset: reset,
      stb: [one, one],
      cyc: [one, one],
      adr: [adr0, adr1],
      dAck: dAck,
      dDataIn: dDataIn,
    );

    // Fake memory: 0-latency ack, data = address.
    dAck <= arb.dStb;
    dDataIn <= arb.dAddr;

    output('d_adr') <= arb.dAddr;
    output('ack0') <= arb.ack(0);
    output('ack1') <= arb.ack(1);
    output('dat0') <= arb.dat(0);
    output('dat1') <= arb.dat(1);
  }
}

void main() {
  test('round-robins two read masters onto one memory', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final adr0 = Logic(name: 'adr0', width: 32);
    final adr1 = Logic(name: 'adr1', width: 32);

    final h = _Harness(clk, reset, adr0, adr1);
    await h.build();

    reset.inject(1);
    adr0.inject(0x10);
    adr1.inject(0x20);
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;

    // Collect which master is served over several cycles.
    final served = <int>[];
    for (var i = 0; i < 4; i++) {
      final adr = h.dAdr.value.toInt();
      if (adr == 0x10) {
        expect(h.ack0.value.toInt(), equals(1));
        expect(h.dat0.value.toInt(), equals(0x10));
        served.add(0);
      } else if (adr == 0x20) {
        expect(h.ack1.value.toInt(), equals(1));
        expect(h.dat1.value.toInt(), equals(0x20));
        served.add(1);
      }
      await clk.nextPosedge;
      await clk.nextNegedge;
    }

    // Both masters get served, alternating (round-robin fairness).
    expect(served.contains(0), isTrue);
    expect(served.contains(1), isTrue);
    expect(served[0], isNot(equals(served[1])));

    await Simulator.endSimulation();
    Simulator.reset();
  });
}

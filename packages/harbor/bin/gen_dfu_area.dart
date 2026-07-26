// Area-measurement harness for the USB DFU subsystem that would be added to
// creek. Wraps the synthesizable DFU datapath that lands in the SoC:
//   - UsbEp0Engine  (internally instantiates HarborUsbFsPhyRx/Tx, packet
//     rx/tx, descriptor ROM, the EP0 + DFU class FSM)
//   - UsbDfuRamSink (the bus-master RAM sink + CDC FIFO)
// into a single parent BridgeModule DfuAreaTop so synth sees the whole
// subsystem as one netlist.
//
// CRITICAL: every top-level input is DRIVEN (from top ports or a register that
// is genuinely used), and the bus master's ack/dat_miso are driven by an
// always-ack so the bus write FSM is retained. This prevents `opt` from pruning
// the logic and reporting a misleading ~0 cell count.
//
// This is a MEASUREMENT tool only. It does not change any RTL.
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Parent that stitches the engine + ram sink into one synthesizable top.
class DfuAreaTop extends BridgeModule {
  DfuAreaTop() : super('DfuAreaTop', name: 'dfu_area_top') {
    // ---- Top-level ports (everything an external SoC would wire). ----
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    // USB line inputs (drive the engine PHY rx so framing logic is retained).
    createPort('usb_dp_in', PortDirection.input);
    createPort('usb_dm_in', PortDirection.input);
    // Bus-domain clock/reset for the ram sink (a real SoC would use a slower
    // bus clock; here just give it its own port so nothing is tied to a const).
    createPort('bus_clk', PortDirection.input);
    createPort('bus_reset', PortDirection.input);

    // Surface a couple of engine + sink outputs at the top so the whole chain
    // (engine FSM -> sink stream -> bus FSM -> image_ready) is observable and
    // therefore not pruned.
    addOutput('usb_dp_out');
    addOutput('usb_dm_out');
    addOutput('usb_oe');
    addOutput('dev_addr', width: 7);
    addOutput('configured');
    addOutput('dfu_state', width: 4);
    addOutput('image_ready');
    addOutput('bytes_written', width: 32);
    addOutput('sink_overflow');

    final clk = input('clk');
    final reset = input('reset');
    final busClk = input('bus_clk');
    final busReset = input('bus_reset');

    // ---- The DFU engine. ----
    final engine = UsbEp0Engine(name: 'dfu_ep0');
    addSubModule(engine);
    engine.input('clk').srcConnection! <= clk;
    engine.input('reset').srcConnection! <= reset;
    engine.input('dp').srcConnection! <= input('usb_dp_in');
    engine.input('dm').srcConnection! <= input('usb_dm_in');

    // ---- The RAM sink (bus master). ----
    final ramSink = UsbDfuRamSink(loadBase: 0x1000, busDataWidth: 32);
    addSubModule(ramSink);
    // USB-domain clock/reset are the SAME 48 MHz domain as the engine.
    ramSink.input('usb_clk').srcConnection! <= clk;
    ramSink.input('usb_reset').srcConnection! <= reset;
    ramSink.input('bus_clk').srcConnection! <= busClk;
    ramSink.input('bus_reset').srcConnection! <= busReset;

    // ---- Wire engine sink outputs -> ram sink inputs. ----
    ramSink.input('sink_data').srcConnection! <= engine.output('sink_data');
    ramSink.input('sink_valid').srcConnection! <= engine.output('sink_valid');
    ramSink.input('dnload_done').srcConnection! <= engine.output('dnload_done');
    ramSink.input('image_target').srcConnection! <=
        engine.output('image_target');
    ramSink.input('alt_setting').srcConnection! <= engine.output('alt_setting');
    // Back-pressure: ram sink's sink_ready feeds the engine's sink_ready in.
    engine.input('sink_ready').srcConnection! <= ramSink.output('sink_ready');

    // ---- Bus master slave side: drive the ram sink's Wishbone consumer-side
    // inputs (bus_ACK, bus_DAT_MISO) directly. The ram sink's `bus` interface
    // is a provider (master), so ACK / DAT_MISO are INPUT ports on the
    // submodule. We drive them with an always-ack so the bus write FSM (stWrite
    // waits on bus.ack) always completes and the whole FSM + datapath is
    // retained (not pruned by opt). ----
    final busCyc = ramSink.output('bus_CYC');
    final busStb = ramSink.output('bus_STB');
    final busAdr = ramSink.output('bus_ADR');

    // Always-ack: ack follows (cyc & stb) one cycle later, so the master's
    // stWrite state always completes. dat_miso is fed from the master's adr so
    // the read path is also kept live.
    final ackReg = Logic(name: 'ack_reg');
    final misoReg = Logic(name: 'miso_reg', width: 32);
    Sequential(busClk, [
      If(
        busReset,
        then: [ackReg < Const(0), misoReg < Const(0, width: 32)],
        orElse: [
          ackReg < (busCyc & busStb & ~ackReg),
          misoReg < busAdr.zeroExtend(32),
        ],
      ),
    ]);
    ramSink.input('bus_ACK').srcConnection! <= ackReg;
    ramSink.input('bus_DAT_MISO').srcConnection! <= misoReg;

    // ---- Surface outputs. ----
    output('usb_dp_out') <= engine.output('dp_out');
    output('usb_dm_out') <= engine.output('dm_out');
    output('usb_oe') <= engine.output('oe');
    output('dev_addr') <= engine.output('dev_addr');
    output('configured') <= engine.output('configured');
    output('dfu_state') <= engine.output('dfu_state');
    output('image_ready') <= ramSink.output('image_ready');
    output('bytes_written') <= ramSink.output('bytes_written');
    output('sink_overflow') <= ramSink.output('overflow');
  }
}

Future<void> main() async {
  final top = DfuAreaTop();
  await top.build();
  final sv = top.generateSynth();
  const outPath = '/tmp/dfu_area.sv';
  File(outPath).writeAsStringSync(sv);
  stdout.writeln('WROTE ${sv.length} bytes to $outPath');
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'wishbone/wishbone_interface.dart';
import 'tilelink/tilelink_interface.dart';

/// Which bus protocol to use for a peripheral.
enum BusProtocol { wishbone, tilelink }

/// A bus-protocol-agnostic slave port for peripherals.
///
/// Provides a uniform internal interface (addr, dataIn, dataOut,
/// stb, we, sel, ack) that peripherals wire their register logic to.
/// The external bus protocol (Wishbone, TileLink, etc.) is handled
/// transparently.
///
/// ```dart
/// class MyDevice extends BridgeModule with HarborDeviceTreeNodeProvider {
///   MyDevice({required int baseAddress}) : super('MyDevice') {
///     createPort('clk', PortDirection.input);
///     createPort('reset', PortDirection.input);
///
///     final bus = BusSlavePort.create(
///       module: this,
///       name: 'bus',
///       protocol: BusProtocol.wishbone,
///       addressWidth: 8,
///       dataWidth: 32,
///     );
///
///     // Use bus.addr, bus.dataIn, bus.dataOut, bus.stb, bus.we, bus.sel,
///     // bus.ack regardless of which protocol was chosen
///   }
/// }
/// ```
class BusSlavePort {
  /// Address signal (from master).
  final Logic addr;

  /// Write data signal (from master).
  final Logic dataIn;

  /// Read data signal (to master).
  final Logic dataOut;

  /// Strobe/valid signal (from master - transaction active).
  final Logic stb;

  /// Write enable (from master - 1=write, 0=read).
  final Logic we;

  /// Byte-lane selects (from master, one bit per byte of [dataIn]). On
  /// Wishbone this is SEL, on TileLink the A-channel mask.
  final Logic sel;

  /// Acknowledge (to master - transaction complete).
  final Logic ack;

  /// Error signal (to master, optional).
  final Logic? err;

  /// The protocol being used.
  final BusProtocol protocol;

  /// The rohd_bridge interface reference (for connectInterfaces).
  final InterfaceReference<PairInterface> interfaceRef;

  BusSlavePort._({
    required this.addr,
    required this.dataIn,
    required this.dataOut,
    required this.stb,
    required this.we,
    required this.sel,
    required this.ack,
    this.err,
    required this.protocol,
    required this.interfaceRef,
  });

  /// Creates a bus slave port on [module] using the specified [protocol].
  ///
  /// Adds the appropriate bus interface to the module and returns
  /// a [BusSlavePort] with protocol-agnostic signals.
  static BusSlavePort create({
    required BridgeModule module,
    required String name,
    required BusProtocol protocol,
    required int addressWidth,
    required int dataWidth,
  }) {
    switch (protocol) {
      case BusProtocol.wishbone:
        return _createWishbone(module, name, addressWidth, dataWidth);
      case BusProtocol.tilelink:
        return _createTileLink(module, name, addressWidth, dataWidth);
    }
  }

  static BusSlavePort _createWishbone(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
  ) {
    final intf = WishboneInterface(
      WishboneConfig(addressWidth: addressWidth, dataWidth: dataWidth),
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final busIntf = ref.internalInterface!;

    final datOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ackOut = Logic(name: '${name}_ack_out');

    busIntf.datMiso <= datOut;
    busIntf.ack <= ackOut;

    return BusSlavePort._(
      addr: busIntf.adr,
      dataIn: busIntf.datMosi,
      dataOut: datOut,
      stb: busIntf.cyc & busIntf.stb,
      we: busIntf.we,
      sel: busIntf.sel,
      ack: ackOut,
      err: null,
      protocol: BusProtocol.wishbone,
      interfaceRef: ref,
    );
  }

  static BusSlavePort _createTileLink(
    BridgeModule module,
    String name,
    int addressWidth,
    int dataWidth,
  ) {
    final intf = TileLinkInterface(
      TileLinkConfig(addressWidth: addressWidth, dataWidth: dataWidth),
    );
    final ref = module.addInterface(intf, name: name, role: PairRole.consumer);
    final busIntf = ref.internalInterface!;

    final datOut = Logic(name: '${name}_dat_out', width: dataWidth);
    final ackOut = Logic(name: '${name}_ack_out');

    // TileLink -> internal signals
    final stb = busIntf.aValid;
    final we =
        busIntf.aOpcode.eq(Const(0, width: 3)) | // PutFullData
        busIntf.aOpcode.eq(Const(1, width: 3)); // PutPartialData
    final addr = busIntf.aAddress;
    final dataIn = busIntf.aData;

    // Internal signals -> TileLink Channel D
    busIntf.dValid <= ackOut;
    busIntf.dOpcode <= mux(we, Const(0, width: 3), Const(1, width: 3));
    busIntf.dParam <= Const(0, width: 2);
    busIntf.dSize <= busIntf.aSize;
    busIntf.dSource <= busIntf.aSource;
    busIntf.dSink <= Const(0, width: intf.config.sinkWidth);
    busIntf.dData <= datOut;
    busIntf.dCorrupt <= Const(0);
    busIntf.dDenied <= Const(0);
    busIntf.aReady <= ackOut | ~busIntf.aValid;

    return BusSlavePort._(
      addr: addr,
      dataIn: dataIn,
      dataOut: datOut,
      stb: stb,
      we: we,
      sel: busIntf.aMask,
      ack: ackOut,
      err: null,
      protocol: BusProtocol.tilelink,
      interfaceRef: ref,
    );
  }
}

import 'package:rohd/rohd.dart';

import '../../../harbor.dart';

/// Configuration for a Wishbone B4 bus interface.
///
/// Controls which optional signals are generated and their widths.
class WishboneConfig with HarborPrettyString {
  /// Address bus width in bits.
  final int addressWidth;

  /// Data bus width in bits. Must be 8, 16, 32, or 64.
  final int dataWidth;

  /// Select granularity width. Defaults to `dataWidth ~/ 8`.
  final int selWidth;

  /// Include ERR (error) signal.
  final bool useErr;

  /// Include RTY (retry) signal.
  final bool useRty;

  /// Include CTI (cycle type identifier) signal.
  final bool useCti;

  /// Include BTE (burst type extension) signal.
  final bool useBte;

  /// Tag address width. 0 disables.
  final int tgaWidth;

  /// Tag data width. 0 disables.
  final int tgdWidth;

  const WishboneConfig({
    required this.addressWidth,
    required this.dataWidth,
    this.selWidth = 0,
    this.useErr = false,
    this.useRty = false,
    this.useCti = false,
    this.useBte = false,
    this.tgaWidth = 0,
    this.tgdWidth = 0,
  });

  /// Default select width: one bit per byte lane.
  int get effectiveSelWidth => selWidth > 0 ? selWidth : dataWidth ~/ 8;

  /// Validates parameters. Returns error messages (empty = valid).
  List<String> validate() {
    final errors = <String>[];
    if (addressWidth < 1) {
      errors.add('addressWidth must be >= 1');
    }
    if (![8, 16, 32, 64].contains(dataWidth)) {
      errors.add('dataWidth must be one of [8, 16, 32, 64]');
    }
    if (useBte && !useCti) {
      errors.add('BTE requires CTI to be enabled');
    }
    return errors;
  }

  @override
  String toString() => 'WishboneConfig(addr: $addressWidth, data: $dataWidth)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}WishboneConfig(\n');
    buf.writeln('${c}addressWidth: $addressWidth,');
    buf.writeln('${c}dataWidth: $dataWidth,');
    buf.writeln('${c}selWidth: $effectiveSelWidth,');
    if (useErr) buf.writeln('${c}useErr: true,');
    if (useRty) buf.writeln('${c}useRty: true,');
    if (useCti) buf.writeln('${c}useCti: true,');
    if (useBte) buf.writeln('${c}useBte: true,');
    if (tgaWidth > 0) buf.writeln('${c}tgaWidth: $tgaWidth,');
    if (tgdWidth > 0) buf.writeln('${c}tgdWidth: $tgdWidth,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// A Wishbone B4 pipelined bus interface using [PairInterface].
///
/// Provider role = master (drives CYC, STB, WE, ADR, DAT_MOSI, SEL).
/// Consumer role = slave (drives ACK, DAT_MISO, ERR, RTY).
///
/// Works with [BridgeModule.addInterface] and [connectInterfaces].
///
/// ```dart
/// // In a master BridgeModule:
/// final bus = addInterface(
///   WishboneInterface(config),
///   name: 'dataBus',
///   role: PairRole.provider,  // master
/// )
///
/// // In a slave BridgeModule:
/// final bus = addInterface(
///   WishboneInterface(config),
///   name: 'bus',
///   role: PairRole.consumer,  // slave
/// )
/// ```
class WishboneInterface extends PairInterface {
  /// The configuration for this interface.
  final WishboneConfig config;

  /// Cycle signal. Asserted for the duration of a bus cycle.
  Logic get cyc => port('CYC');

  /// Strobe signal. Indicates a valid transfer cycle.
  Logic get stb => port('STB');

  /// Write enable. High = write, low = read.
  Logic get we => port('WE');

  /// Address bus.
  Logic get adr => port('ADR');

  /// Write data (master → slave).
  Logic get datMosi => port('DAT_MOSI');

  /// Byte select.
  Logic get sel => port('SEL');

  /// Acknowledge. Slave indicates transfer completion.
  Logic get ack => port('ACK');

  /// Read data (slave → master).
  Logic get datMiso => port('DAT_MISO');

  /// Error signal (slave → master). Only present if [WishboneConfig.useErr].
  Logic? get err => tryPort('ERR');

  /// Retry signal (slave → master). Only present if [WishboneConfig.useRty].
  Logic? get rty => tryPort('RTY');

  /// Cycle type identifier (master → slave). Only present if
  /// [WishboneConfig.useCti].
  Logic? get cti => tryPort('CTI');

  /// Burst type extension (master → slave). Only present if
  /// [WishboneConfig.useBte].
  Logic? get bte => tryPort('BTE');

  /// Tag address (master → slave). Only present if
  /// [WishboneConfig.tgaWidth] > 0.
  Logic? get tga => tryPort('TGA');

  /// Tag data master → slave. Only present if
  /// [WishboneConfig.tgdWidth] > 0.
  Logic? get tgdMosi => tryPort('TGD_MOSI');

  /// Tag data slave → master. Only present if
  /// [WishboneConfig.tgdWidth] > 0.
  Logic? get tgdMiso => tryPort('TGD_MISO');

  /// Creates a Wishbone interface with the given [config].
  ///
  /// Throws [ArgumentError] if config validation fails.
  WishboneInterface(this.config)
    : super(
        portsFromProvider: [
          // Master → Slave
          Logic.port('CYC'),
          Logic.port('STB'),
          Logic.port('WE'),
          Logic.port('ADR', config.addressWidth),
          Logic.port('DAT_MOSI', config.dataWidth),
          Logic.port('SEL', config.effectiveSelWidth),
          if (config.useCti) Logic.port('CTI', 3),
          if (config.useBte) Logic.port('BTE', 2),
          if (config.tgaWidth > 0) Logic.port('TGA', config.tgaWidth),
          if (config.tgdWidth > 0) Logic.port('TGD_MOSI', config.tgdWidth),
        ],
        portsFromConsumer: [
          // Slave → Master
          Logic.port('ACK'),
          Logic.port('DAT_MISO', config.dataWidth),
          if (config.useErr) Logic.port('ERR'),
          if (config.useRty) Logic.port('RTY'),
          if (config.tgdWidth > 0) Logic.port('TGD_MISO', config.tgdWidth),
        ],
      ) {
    final errors = config.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError('Invalid WishboneConfig: ${errors.join("; ")}');
    }
  }

  @override
  WishboneInterface clone() => WishboneInterface(config);
}

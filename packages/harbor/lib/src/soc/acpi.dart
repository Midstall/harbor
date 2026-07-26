import '../bus/bus.dart';
import 'cpu.dart';

class HarborAcpiDevice {
  /// ACPI Hardware ID
  final String hid;

  /// Optional compatible IDs
  final List<String> cid;

  /// Unique device ID
  final int uid;

  /// MMIO regions
  final List<BusAddressRange> memory;

  /// Interrupts
  final List<int> interrupts;

  /// Device properties emitted as an ACPI `_DSD` device-properties package.
  ///
  /// This is the standard mechanism for attaching arbitrary key/value data to
  /// a device. Pairing a `compatible` property here with [hid] `"PRP0001"`
  /// lets an OS reuse its device tree driver for a device that has no native
  /// ACPI hardware ID.
  ///
  /// Values may be [String], [int], [bool], [List<int>] or [List<String>].
  final Map<String, Object> properties;

  /// Additional raw ACPI names emitted as `Name (KEY, value)` entries.
  final Map<String, Object> names;

  const HarborAcpiDevice({
    required this.hid,
    this.cid = const [],
    this.uid = 0,
    this.memory = const [],
    this.interrupts = const [],
    this.properties = const {},
    this.names = const {},
  });
}

mixin HarborAcpiDeviceProvider {
  HarborAcpiDevice get acpiDevice;
}

class HarborAcpiGenerator {
  /// OEM ID (6 chars max)
  final String oemId;

  /// OEM Table ID (8 chars max)
  final String oemTableId;

  /// CPU entries.
  final List<HarborCpu> cpus;

  /// Peripheral nodes implementing [HarborAcpiDeviceProvider].
  final List<HarborAcpiDeviceProvider> peripherals;

  /// Interrupt numbers assigned to peripherals by the SoC's allocator, keyed
  /// by provider.
  ///
  /// When a provider has an entry here it overrides the device's own
  /// [HarborAcpiDevice.interrupts], so interrupt numbering lives in one place
  /// rather than being hardcoded per peripheral.
  final Map<HarborAcpiDeviceProvider, List<int>> interrupts;

  const HarborAcpiGenerator({
    required this.oemId,
    required this.oemTableId,
    this.cpus = const [],
    this.peripherals = const [],
    this.interrupts = const {},
  });

  /// ACPI device nodes from the peripherals.
  List<HarborAcpiDevice> get devices =>
      peripherals.map((p) => p.acpiDevice).toList();

  /// Generates the DSDT ASL source as a string.
  ///
  /// The output is intended to be fed to an ASL compiler such as `iasl`.
  String generate() {
    final buf = StringBuffer();

    buf.writeln(
      'DefinitionBlock ("", "DSDT", 2, "$oemId", "$oemTableId", 0x00000001)',
    );
    buf.writeln('{');
    buf.writeln('    Scope (\\_SB)');
    buf.writeln('    {');

    for (var i = 0; i < cpus.length; i++) {
      if (i > 0) buf.writeln();
      _writeCpu(buf, cpus[i]);
    }

    if (cpus.isNotEmpty && peripherals.isNotEmpty) buf.writeln();

    for (var i = 0; i < peripherals.length; i++) {
      if (i > 0) buf.writeln();
      final provider = peripherals[i];
      final dev = provider.acpiDevice;
      _writeDevice(buf, dev, i, interrupts[provider] ?? dev.interrupts);
    }

    buf.writeln('    }');
    buf.writeln('}');
    return buf.toString();
  }

  void _writeCpu(StringBuffer buf, HarborCpu cpu) {
    final name = _nameSeg('C', cpu.hartId);
    buf.writeln('        Device ($name)');
    buf.writeln('        {');
    buf.writeln('            Name (_HID, "ACPI0007")');
    buf.writeln('            Name (_UID, ${_hex(cpu.hartId)})');
    buf.writeln('            Name (_STA, 0x0F)');

    final props = <MapEntry<String, Object>>[
      MapEntry('riscv,isa', cpu.isa),
      if (cpu.mmu != null) MapEntry('mmu-type', cpu.mmu!),
      if (cpu.clockFrequency != null)
        MapEntry('clock-frequency', cpu.clockFrequency!),
    ];
    _writeDsd(buf, props, indent: '            ');

    buf.writeln('        }');
  }

  void _writeDevice(
    StringBuffer buf,
    HarborAcpiDevice dev,
    int index,
    List<int> irqs,
  ) {
    final name = _nameSeg('D', index);
    buf.writeln('        Device ($name)');
    buf.writeln('        {');
    buf.writeln('            Name (_HID, "${dev.hid}")');

    if (dev.cid.length == 1) {
      buf.writeln('            Name (_CID, "${dev.cid.first}")');
    } else if (dev.cid.length > 1) {
      final list = dev.cid.map((c) => '"$c"').join(', ');
      buf.writeln('            Name (_CID, Package () { $list })');
    }

    buf.writeln('            Name (_UID, ${_hex(dev.uid)})');
    buf.writeln('            Name (_STA, 0x0F)');

    if (dev.memory.isNotEmpty || irqs.isNotEmpty) {
      buf.writeln('            Name (_CRS, ResourceTemplate ()');
      buf.writeln('            {');
      for (final region in dev.memory) {
        _writeMemory(buf, region);
      }
      if (irqs.isNotEmpty) {
        final irqList = irqs.map(_hex).join(', ');
        buf.writeln(
          '                Interrupt (ResourceConsumer, Level, ActiveHigh, '
          'Exclusive)',
        );
        buf.writeln('                {');
        buf.writeln('                    $irqList');
        buf.writeln('                }');
      }
      buf.writeln('            })');
    }

    _writeDsd(buf, dev.properties.entries.toList(), indent: '            ');

    for (final entry in dev.names.entries) {
      buf.writeln(
        '            Name (${_nameSegFromKey(entry.key)}, '
        '${_formatValue(entry.value)})',
      );
    }

    buf.writeln('        }');
  }

  void _writeMemory(StringBuffer buf, BusAddressRange region) {
    // Use the compact 32-bit descriptor when the whole range fits, otherwise
    // fall back to the 64-bit QWord descriptor.
    if (region.end <= 0x100000000) {
      buf.writeln(
        '                Memory32Fixed (ReadWrite, '
        '${_hex32(region.start)}, ${_hex32(region.size)})',
      );
      return;
    }

    buf.writeln(
      '                QWordMemory (ResourceConsumer, PosDecode, MinFixed, '
      'MaxFixed, NonCacheable, ReadWrite,',
    );
    buf.writeln('                    0x0000000000000000, // Granularity');
    buf.writeln(
      '                    ${_hex64(region.start)}, // Range Minimum',
    );
    buf.writeln(
      '                    ${_hex64(region.end - 1)}, // Range Maximum',
    );
    buf.writeln(
      '                    0x0000000000000000, // Translation Offset',
    );
    buf.writeln('                    ${_hex64(region.size)}, // Length');
    buf.writeln('                    )');
  }

  void _writeDsd(
    StringBuffer buf,
    List<MapEntry<String, Object>> props, {
    required String indent,
  }) {
    if (props.isEmpty) return;
    // Standard ACPI device-properties UUID for _DSD.
    buf.writeln('${indent}Name (_DSD, Package ()');
    buf.writeln('$indent{');
    buf.writeln('$indent    ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),');
    buf.writeln('$indent    Package ()');
    buf.writeln('$indent    {');
    for (final p in props) {
      buf.writeln(
        '$indent        Package () { "${p.key}", ${_formatValue(p.value)} },',
      );
    }
    buf.writeln('$indent    }');
    buf.writeln('$indent})');
  }

  /// Builds a 4-character ACPI NameSeg from a [prefix] and numeric [index].
  String _nameSeg(String prefix, int index) {
    final hex = index.toRadixString(16).toUpperCase();
    final room = 4 - prefix.length;
    final tail = hex.length >= room
        ? hex.substring(hex.length - room)
        : hex.padLeft(room, '0');
    return '$prefix$tail';
  }

  /// Sanitizes an arbitrary [key] into a valid 4-character ACPI NameSeg.
  String _nameSegFromKey(String key) {
    var s = key.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
    if (s.isEmpty) s = '_';
    if (RegExp(r'[0-9]').hasMatch(s[0])) s = '_$s';
    if (s.length > 4) s = s.substring(0, 4);
    return s.padRight(4, '_');
  }

  String _hex(int v) => '0x${v.toRadixString(16).toUpperCase()}';

  String _hex32(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(8, '0')}';

  String _hex64(int v) =>
      '0x${v.toRadixString(16).toUpperCase().padLeft(16, '0')}';

  String _formatValue(Object value) {
    if (value is String) return '"$value"';
    if (value is bool) return value ? 'One' : 'Zero';
    if (value is int) return _hex(value);
    if (value is List<int>) {
      return 'Package () { ${value.map(_hex).join(', ')} }';
    }
    if (value is List<String>) {
      return 'Package () { ${value.map((s) => '"$s"').join(', ')} }';
    }
    if (value is List) {
      return 'Package () { '
          '${value.map((e) => _formatValue(e as Object)).join(', ')} }';
    }
    return '"$value"';
  }
}

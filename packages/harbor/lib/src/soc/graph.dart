import 'cpu.dart';
import 'device_tree.dart';

/// Generates Mermaid and Graphviz DOT diagrams of a SoC's bus fabric
/// and peripheral topology.
///
/// ```dart
/// final graph = HarborSoCGraphGenerator(
///   name: 'Creek V1',
///   cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
///   peripherals: [clint, plic, uart, sram],
/// );
///
/// print(graph.mermaid());   // Mermaid flowchart
/// print(graph.dot());       // Graphviz DOT
/// ```
class HarborSoCGraphGenerator {
  /// SoC name for the graph title.
  final String name;

  /// CPU entries.
  final List<HarborCpu> cpus;

  /// Peripheral nodes.
  final List<HarborDeviceTreeNodeProvider> peripherals;

  /// Interrupt numbers assigned to peripherals by the SoC's allocator, keyed
  /// by provider. Overrides a node's own interrupts when present.
  final Map<HarborDeviceTreeNodeProvider, List<int>> interrupts;

  const HarborSoCGraphGenerator({
    required this.name,
    this.cpus = const [],
    this.peripherals = const [],
    this.interrupts = const {},
  });

  /// All device tree nodes from the peripherals.
  List<HarborDeviceTreeNode> get _nodes =>
      peripherals.map((p) => p.dtNode).toList();

  /// Each peripheral's node paired with its effective interrupt numbers.
  List<({HarborDeviceTreeNode node, List<int> irqs})> get _entries => [
    for (final p in peripherals)
      (node: p.dtNode, irqs: interrupts[p] ?? p.dtNode.interrupts),
  ];

  /// Generates a Mermaid flowchart diagram.
  String mermaid() {
    final buf = StringBuffer();
    final nodes = _nodes;

    buf.writeln('---');
    buf.writeln('title: $name');
    buf.writeln('---');
    buf.writeln('flowchart TD');

    for (final cpu in cpus) {
      buf.writeln(
        '    cpu${cpu.hartId}'
        '["CPU ${cpu.hartId}\\n${cpu.isa}"]',
      );
    }

    buf.writeln('    bus(("Bus Fabric"))');

    for (final cpu in cpus) {
      buf.writeln('    cpu${cpu.hartId} --> bus');
    }

    for (final n in nodes) {
      final id = _sanitizeId(n.nodeName);
      final addrHex = '0x${n.reg.start.toRadixString(16)}';
      final sizeHex = '0x${n.reg.size.toRadixString(16)}';

      if (n.interruptController) {
        buf.writeln('    $id{{"${n.primaryCompatible}\\n$addrHex"}}');
      } else {
        buf.writeln('    $id["${n.primaryCompatible}\\n$addrHex"]');
      }

      buf.writeln('    bus -- "$addrHex ($sizeHex)" --> $id');
    }

    for (final e in _entries) {
      if (e.irqs.isNotEmpty) {
        final controller = nodes
            .where((c) => c.interruptController)
            .firstOrNull;
        if (controller != null) {
          final srcId = _sanitizeId(e.node.nodeName);
          final ctrlId = _sanitizeId(controller.nodeName);
          final irqs = e.irqs.join(',');
          buf.writeln('    $srcId -. "IRQ $irqs" .-> $ctrlId');
        }
      }
    }

    return buf.toString();
  }

  /// Generates a Graphviz DOT graph.
  String dot() {
    final buf = StringBuffer();
    final nodes = _nodes;

    buf.writeln('digraph "$name" {');
    buf.writeln('    rankdir=TD;');
    buf.writeln('    node [fontname="monospace"];');
    buf.writeln('    edge [fontname="monospace", fontsize=10];');
    buf.writeln();

    buf.writeln('    subgraph cluster_cpus {');
    buf.writeln('        label="CPUs";');
    buf.writeln('        style=dashed;');
    for (final cpu in cpus) {
      buf.writeln(
        '        cpu${cpu.hartId} '
        '[label="CPU ${cpu.hartId}\\n${cpu.isa}"'
        ', shape=box, style=filled, fillcolor=lightblue];',
      );
    }
    buf.writeln('    }');
    buf.writeln();

    buf.writeln(
      '    bus [label="Bus Fabric"'
      ', shape=diamond, style=filled, fillcolor=lightyellow];',
    );
    buf.writeln();

    for (final cpu in cpus) {
      buf.writeln('    cpu${cpu.hartId} -> bus;');
    }
    buf.writeln();

    buf.writeln('    subgraph cluster_peripherals {');
    buf.writeln('        label="Peripherals";');
    buf.writeln('        style=dashed;');
    for (final n in nodes) {
      final id = _sanitizeId(n.nodeName);
      final addrHex = '0x${n.reg.start.toRadixString(16)}';
      final shape = n.interruptController ? 'hexagon' : 'box';
      final color = n.interruptController ? 'lightsalmon' : 'lightgreen';
      buf.writeln(
        '        $id '
        '[label="${n.primaryCompatible}\\n$addrHex"'
        ', shape=$shape, style=filled, fillcolor=$color];',
      );
    }
    buf.writeln('    }');
    buf.writeln();

    for (final n in nodes) {
      final id = _sanitizeId(n.nodeName);
      final addrHex = '0x${n.reg.start.toRadixString(16)}';
      final sizeHex = '0x${n.reg.size.toRadixString(16)}';
      buf.writeln('    bus -> $id [label="$addrHex\\n($sizeHex)"];');
    }
    buf.writeln();

    for (final e in _entries) {
      if (e.irqs.isNotEmpty) {
        final controller = nodes
            .where((c) => c.interruptController)
            .firstOrNull;
        if (controller != null) {
          final srcId = _sanitizeId(e.node.nodeName);
          final ctrlId = _sanitizeId(controller.nodeName);
          final irqs = e.irqs.join(',');
          buf.writeln(
            '    $srcId -> $ctrlId '
            '[label="IRQ $irqs", style=dashed, color=red];',
          );
        }
      }
    }

    buf.writeln('}');
    return buf.toString();
  }

  String _sanitizeId(String name) =>
      name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
}

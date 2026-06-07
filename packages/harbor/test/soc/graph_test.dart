import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  late List<HarborCpu> cpus;
  late HarborClint clint;
  late HarborPlic plic;
  late HarborUart uart;

  setUp(() {
    cpus = [
      HarborCpu(hartId: 0, isa: 'rv64imac'),
      HarborCpu(hartId: 1, isa: 'rv64imac'),
    ];
    clint = HarborClint(baseAddress: 0x02000000, hartCount: 2);
    plic = HarborPlic(baseAddress: 0x0C000000, sources: 32, contexts: 2);
    uart = HarborUart(baseAddress: 0x10000000);
  });

  group('HarborSoCGraphGenerator', () {
    group('mermaid', () {
      test('generates valid mermaid flowchart', () {
        final graph = HarborSoCGraphGenerator(
          name: 'Test SoC',
          cpus: cpus,
          peripherals: [clint, plic, uart],
        );
        final output = graph.mermaid();

        expect(output, contains('flowchart TD'));
        expect(output, contains('title: Test SoC'));

        // CPUs
        expect(output, contains('cpu0'));
        expect(output, contains('cpu1'));
        expect(output, contains('rv64imac'));

        // Bus
        expect(output, contains('bus'));

        // Peripherals
        expect(output, contains('riscv,clint0'));
        expect(output, contains('sifive,plic-1.0.0'));
        expect(output, contains('ns16550a'));

        // Addresses
        expect(output, contains('0x2000000'));
        expect(output, contains('0xc000000'));
        expect(output, contains('0x10000000'));
      });

      test('interrupt controllers get special shape', () {
        final graph = HarborSoCGraphGenerator(
          name: 'IC Test',
          peripherals: [plic],
        );
        final output = graph.mermaid();
        // Interrupt controllers use double braces {{}}
        expect(output, contains('{{'));
      });
    });

    group('dot', () {
      test('generates valid DOT graph', () {
        final graph = HarborSoCGraphGenerator(
          name: 'Test SoC',
          cpus: cpus,
          peripherals: [clint, plic, uart],
        );
        final output = graph.dot();

        expect(output, contains('digraph "Test SoC"'));
        expect(output, contains('rankdir=TD'));

        // CPUs
        expect(output, contains('cpu0'));
        expect(output, contains('cpu1'));

        // Bus
        expect(output, contains('bus'));
        expect(output, contains('diamond'));

        // Peripherals
        expect(output, contains('riscv,clint0'));
        expect(output, contains('sifive,plic-1.0.0'));
        expect(output, contains('ns16550a'));

        // Interrupt controller gets hexagon shape
        expect(output, contains('hexagon'));

        // Proper closing
        expect(output, contains('}'));
      });

      test('addresses in edge labels', () {
        final graph = HarborSoCGraphGenerator(
          name: 'Addr Test',
          peripherals: [uart],
        );
        final output = graph.dot();
        expect(output, contains('0x10000000'));
        expect(output, contains('0x1000'));
      });
    });

    group('empty', () {
      test('handles no CPUs or peripherals', () {
        final graph = HarborSoCGraphGenerator(name: 'Empty');
        expect(graph.mermaid(), contains('flowchart TD'));
        expect(graph.dot(), contains('digraph'));
      });
    });
  });
}

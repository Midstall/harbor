import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test('Xilinx openXC7 target emits an FTDI + BSCAN-tunnel openocd config', () {
    const t = HarborFpgaTarget.spartan7(
      device: 'xc7s50',
      package: 'csga324',
      useOpenXc7: true,
    );
    final cfg = t.generateOpenocdConfig(innerIrWidth: 5, dmIdcode: 0x10000001);
    expect(cfg, contains('adapter driver ftdi'));
    expect(
      cfg,
      contains(r'jtag newtap $_CHIPNAME tap -irlen 6 -expected-id 0x0362f093'),
    );
    expect(cfg, contains('set _USER 0x23'));
    expect(cfg, contains('riscv use_bscan_tunnel 5 0'));
    expect(
      cfg,
      contains(
        r'target create $_TARGETNAME riscv -chain-position $_CHIPNAME.tap',
      ),
    );
    expect(cfg, contains('riscv set_mem_access sysbus'));
    // The `riscv` group only registers after target create, so the tunnel
    // command must come after it.
    expect(
      cfg.indexOf('target create'),
      lessThan(cfg.indexOf('use_bscan_tunnel')),
    );
  });

  test('ECP5 target emits dirtyjtag + irlen 8 + ER1', () {
    const t = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CSFBGA285');
    final cfg = t.generateOpenocdConfig(innerIrWidth: 5);
    expect(cfg, contains('adapter driver dirtyjtag'));
    expect(cfg, contains('-irlen 8'));
    expect(cfg, contains('set _USER 0x32'));
    expect(cfg, contains('-expected-id 0x41111043'));
  });
}

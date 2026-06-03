/// Harbor: ROHD extensions for physical implementation - ASIC tapeout
/// flows, FPGA build support, and reusable SoC components.
///
/// Harbor provides a composable, declarative framework for building
/// RISC-V SoCs using ROHD and rohd_bridge.
library;

// HarborFiber primitives
export 'src/fiber/database.dart';
export 'src/fiber/fiber.dart';
export 'src/fiber/handle.dart';
export 'src/fiber/lock.dart';
export 'src/fiber/retainer.dart';

// Plugin system
export 'src/plugin/plugin.dart';

// HarborPipeline
export 'src/pipeline/builder.dart';
export 'src/pipeline/link.dart';
export 'src/pipeline/node.dart';
export 'src/pipeline/payload.dart';
export 'src/pipeline/stage.dart';

// Bus
export 'src/bus/bus_exports.dart';
export 'src/bus/fabric.dart';

// Cache
export 'src/cache/cache_config.dart';
export 'src/cache/cache_hierarchy.dart';
export 'src/cache/l1_cache.dart';
export 'src/cache/l2_cache.dart';

// Memory
export 'src/memory/data_port.dart';
export 'src/memory/memory_map.dart';
export 'src/memory/memory_port.dart';
export 'src/memory/mmu_config.dart';
export 'src/memory/page_table_walker.dart';
export 'src/memory/pma_checker.dart';
export 'src/memory/tlb.dart';

// Clock
export 'src/clock/cdc.dart';
export 'src/clock/clock_domain.dart';
export 'src/clock/clock_gate.dart';

// SoC
export 'src/soc/boot_sequencer.dart';
export 'src/soc/device_tree.dart';
export 'src/soc/graph.dart';
export 'src/soc/harbor_soc.dart';
export 'src/soc/interrupt_routing.dart';
export 'src/soc/power_domain.dart';
export 'src/soc/target.dart';

// PDK
export 'src/pdk/analog_block.dart';
export 'src/pdk/gf180mcu.dart';
export 'src/pdk/io_ring.dart';
export 'src/pdk/klayout.dart';
export 'src/pdk/pdk_provider.dart';
export 'src/pdk/sky130.dart';
export 'src/pdk/standard_cell_library.dart';

// RISC-V ISA
export 'src/riscv/decoder.dart';
export 'src/riscv/extension.dart';
export 'src/riscv/isa.dart';
export 'src/riscv/micro_op.dart';
export 'src/riscv/mxlen.dart';
export 'src/riscv/operation.dart';
export 'src/riscv/paging.dart';
export 'src/riscv/resource.dart';
export 'src/riscv/extensions/rv32i.dart';
export 'src/riscv/extensions/rv64i.dart';
export 'src/riscv/extensions/rv_a.dart';
export 'src/riscv/extensions/rv_b.dart';
export 'src/riscv/extensions/rv_c.dart';
export 'src/riscv/extensions/rv_d.dart';
export 'src/riscv/extensions/rv_f.dart';
export 'src/riscv/extensions/rv_h.dart';
export 'src/riscv/extensions/rv_m.dart';
export 'src/riscv/extensions/rv_priv.dart';
export 'src/riscv/extensions/rv_misc.dart';
export 'src/riscv/extensions/rv_zfhmin.dart';
export 'src/riscv/extensions/rv_zicond.dart';
export 'src/riscv/profiles/rva23.dart';
export 'src/riscv/extensions/rv_v.dart';
export 'src/riscv/extensions/rv_zicsr.dart';
export 'src/riscv/extensions/rv_zifencei.dart';

// Blackbox (FPGA primitives)
export 'src/blackbox/ice40/ice40.dart';
export 'src/blackbox/ecp5/ecp5.dart';
export 'src/blackbox/xilinx/xilinx.dart';

// Encoding
export 'src/encoding/bit_struct.dart';
export 'src/encoding/riscv_compressed.dart';
export 'src/encoding/riscv_csr.dart';
export 'src/encoding/riscv_formats.dart';
export 'src/encoding/riscv_hypervisor.dart';
export 'src/encoding/riscv_vector.dart';
export 'src/encoding/rvc_immediate.dart';

// Media
export 'src/media/audio.dart';
export 'src/media/codec.dart';
export 'src/media/media_engine.dart';

// Debug / JTAG
export 'src/debug/debug_module.dart';
export 'src/debug/debug_transport.dart';
export 'src/debug/jtag_interface.dart';
export 'src/debug/jtag_remote.dart';
export 'src/debug/jtag_tap.dart';
export 'src/debug/trace.dart';

// Utilities
export 'src/util/elf_loader.dart';
export 'src/util/pretty_string.dart';

// OpenSBI
export 'src/opensbi/platform.dart';

// Peripherals
export 'src/peripherals/aplic.dart';
export 'src/peripherals/clint.dart';
export 'src/peripherals/crypto.dart';
export 'src/peripherals/ddr.dart';
export 'src/peripherals/device_register.dart';
export 'src/peripherals/display.dart';
export 'src/peripherals/dma.dart';
export 'src/peripherals/efuse.dart';
export 'src/peripherals/ethernet.dart';
export 'src/peripherals/flash.dart';
export 'src/peripherals/gpio.dart';
export 'src/peripherals/hpm.dart';
export 'src/peripherals/i2c.dart';
export 'src/peripherals/imsic.dart';
export 'src/peripherals/iommu.dart';
export 'src/peripherals/maskrom.dart';
export 'src/peripherals/pcie.dart';
export 'src/peripherals/plic.dart';
export 'src/peripherals/pmu.dart';
export 'src/peripherals/pwm_timer.dart';
export 'src/peripherals/register_file.dart';
export 'src/peripherals/reset_controller.dart';
export 'src/peripherals/sdio.dart';
export 'src/peripherals/spi.dart';
export 'src/peripherals/spi_flash.dart';
export 'src/peripherals/sram.dart';
export 'src/peripherals/temperature_sensor.dart';
export 'src/peripherals/uart.dart';
export 'src/peripherals/usb.dart';
export 'src/peripherals/watchdog.dart';

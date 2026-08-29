# Harbor Nix build infrastructure.
#
# Provides three composable builder functions for hardware projects:
#
#   harbor.mkIp      - Generate RTL + scripts from a Dart/Harbor SoC definition
#   harbor.mkSynth   - FPGA synthesis + PnR + bitstream (Yosys + nextpnr)
#   harbor.mkTapeout  - ASIC tapeout flow (Yosys + OpenROAD + KLayout)
#
# Example usage in a downstream flake:
#
#   {
#     inputs.harbor.url = "github:LilithSemi/harbor";
#     outputs = { self, nixpkgs, harbor, ... }:
#       let
#         pkgs = import nixpkgs {
#           system = "x86_64-linux";
#           overlays = [ harbor.overlays.default ];
#         };
#       in {
#         packages.x86_64-linux = {
#           # Generate RTL from your SoC definition
#           my-soc-ip = pkgs.harbor.mkIp {
#             name = "my-soc";
#             dartSrc = ./soc;
#             pubspecLock = lib.importJSON ./soc/pubspec.lock.json;
#           };
#
#           # FPGA synthesis for ECP5
#           my-soc-synth = pkgs.harbor.mkSynth {
#             ip = self.packages.x86_64-linux.my-soc-ip;
#             topCell = "MySoC";
#             vendor = "ecp5";
#             device = "lfe5u-45f";
#             package_ = "CABGA381";
#             frequency = 50000000;
#           };
#
#           # ASIC tapeout with Sky130
#           my-soc-tapeout = pkgs.harbor.mkTapeout {
#             ip = self.packages.x86_64-linux.my-soc-ip;
#             topCell = "MySoC";
#             pdk = pkgs.sky130-pdk;
#             cellLib = "sky130_fd_sc_hd";
#             clockPeriodNs = 20;
#             macros = [ "RiverCore" "L2Cache" ];
#           };
#         };
#       };
#   }
{ lib, callPackage }:
{
  mkIp = callPackage ./mkIp.nix { };
  mkSynth = callPackage ./mkSynth.nix { };
  mkTapeout = callPackage ./mkTapeout.nix { };
}

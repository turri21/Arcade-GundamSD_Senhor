# Authors and Credits

## GundamSD_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the SD Gundam-specific logic (under
`rtl/GundamSD/` and the project wrapper `GundamSD.sv`) are copyright
Umberto Parisi and distributed under GNU GPL v3 or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **FX68K** — cycle-accurate M68000 core | Frederic Requin | [ijor/fx68k](https://github.com/ijor/fx68k) | LGPL-2.1 |
| **T80** — Z80 core | Daniel Wallner, MikeJ | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) | BSD / GPL |
| **JTFRAME / JTCORES** — framework, filters, tilemap, etc. | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **JT51** — YM2151 FM synthesizer | Jose Tejada | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT6295** — OKI M6295 ADPCM sample player | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **sdram.sv** — SDRAM controller | Sorgelig ([sorgelig](https://github.com/sorgelig)) | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **SD Gundam Psycho Salamander no Kyoui arcade hardware** — Banpresto /
  Bandai, 1991, running on Seibu PB91008 (Seibu D-Con family). This FPGA
  core is a reimplementation from hardware documentation, MAME source
  code (`seibu/dcon.cpp`, `seibu/seibu_crtc.cpp`), the main 68000 ROM
  disassembly and observation of real hardware behavior. ROMs are
  **not** included and must be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing,
  and driver behavior. [mamedev/mame](https://github.com/mamedev/mame)
- **Reverse engineering** — full annotated 68K disassembly and
  documentation in `docs/reverse_engineering/`.

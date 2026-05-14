# Arcade-GundamSD_MiSTer

FPGA core for **SD Gundam Psycho Salamander no Kyoui** (Banpresto / Bandai,
1991) targeting the [MiSTer FPGA](https://github.com/MiSTer-devel) platform
(Terasic DE10-Nano).

SD Gundam Psycho Salamander no Kyoui (SD ガンダム サイコサラマンダーの脅威)
is a side-scrolling shoot-em-up running on **Seibu PB91008** hardware — the
same Seibu D-Con family used by *Blood Bros.* and *D-Con*. The core
reimplements the hardware in SystemVerilog from MAME (`seibu/dcon.cpp`,
`seibu/seibu_crtc.cpp`), the Seibu CRTC documentation, the main 68000 ROM
disassembly and observation of real PCB behavior.

## Status

**Current version: 1.0** (May 2026) — first public release.

The core runs the full game with audio and inputs.

**Features**
- M68000 main CPU @ 10 MHz (FX68K cycle-accurate)
- Z80 sound CPU @ 3.579545 MHz (T80s)
- YM2151 FM (jt51) + OKI M6295 ADPCM (jt6295) with MAME-accurate mixer
- 320×224 active video area (Seibu D-Con timings)
- BG / MG / FG tilemaps (16×16, 4bpp, 32×32 tilemap)
- Text layer (8×8, 4bpp, 64×32 tilemap)
- 16×16 sprites with priority callback (Seibu SEI0211)
- Seibu CRTC registers (scroll, layer enable, flip screen)
- MiSTer OSD with audio mixer (FM/OKI volume), per-layer debug toggles
- Pause overlay with logo + supporters scroll

**ROM sets supported**
- SD Gundam Psycho Salamander no Kyoui (sdgndmps)

## Screenshots

| | |
|---|---|
| ![Title](docs/title.png) | ![Insert coin](docs/attract_insert_coin.png) |
| Title screen | Attract — Insert Coin |
| ![Intro](docs/intro_story.png) | ![Cave](docs/gameplay_cave.png) |
| Intro story | Gameplay — cave stage |
| ![Forest](docs/gameplay_forest_mountain.png) | ![Jungle](docs/gameplay_jungle_day.png) |
| Forest / mountain | Jungle stage |

## Hardware emulated

| Component        | Spec                                                |
|------------------|-----------------------------------------------------|
| Master clock     | 20 MHz crystal (main) + 14.31818 MHz (sound)        |
| Main CPU         | M68000 @ 10 MHz                                     |
| Sound CPU        | Z80 @ 3.579545 MHz                                  |
| Sound chip 1     | Yamaha YM2151 (jt51)                                |
| Sound chip 2     | OKI M6295 (jt6295) ADPCM, pin7=LOW, 1.25 MHz        |
| Video resolution | 320×224 active                                      |
| Refresh rate     | ~59.4 Hz                                            |
| BG layer         | 16×16 4bpp, 32×32 tilemap, scroll X/Y               |
| MG layer         | 16×16 4bpp, 32×32 tilemap, scroll X/Y, gfx-bank     |
| FG layer         | 16×16 4bpp, 32×32 tilemap, scroll X/Y               |
| Text layer       | 8×8 4bpp, 64×32 tilemap                             |
| Sprites          | 16×16 4bpp, 4-level priority (Seibu SEI0211)        |
| Palette          | xBGR_555, 2048 entries                              |
| Custom video CRTC| Seibu CRTC (legionna.cpp / seibu_crtc.cpp)          |
| Sprite chip      | Seibu SEI0211                                       |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- Works on HDMI displays and on 15 kHz CRTs via the analog video output

## Notes

- 15 kHz CRT output via the MiSTer analog I/O board works (Seibu D-Con
  320×224 is a standard arcade resolution).
- HDMI output works directly on modern displays. For 31 kHz VGA monitors
  use an HDMI→VGA adapter, or enable **Direct Video** if your I/O board
  and monitor support it.

## Build from source

Requires **Quartus Prime Lite 17.0.x** for Cyclone V (5CSEBA6U23I7).

```bash
cd Arcade-GundamSD_MiSTer
quartus_sh --flow compile SDGundamPS
```

Output: `output_files/SDGundamPS.rbf` (~3.9 MB).

## Running on MiSTer

The [releases/](releases/) folder contains the parent MRA and a
prebuilt RBF:

- `SD Gundam Psycho Salamander no Kyoui.mra` — parent MRA
- `SDGundamPS_YYYYMMDD.rbf` — prebuilt bitstream

Steps:

1. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card (rename to
   `SDGundamPS.rbf` or keep the dated name and update the MRA accordingly).
2. Copy the `.mra` file to `_Arcade/` on the MiSTer SD card.
3. Provide your legally-owned `sdgndmps.zip` ROM where the MRA expects it
   (usually in `games/mame/`).

**ROMs are NOT included in this repository.** You must provide them yourself.

## Repository layout

```
Arcade-GundamSD_MiSTer/
├── rtl/
│   ├── GundamSD/     SD Gundam-specific core RTL
│   ├── pll/          Clock PLL
│   ├── sound/        Sound chip cores (jt51, jt6295, t80)
│   ├── fx68k/        FX68K M68000 cycle-accurate core
│   ├── jtframe/      JTFRAME framework modules
│   └── sdram.sv      SDRAM controller (Sorgelig)
├── sys/              MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/             Pause overlay assets (font, logo, supporter list)
├── docs/             Screenshots
├── releases/         Parent MRA + prebuilt RBF
├── SDGundamPS.qpf    Quartus project
├── SDGundamPS.qsf    Quartus assignments
├── GundamSD.sv       Top-level wrapper
├── Template.sdc      Timing constraints
├── files.qip         HDL file list
├── build_id.v        Build version stamp
├── LICENSE           GNU GPL v3
├── AUTHORS.md        Credits and third-party licenses
└── README.md         This file
```

## Acknowledgements

- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JT51 (YM2151),
  JT6295 (OKI M6295) and the JTFRAME framework.
- **Daniel Wallner** and **MikeJ** for the T80 (Z80) core.
- **Frederic Requin** and contributors for the **FX68K** cycle-accurate
  M68000 core.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.
- The **MAME** project for invaluable hardware reference
  (`seibu/dcon.cpp`, `seibu/seibu_crtc.cpp`).

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [GitHub](https://github.com/rmonic79)
- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici) — playlists and videos
- [X / Twitter](https://x.com/rmonic79)

## License

Distributed under **GNU General Public License v3 or later**.
See [LICENSE](LICENSE) and [AUTHORS.md](AUTHORS.md) for credits and
third-party licensing.

GPL-3 is chosen to stay compatible with upstream GPL-3 dependencies
(JTFRAME, FX68K, Sorgelig's sdram and sys framework).

Original *SD Gundam Psycho Salamander no Kyoui* arcade hardware © Banpresto
/ Bandai / Sunrise / SOTSU AGENCY, 1991. Original ROM data is not included;
users must provide their own legally obtained copies.

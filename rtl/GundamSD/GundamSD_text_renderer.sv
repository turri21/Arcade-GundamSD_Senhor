// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of GundamSD_MiSTer.

    GundamSD_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    GundamSD_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with GundamSD_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

/*  Text layer renderer Seibu D-Con (8x8, 4bpp, 64x32).

    Specifiche da MAME (src/mame/seibu/dcon.cpp):

      // get_text_tile_info
      tile  = textram[tile_index];
      color = (tile >> 12) & 0xf;
      tile  = tile & 0xfff;
      tileinfo.set(0, tile, color, 0);

      // create
      m_text_layer = create(... TILEMAP_SCAN_ROWS, 8, 8, 64, 32);
      m_text_layer->set_transparent_pen(15);

      // GFXDECODE
      GFXDECODE_ENTRY("txtiles", 0, dcon_charlayout, 1024+768, 16);
      // → color base = 0x700, 16 colorset

      // sdgndmps_map dispatcher
      m_text_layer->set_scrollx(0, 128);
      m_text_layer->set_scrolly(0, 0);

      // dcon_charlayout
      8x8, RGN_FRAC(1,2), 4 bpp,
      planes  = { 0, 4, 0x80000, 0x80004 },     // bit-offset
      x_bits  = { 3,2,1,0, 11,10,9,8 },         // pixel→bit-offset
      y_bits  = { 0,16,32,...,7*16 },
      tile_size = 128 bit (= 16 byte per metà)

    Char ROM mapping in SDRAM (vedi MRA):
      0x080000..0x08FFFF (64KB): planes 0,1 (= ROM 911-a08.66)
      0x090000..0x09FFFF (64KB): planes 2,3 (= ROM 911-a07.73)

    Cache strategy: 128KB BRAM totali (32 M10K), tutti i 4096 char,
    caricati durante MRA download via ioctl_addr 0x080000..0x09FFFF.

    Pixel decode per (col, row) di char idx:
      byte_lo = char_lo[idx*16 + row*2 + (col>=4 ? 1 : 0)]
      byte_hi = char_hi[idx*16 + row*2 + (col>=4 ? 1 : 0)]
      sub     = 3 - (col & 3)
      pen[0]  = byte_lo[sub]
      pen[1]  = byte_lo[sub+4]
      pen[2]  = byte_hi[sub]
      pen[3]  = byte_hi[sub+4]

    Pen finale a palette = 0x700 + (color << 4) + pen, transparent se pen==15.
*/

module GundamSD_text_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	// Video timing
	input  wire  [9:0] hpos,        // 0..383
	input  wire  [8:0] vpos,        // 0..262
	input  wire        de,
	input  wire        layer_en,

	// CRTC scroll (SD Gundam Text: 128 X, 0 Y; lasciamo input parametrico)
	input  wire [15:0] scroll_x,
	input  wire [15:0] scroll_y,

	// OSD offset di rendering (debug pixel-hunting)
	input  wire signed [9:0] xoff,
	input  wire signed [9:0] yoff,

	// Text VRAM read port (4KB = 2Kw, 64*32 grid)
	output reg  [10:0] vram_addr,   // 0..2047
	input  wire [15:0] vram_data,

	// Char ROM download via ioctl (WIDE=1 → 2 byte/word a indirizzi pari)
	// rom_dl_addr = byte address relativo al txtiles (0..0x1FFFF), [0]=0
	// rom_dl_data = {byte_high, byte_low}: byte_low scritto a addr, byte_high a addr+1
	//   bit[16] = 0 → metà bassa (plane 0,1)
	//   bit[16] = 1 → metà alta  (plane 2,3)
	input  wire        rom_dl_wr,
	input  wire [16:0] rom_dl_addr,
	input  wire [15:0] rom_dl_data,

	// Output pixel
	output reg         opaque,
	output reg  [10:0] pen_index    // 0x700 + (color<<4) + pen
);

	// ── Char ROM cache: 64KB lo + 64KB hi organizzati come 32Kw 16-bit ──────
	// (Organizzazione naturale per Quartus → infer M10K word-mode veloce)
	// rom_dl_addr[16:1] = word index (0..32767), rom_dl_addr[16] = mezzo
	reg [15:0] charrom_lo [0:32767];
	reg [15:0] charrom_hi [0:32767];
	always @(posedge clk) begin
		if (rom_dl_wr) begin
			if (rom_dl_addr[16] == 1'b0) charrom_lo[rom_dl_addr[15:1]] <= rom_dl_data;
			else                          charrom_hi[rom_dl_addr[15:1]] <= rom_dl_data;
		end
	end

	// ── Pipeline ──────────────────────────────────────────────────────────────
	// Stage 0: input hpos/vpos → calc tile coords, emit vram_addr
	// Stage 1: vram_data registered, calc charrom addr
	// Stage 2: charrom byte_lo/byte_hi registered, decode pen
	// Stage 3: pen + color → pen_index latched

	// --- Stage 0: tile coords ---
	wire [15:0] eff_x = {6'd0, hpos} + scroll_x + {{6{xoff[9]}}, xoff};
	wire [15:0] eff_y = {7'd0, vpos} + scroll_y + {{6{yoff[9]}}, yoff};
	wire  [5:0] tile_x_s0 = eff_x[8:3];   // 0..63 (mod 64 implicito da bit width)
	wire  [4:0] tile_y_s0 = eff_y[7:3];   // 0..31
	wire  [2:0] row_s0    = eff_y[2:0];
	wire  [2:0] col_s0    = eff_x[2:0];

	always @(posedge clk) begin
		if (ce_pix) vram_addr <= {tile_y_s0, tile_x_s0};   // 11-bit (32*64=2048)
	end

	// --- Stage 1: vram_data, decode tile + color ---
	reg [2:0] row_s1, col_s1;
	reg       de_s1, layer_en_s1;
	always @(posedge clk) begin
		if (ce_pix) begin
			row_s1     <= row_s0;
			col_s1     <= col_s0;
			de_s1      <= de;
			layer_en_s1 <= layer_en;
		end
	end

	// vram_data è valido in stage 1 (BRAM read latency 1 ce_pix)
	wire [11:0] tile_idx_s1 = vram_data[11:0];
	wire  [3:0] tile_clr_s1 = vram_data[15:12];

	// charrom byte addr: idx*16 + row*2 + (col>=4 ? 1:0)
	// Organizzazione word 16-bit: word_addr = byte_addr[15:1], byte_sel = byte_addr[0]
	// idx*16 = idx*8 word; row*2 byte = row word; col>=4 → +1 byte = byte_sel=1
	wire [14:0] crom_word_s1 = ({3'd0, tile_idx_s1}) << 3   // idx*8 word (=idx*16 byte)
	                          | ({12'd0, row_s1});           // + row word (= +row*2 byte)
	wire        crom_byte_sel_s1 = col_s1[2];               // 1 = byte alto del word

	// --- Stage 2: charrom word read ---
	reg [15:0] crom_lo_word_s2, crom_hi_word_s2;
	reg        crom_byte_sel_s2;
	reg [2:0]  col_s2;
	reg [3:0]  tile_clr_s2;
	reg        de_s2, layer_en_s2;
	always @(posedge clk) begin
		if (ce_pix) begin
			crom_lo_word_s2  <= charrom_lo[crom_word_s1];
			crom_hi_word_s2  <= charrom_hi[crom_word_s1];
			crom_byte_sel_s2 <= crom_byte_sel_s1;
			col_s2           <= col_s1;
			tile_clr_s2      <= tile_clr_s1;
			de_s2            <= de_s1;
			layer_en_s2      <= layer_en_s1;
		end
	end

	// Estraggo i 2 byte selezionati dai word
	wire [7:0] crom_lo_s2 = crom_byte_sel_s2 ? crom_lo_word_s2[15:8] : crom_lo_word_s2[7:0];
	wire [7:0] crom_hi_s2 = crom_byte_sel_s2 ? crom_hi_word_s2[15:8] : crom_hi_word_s2[7:0];

	// --- Stage 3: pen decode ---
	// MAME readbit: bit MSB-first → src[bn/8] & (0x80 >> (bn%8))
	// In Verilog LSB-first, bit position = 7 - (bn%8).
	// Per dcon_charlayout planes={0,4,0x80000,0x80000+4}, xoff[col]=3..0 col 0..3:
	//   plane 0 col 0: bit_offs = 0+3+0 = 3 → byte_lo bit (7-3) = bit 4
	//   plane 1 col 0: bit_offs = 4+3+0 = 7 → byte_lo bit (7-7) = bit 0
	//   plane 2 col 0: bit_offs = 0x80000*8+3 → byte_hi bit 4
	//   plane 3 col 0: bit_offs = 0x80000*8+7 → byte_hi bit 0
	wire [1:0] sub = 2'd3 - col_s2[1:0];   // 3..0 per col 0..3
	// Fix D3: swap nibble alto/basso del byte (consistente con tile_layer)
	wire pen0 = crom_lo_s2[3 - {1'b0, sub}];   // plane 0
	wire pen1 = crom_lo_s2[7 - {1'b0, sub}];   // plane 1
	wire pen2 = crom_hi_s2[3 - {1'b0, sub}];   // plane 2
	wire pen3 = crom_hi_s2[7 - {1'b0, sub}];   // plane 3
	wire [3:0] pen = {pen3, pen2, pen1, pen0};

	always @(posedge clk) begin
		if (reset) begin
			opaque    <= 1'b0;
			pen_index <= 11'd0;
		end else if (ce_pix) begin
			if (de_s2 & layer_en_s2 & (pen != 4'd15)) begin
				opaque    <= 1'b1;
				pen_index <= 11'h700 + {3'd0, tile_clr_s2, pen};
			end else begin
				opaque    <= 1'b0;
				pen_index <= 11'd0;
			end
		end
	end

endmodule

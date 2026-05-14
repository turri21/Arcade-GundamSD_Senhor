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

/*  Sprite renderer Seibu SEI0211.

    Spriteram: 256 entry × 8 byte (4 word) @ 0x08F800-0x08FFFF.

    Format word (formato "comune", non alt_format) da MAME
    src/mame/seibu/sei021x_sei0220_spr.cpp:
      w0 bit 15      = enable (0=skip, 1=draw)
      w0 bit 14      = flip_x
      w0 bit 13      = flip_y
      w0 bit 12..10  = sizex (3-bit, +1) → 1..8 tile larghezza
      w0 bit 9..7    = sizey (3-bit, +1) → 1..8 tile altezza
      w0 bit 6       = ext (extra bit per priority callback)
      w0 bit 5..0    = color (6-bit, color_base = color << 4)
      w1 bit 15..14  = priority code (2-bit, → pri_cb)
      w1 bit 13..0   = tile_code (14-bit)
      w2 bit 8..0    = X (signed 9-bit)
      w3 bit 8..0    = Y (signed 9-bit)

    Tile size 16×16 4bpp = 128 byte/tile = 32 word 16-bit.
    Multi-tile: tile_code += 1 per sub-tile (TODO: ordine x-major o y-major
    da verificare con dump MAME — assunto x-major per ora).

    Priority callback dcon.cpp::pri_cb:
      pri=0 → above FG
      pri=1 → above MG
      pri=2 → above BG
      pri=3 → above Text (= sotto Text)

    Pen 15 = trasparente.

    Architettura:
      - Sprite scan FSM durante linea N: scorre 256 entry, per quelle che
        intersecano linea N+1 (target_y), fetch SDRAM dei tile coperti e
        scrive in line buffer non-attivo.
      - Read side: a hpos legge line buffer attivo, restituisce pen+pri_code.
      - Ping-pong al new_line.

    Worst case: 256 entry × max 8 sizex × 1 fetch/tile = 2048 fetch/linea.
    Realistico: 30 sprite × 4 sizex avg = 120 fetch. Banda OK.
*/

module GundamSD_sprite_renderer (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire  [9:0] hpos,        // 0..319 logico
	input  wire  [8:0] vpos,        // 0..223 logico
	input  wire        de,
	input  wire        layer_en,
	input  wire        new_line,

	// Sprite RAM read port (dual-port lato B)
	output reg   [9:0] spr_addr,    // 1024 word total (256 entry × 4 word)
	input  wire [15:0] spr_data,

	// SDRAM tile fetch via arbiter (client r3, kind=3, no cache)
	output reg         rom_req,
	output reg  [23:0] rom_addr,
	input  wire [31:0] rom_data,
	input  wire        rom_valid,

	// Output pixel
	output reg         opaque,
	output reg  [10:0] pen_index,   // sprite color base = 0 (palette[0..1023])
	output reg   [1:0] pri_code     // 2-bit priority dal w1
);

	// ─── Line buffer ping-pong (320 × 14-bit: pen[3:0] + color[5:0] + pri[1:0] + valid + flip pad) ──
	// Layout 14-bit: [13:8]=color, [7:6]=pri_code, [5:4]=00, [3:0]=pen
	// Valid pixel = pen != 0xF (sentinel "no sprite") — usiamo 0xF come "vuoto"
	// perché pen 15 reale = trasparente (skipped al draw).
	localparam [13:0] LB_EMPTY = 14'h003F;  // color=0, pri=0, pen=15 (trasparente)
	reg [13:0] linebuf0 [0:319];
	reg [13:0] linebuf1 [0:319];
	reg        active_buf;

	// ─── Sprite scan FSM ─────────────────────────────────────────────────────
	// Stati: IDLE → CLEAR (azzera buffer non-attivo a pen=15) → RW0..3 (legge
	// 4 word di entry) → CHECK → ROM_REQ/W → DECODE → NEXT_TX/E → DONE.
	localparam SC_IDLE     = 4'd0;
	localparam SC_CLEAR    = 4'd1;
	localparam SC_RW0      = 4'd2;
	localparam SC_RW1      = 4'd3;
	localparam SC_RW2      = 4'd4;
	localparam SC_RW3      = 4'd5;
	localparam SC_CHECK    = 4'd6;
	localparam SC_CHECK2   = 4'd7;
	localparam SC_ROM_REQ  = 4'd8;
	localparam SC_ROM_W    = 4'd9;
	localparam SC_DECODE   = 4'd10;
	localparam SC_NEXT_TX  = 4'd11;
	localparam SC_NEXT_E   = 4'd12;
	localparam SC_DONE     = 4'd13;

	reg [3:0] sc_state;
	reg [7:0] entry_idx;       // 0..255
	reg [8:0] clear_idx;       // 0..319 per clear buffer
	reg [15:0] sp_w0, sp_w1, sp_w2, sp_w3;
	reg        pf_side;        // 0=metà sx tile (col 0..7), 1=metà dx (col 8..15)

	// Decoded fields
	wire        sp_enable = sp_w0[15];
	wire        sp_flipx  = sp_w0[14];
	wire        sp_flipy  = sp_w0[13];
	wire  [2:0] sp_sizex  = sp_w0[12:10];      // +1 → 1..8 tile
	wire  [2:0] sp_sizey  = sp_w0[9:7];        // +1
	wire  [5:0] sp_color  = sp_w0[5:0];
	wire  [1:0] sp_pri    = sp_w1[15:14];
	wire [13:0] sp_code   = sp_w1[13:0];
	// SEI0211 get_coordinate (MAME sei021x_sei0220_spr.h):
	//   coord &= 0x1ff;
	//   return (coord >= 0x180) ? coord - 0x200 : coord;
	// Range effettivo: -128..+383 (positivi 0..0x17F, negativi 0x180..0x1FF).
	// Y: lo sprite ha direzione opposta agli altri layer → -16 (verificato HW)
	wire [8:0] sp_xraw = sp_w2[8:0];
	wire [8:0] sp_yraw = sp_w3[8:0];
	wire signed [10:0] sp_x_raw = (sp_xraw >= 9'h180) ? ({2'b00, sp_xraw} - 11'h200) : {2'b00, sp_xraw};
	wire signed [10:0] sp_y_raw = (sp_yraw >= 9'h180) ? ({2'b00, sp_yraw} - 11'h200) : {2'b00, sp_yraw};
	wire signed [10:0] sp_x = sp_x_raw;
	wire signed [10:0] sp_y = sp_y_raw - 11'sd16;

	wire [3:0] sp_w  = {1'b0, sp_sizex} + 4'd1;    // 1..8
	wire [3:0] sp_h  = {1'b0, sp_sizey} + 4'd1;    // 1..8

	// Target Y per la linea che stiamo prefetchando (= linea corrente + 1, wrap)
	wire [8:0] target_y = (vpos == 9'd223) ? 9'd0 : (vpos + 9'd1);

	// Sprite intersect check: target_y in [sp_y, sp_y + sp_h*16)
	wire signed [10:0] dy_top = {2'b00, target_y} - sp_y;
	wire        in_y     = (dy_top >= 0) && (dy_top < {3'd0, sp_h, 4'd0});  // sp_h*16
	wire  [3:0] tile_y_in = dy_top[7:4];   // tile row 0..7 dentro sprite
	wire  [3:0] row_in    = dy_top[3:0];   // row dentro tile 0..15
	// flip Y
	wire  [3:0] eff_tile_y = sp_flipy ? (sp_h - 4'd1 - tile_y_in) : tile_y_in;
	wire  [3:0] eff_row    = sp_flipy ? (4'd15 - row_in)          : row_in;

	// Iteratore tile_x
	reg  [3:0] tile_x_pf;
	reg [31:0] pf_rom_data;
	reg  [3:0] decode_step;
	wire  [3:0] eff_tile_x = sp_flipx ? (sp_w - 4'd1 - tile_x_pf) : tile_x_pf;

	// Tile code finale Y-MAJOR (MAME draw_internal: ax=outer, ay=inner, code++):
	//   sub_index = ax*sizey + ay  →  cur_tile = code + eff_tile_x*sp_h + eff_tile_y
	wire [13:0] cur_tile = sp_code + ({10'd0, eff_tile_x} * {10'd0, sp_h}) + {10'd0, eff_tile_y};

	// new_line gating
	wire vpos_visible = (vpos < 9'd224);
	wire gated_new_line = new_line & vpos_visible;

	always @(posedge clk) begin
		if (reset) begin
			sc_state    <= SC_IDLE;
			entry_idx   <= 8'd255;
			tile_x_pf   <= 4'd0;
			rom_req     <= 1'b0;
			spr_addr    <= 10'd0;
			active_buf  <= 1'b0;
			decode_step <= 4'd0;
			clear_idx   <= 9'd0;
		end else begin
			case (sc_state)
				SC_IDLE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						// First-win: scan da entry 255 → 0, così entry 0 (scritta
						// per ultima) sovrascrive le altre = entry 0 sopra in priorità
						entry_idx  <= 8'd255;
						tile_x_pf  <= 4'd0;
						clear_idx  <= 9'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				// CLEAR: azzera 320 entry del buffer non-attivo a LB_EMPTY (pen=15
				// trasparente) per evitare ghost da scanline precedente.
				SC_CLEAR: begin
					if (active_buf == 1'b0)
						linebuf1[clear_idx] <= LB_EMPTY;
					else
						linebuf0[clear_idx] <= LB_EMPTY;
					if (clear_idx == 9'd319) begin
						clear_idx <= 9'd0;
						spr_addr  <= {entry_idx, 2'd0};   // primo scan = entry 255
						sc_state  <= SC_RW0;
					end else begin
						clear_idx <= clear_idx + 9'd1;
					end
				end

				// Lettura 4 word entry: BRAM dual-port latency 1 ce_pix → wait state
				SC_RW0: begin
					spr_addr <= {entry_idx, 2'd1};   // pre-emit addr w1
					sc_state <= SC_RW1;
				end
				SC_RW1: begin
					sp_w0    <= spr_data;            // w0 valido
					spr_addr <= {entry_idx, 2'd2};
					sc_state <= SC_RW2;
				end
				SC_RW2: begin
					sp_w1    <= spr_data;
					spr_addr <= {entry_idx, 2'd3};
					sc_state <= SC_RW3;
				end
				SC_RW3: begin
					sp_w2    <= spr_data;
					sc_state <= SC_CHECK;
				end

				// SC_CHECK: latcho sp_w3 dal spr_data corrente. Decisione spostata
				// al ciclo SUCCESSIVO per dare tempo a sp_w3 di propagarsi nei wire
				// derived (sp_y, in_y, dy_top). Senza wait, in_y usava sp_y vecchio
				// → tile fetchati a coordinate sbagliate, sub-tile in posti errati.
				SC_CHECK: begin
					sp_w3    <= spr_data;
					sc_state <= SC_CHECK2;
				end

				SC_CHECK2: begin
					if (sp_enable && in_y && layer_en) begin
						tile_x_pf <= 4'd0;
						pf_side   <= 1'b0;
						sc_state  <= SC_ROM_REQ;
					end else begin
						sc_state <= SC_NEXT_E;
					end
				end

				SC_ROM_REQ: begin
					// Sprite tile addr in SDRAM region (byte_offset relativo):
					// tile_code * 128 (32 word) + (pf_side ? 64 byte : 0) + eff_row * 4
					rom_addr <= ({4'd0, cur_tile, 7'd0})        // tile*128
					           + (pf_side ? 24'd64 : 24'd0)     // metà dx tile
					           + ({18'd0, eff_row, 2'd0});       // row*4
					rom_req  <= 1'b1;
					sc_state <= SC_ROM_W;
				end

				SC_ROM_W: begin
					if (rom_valid) begin
						pf_rom_data <= rom_data;
						rom_req     <= 1'b0;
						decode_step <= 4'd0;
						sc_state    <= SC_DECODE;
					end
				end

				SC_DECODE: begin
					begin : sp_decode_blk
						reg [7:0] byte_lo, byte_hi;
						reg [1:0] sub;
						reg [3:0] pen;
						reg signed [10:0] dx;
						reg [4:0] eff_col;   // 0..15 (full tile width)
						// dcon_tilelayout: rom_data 32-bit = 8 pixel per row.
						// pf_side=0 → pixel col 0..7, pf_side=1 → col 8..15 (offset +64 byte).
						if (decode_step[2] == 1'b0) begin
							byte_lo = pf_rom_data[31:24];
							byte_hi = pf_rom_data[23:16];
						end else begin
							byte_lo = pf_rom_data[15:8];
							byte_hi = pf_rom_data[7:0];
						end
						sub = 2'd3 - decode_step[1:0];
						pen[2] = byte_lo[3 - {1'b0, sub}];
						pen[3] = byte_lo[7 - {1'b0, sub}];
						pen[0] = byte_hi[3 - {1'b0, sub}];
						pen[1] = byte_hi[7 - {1'b0, sub}];

						// Posizione pixel sullo schermo: sp_x + tile_x_pf*16 + col_in_tile
						// col_in_tile = pf_side*8 + decode_step[2:0]
						// flipX: col_in_tile = 15 - col_in_tile
						eff_col = sp_flipx ? (5'd15 - {pf_side, decode_step[2:0]})
						                   : {pf_side, decode_step[2:0]};
						dx = sp_x + ({6'd0, tile_x_pf, 4'd0}) + {6'd0, eff_col};

						if (pen != 4'd15 && dx >= 0 && dx < 320) begin
							if (active_buf == 1'b0)
								linebuf1[dx[8:0]] <= {sp_color, sp_pri, 2'd0, pen};
							else
								linebuf0[dx[8:0]] <= {sp_color, sp_pri, 2'd0, pen};
						end
					end
					if (decode_step == 4'd7) sc_state <= SC_NEXT_TX;
					else                     decode_step <= decode_step + 4'd1;
				end

				SC_NEXT_TX: begin
					if (pf_side == 1'b0) begin
						// Appena finito metà sx → fai metà dx dello stesso tile
						pf_side  <= 1'b1;
						sc_state <= SC_ROM_REQ;
					end else begin
						// Finito anche metà dx → passa al prossimo tile_x o entry
						pf_side <= 1'b0;
						if (tile_x_pf == sp_w - 4'd1) begin
							sc_state <= SC_NEXT_E;
						end else begin
							tile_x_pf <= tile_x_pf + 4'd1;
							sc_state  <= SC_ROM_REQ;
						end
					end
				end

				SC_NEXT_E: begin
					// Scan decrescente: 255 → 254 → ... → 0, poi DONE
					if (entry_idx == 8'd0) begin
						sc_state <= SC_DONE;
					end else begin
						entry_idx <= entry_idx - 8'd1;
						spr_addr  <= {entry_idx - 8'd1, 2'd0};
						sc_state  <= SC_RW0;
					end
				end

				SC_DONE: begin
					if (gated_new_line) begin
						active_buf <= ~active_buf;
						entry_idx  <= 8'd255;       // first-win scan
						tile_x_pf  <= 4'd0;
						clear_idx  <= 9'd0;
						sc_state   <= SC_CLEAR;
					end
				end

				default: sc_state <= SC_IDLE;
			endcase

			// Clear line buffer non-attivo all'inizio del nuovo new_line
			// (in realtà serve clear durante DONE → ma qui non si può scrivere
			// 320 entry per ce_pix; per semplicità il DONE dovrebbe blankarlo
			// — lascio come TODO, sprite "ghost" possibili nelle linee dove
			// nessun sprite scrive)
		end
	end

	// ─── Read side combinatoriale ────────────────────────────────────────────
	wire [13:0] read_data = active_buf ? linebuf1[hpos[8:0]] : linebuf0[hpos[8:0]];
	wire  [3:0] read_pen   = read_data[3:0];
	wire  [1:0] read_pri   = read_data[7:6];
	wire  [5:0] read_color = read_data[13:8];

	always @(posedge clk) begin
		if (reset) begin
			opaque    <= 1'b0;
			pen_index <= 11'd0;
			pri_code  <= 2'd0;
		end else if (ce_pix) begin
			if (de & layer_en & (hpos < 10'd320) & (read_pen != 4'd15)) begin
				opaque    <= 1'b1;
				pen_index <= {1'b0, read_color, read_pen};   // sprite palette base = 0
				pri_code  <= read_pri;
			end else begin
				opaque    <= 1'b0;
				pen_index <= 11'd0;
				pri_code  <= 2'd0;
			end
		end
	end

endmodule

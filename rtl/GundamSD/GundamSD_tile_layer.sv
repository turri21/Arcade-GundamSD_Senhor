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

/*  Tile-layer parametrico Seibu D-Con (16x16, 4bpp, 32x32).

    Modulo unico per BG / MG / FG. Differenze fra layer (da MAME dcon.cpp):

      LAYER  COLOR_BASE  TRANSP  GFX_BANK  TILE_KIND  SCROLL+128
      BG     0x400       no      no        0          sì
      MG     0x500       sì(15)  sì        1          sì
      FG     0x600       sì(15)  no        2          sì

    Parametri:
      COLOR_BASE   : 11-bit base palette
      HAS_TRANSP   : 1=pen 15 trasparente, 0=sempre opaco
      HAS_GFX_BANK : 1=tile_idx |= gfx_bank_select (per MG)
      TILE_KIND    : 3-bit kind passato a SDRAM arbiter

    Architettura: line buffer ping-pong + prefetcher SDRAM (vedi BG renderer
    cancellato — qui generalizzato).

    Decode tile (dcon_tilelayout):
      base_left  = idx*128 + row*4
      base_right = idx*128 + 64 + row*4
      gruppo (col_local 0..3 di sx o dx) — fetch 32-bit a base+offset:
        byte0 = base+0 (plane 2,3)
        byte1 = base+1 (plane 0,1)
      sub      = 3 - col[1:0]
      pen      = {byte_lo[sub+4], byte_lo[sub], byte_hi[sub+4], byte_hi[sub]}
*/

module GundamSD_tile_layer #(
	parameter [10:0] COLOR_BASE   = 11'h400,
	parameter        HAS_TRANSP   = 0,
	parameter        HAS_GFX_BANK = 0,
	parameter  [2:0] TILE_KIND    = 3'd0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,

	input  wire  [9:0] hpos,
	input  wire  [8:0] vpos,
	input  wire        de,
	input  wire        layer_en,
	input  wire        new_line,

	input  wire [15:0] scroll_x,
	input  wire [15:0] scroll_y,

	// OSD offset di rendering (debug pixel-hunting, indipendente dallo scroll content)
	input  wire signed [9:0] xoff,
	input  wire signed [9:0] yoff,

	// Solo per MG: high bits aggiunti al tile_idx
	input  wire [15:0] gfx_bank,

	// VRAM read port (CPU dual-port lato B)
	output reg  [10:0] vram_addr,
	input  wire [15:0] vram_data,

	// SDRAM tile fetch via arbiter
	output reg         rom_req,
	output reg  [23:0] rom_addr,
	input  wire [31:0] rom_data,
	input  wire        rom_valid,

	// Output pixel
	output reg         opaque,
	output reg  [10:0] pen_index
);

	// ─── Line buffers (ping-pong) ────────────────────────────────────────────
	// 12 bit/pixel: {color[3:0], 4'd0, pen[3:0]} → ricostruito al read in pen_index
	// Bit10 (extra) per "pen=15 transparent" = bit 7 del campo a 12 bit (impostato da decode)
	// Layout: [11:8]=color, [7]=transp_flag, [6:4]=000, [3:0]=pen
	(* ramstyle = "M10K" *) reg [11:0] linebuf0 [0:319];
	(* ramstyle = "M10K" *) reg [11:0] linebuf1 [0:319];
	reg        active_buf;

	// Prefetcher state
	reg  [4:0] tile_col_pf;
	reg  [3:0] pf_state;
	reg [11:0] pf_tile_idx;
	reg  [3:0] pf_tile_clr;
	reg        pf_side;
	reg [31:0] pf_rom_data;
	reg  [3:0] decode_step;

	localparam PF_IDLE    = 4'd0;
	localparam PF_VRAM_R  = 4'd1;
	localparam PF_VRAM_W  = 4'd2;
	localparam PF_VRAM_W2 = 4'd3;   // wait extra: BRAM read latency
	localparam PF_ROM_REQ = 4'd4;
	localparam PF_ROM_W   = 4'd5;
	localparam PF_DECODE  = 4'd6;
	localparam PF_NEXT    = 4'd7;
	localparam PF_DONE    = 4'd8;
	localparam PF_ROM_ADDR = 4'd9;   // stadio pipeline: registra effective_tile_idx (spezza il path lungo)

	// Coordinate prefetch — target = riga da mostrare al new_line successivo.
	//
	// Logica corretta (non più gated VBLANK):
	//   Durante display vpos=N (N<V_VISIBLE-1): prefetch riga N+1 nel buffer
	//     non-attivo. Al new_line N→N+1: swap → display mostra riga N+1.
	//   Durante display vpos=V_VISIBLE-1: prefetch riga 0 (next frame).
	//   Durante VBLANK (vpos >= V_VISIBLE): prefetch IGNORATO (= idle), così
	//     il buffer caricato durante vpos=V_VISIBLE-1 non viene sovrascritto.
	//
	// Toggle buffer al new_line — solo quando entriamo in una riga visibile
	// (vpos=0..V_VISIBLE-1 dopo wrap).
	//
	// PROBLEMA tempistico: la prefetch parte al new_line che inizia riga N+1.
	// Durante riga N+1 il prefetch sta caricando il buffer per riga N+2.
	// Al new_line N+1→N+2 swap → buffer ora-pieno diventa attivo.
	// → FUNZIONA solo se il prefetch finisce ENTRO una riga (= 384 pixel × 16 cicli
	//    = 6144 cicli). Per 21 tile × 2 fetch × ~30 cicli = ~1260 cicli. OK ✓
	//
	// PRIMA RIGA del frame: serve buffer pre-caricato durante VBLANK precedente.
	//   Soluzione: durante riga V_VISIBLE-1 prefetch fa target_y=0 (next frame),
	//   poi VBLANK no toggle. Al wrap V_TOTAL→0 SWAP → buffer ha riga 0 pronta.
	localparam [8:0] V_VISIBLE = 9'd224;
	wire [15:0] target_y = (vpos == V_VISIBLE - 9'd1) ? 16'd0
	                                                  : ({7'd0, vpos} + 16'd1);
	wire [15:0] eff_y_pf = target_y + scroll_y_l + {{6{yoff[9]}}, yoff};
	wire  [4:0] tile_y_pf = eff_y_pf[8:4];
	wire  [3:0] row_pf    = eff_y_pf[3:0];

	// gated_new_line: trigger prefetch SOLO quando new vpos è visible.
	// Durante VBLANK no swap, no nuovo prefetch.
	wire vpos_visible    = (vpos < V_VISIBLE);
	wire gated_new_line  = new_line & vpos_visible;

	// FIX glitch (spec. MID layer): scroll_x/scroll_y/gfx_bank sono scritti dalla
	// CPU in tempo reale. Usati LIVE, se la CPU li cambia DURANTE il prefetch di
	// una riga (~1260 cicli) i tile della riga usano valori misti -> glitch. Il
	// MG glitcha di piu' perche' e' l'unico con gfx_bank (bank tile, molto
	// volatile). Fix: LATCH dei 3 valori all'inizio del prefetch di ogni riga
	// (gated_new_line / PF_DONE swap), stabili per tutta la riga.
	reg [15:0] scroll_x_l, scroll_y_l, gfx_bank_l;
	wire pf_line_start = (pf_state == PF_IDLE || pf_state == PF_DONE) && gated_new_line;
	always @(posedge clk) if (reset) begin
		scroll_x_l <= 16'd0; scroll_y_l <= 16'd0; gfx_bank_l <= 16'd0;
	end else if (pf_line_start) begin
		scroll_x_l <= scroll_x;
		scroll_y_l <= scroll_y;
		gfx_bank_l <= gfx_bank;
	end

	wire [4:0] first_tile_x   = scroll_x_l[8:4];
	wire [3:0] first_pixel_off = scroll_x_l[3:0];

	wire [4:0] cur_tile_x = first_tile_x + tile_col_pf;
	wire signed [10:0] dst_x_signed = ({1'b0, tile_col_pf, 4'd0}) - {7'd0, first_pixel_off} + {{1{xoff[9]}}, xoff};

	// Tile index con eventuale gfx_bank (MG ha bit 12 = 13-bit totali, BG/FG = 12 bit)
	wire [12:0] effective_tile_idx = HAS_GFX_BANK
	                                  ? ({1'b0, pf_tile_idx} | gfx_bank_l[12:0])
	                                  : {1'b0, pf_tile_idx};

	// PIPELINE rom_addr: effective_tile_idx (OR con gfx_bank, poi <<7) registrato
	// in uno stadio dedicato (PF_ROM_ADDR). Cosi' PF_ROM_REQ calcola rom_addr da
	// un valore GIA' registrato -> path corto, chiude a 96 MHz. MG (HAS_GFX_BANK)
	// e' quello che glitchava di piu': gfx_bank allarga il termine idx<<7.
	reg [12:0] eff_tile_idx_r;

	// PIPELINE dx (write addr linebuf): dst_x_signed dipende da tile_col_pf,
	// scroll_x_l, xoff -> STABILE per tutto il decode del tile (8 pixel). Lo
	// registro una volta in PF_ROM_ADDR. Nel DECODE dx = dst_x_base_r + side +
	// step -> somma corta. Prima dst_x_signed (sottrazione+2 somme 11-bit) era
	// combinatorio DENTRO il decode fino al write-addr BRAM -> path -0.83.
	reg signed [10:0] dst_x_base_r;

	// ─── Prefetcher main FSM ─────────────────────────────────────────────────
	always @(posedge clk) begin
		if (reset) begin
			pf_state    <= PF_IDLE;
			tile_col_pf <= 5'd0;
			rom_req     <= 1'b0;
			vram_addr   <= 11'd0;
			active_buf  <= 1'b0;
			decode_step <= 4'd0;
			pf_side     <= 1'b0;
		end else begin
			case (pf_state)
				PF_IDLE: begin
					if (gated_new_line) begin
						active_buf  <= ~active_buf;
						tile_col_pf <= 5'd0;
						pf_side     <= 1'b0;
						pf_state    <= PF_VRAM_R;
					end
				end

				PF_VRAM_R: begin
					// Emetto vram_addr (registered alla fine di questo ciclo).
					vram_addr <= {1'b0, tile_y_pf, cur_tile_x};
					pf_state  <= PF_VRAM_W;
				end

				PF_VRAM_W: begin
					// vram_addr è effettivo all'inizio di questo ciclo.
					// La BRAM dual_port produce vram_data alla FINE di questo ciclo
					// (registered output). Quindi vram_data sarà valido in PF_VRAM_W2.
					pf_state <= PF_VRAM_W2;
				end

				PF_VRAM_W2: begin
					// vram_data ora valido (= dato di addr emesso in PF_VRAM_R).
					pf_tile_idx <= vram_data[11:0];
					pf_tile_clr <= vram_data[15:12];
					pf_state    <= PF_ROM_ADDR;
				end

				// STADIO PIPELINE 1: registra effective_tile_idx. pf_tile_idx e'
				// appena diventato valido (registrato in PF_VRAM_W2) -> qui e' stabile.
				PF_ROM_ADDR: begin
					eff_tile_idx_r <= effective_tile_idx;
					dst_x_base_r   <= dst_x_signed;   // stabile per l'intero tile
					pf_state       <= PF_ROM_REQ;
				end

				PF_ROM_REQ: begin
					// STADIO PIPELINE 2: rom_addr da eff_tile_idx_r GIA' registrato.
					// rom_addr = tile_idx*128 + side_off + row*4
					// effective_tile_idx = 13 bit (MG con bank ha tile fino a 8191)
					// idx*128 = idx<<7. Con idx 13 bit, idx*128 sta in 20 bit.
					rom_addr <= ({4'd0, eff_tile_idx_r, 7'd0})
					           + (pf_side ? 24'd64 : 24'd0)
					           + ({18'd0, row_pf, 2'd0});
					rom_req  <= 1'b1;
					pf_state <= PF_ROM_W;
				end

				PF_ROM_W: begin
					if (rom_valid) begin
						pf_rom_data <= rom_data;
						rom_req     <= 1'b0;
						decode_step <= 4'd0;
						pf_state    <= PF_DECODE;
					end
				end

				PF_DECODE: begin
					begin : decode_blk
						reg [7:0] byte_lo, byte_hi;
						reg [1:0] sub;
						reg [3:0] pen;
						reg signed [10:0] dx;
						reg        transp;
						if (decode_step[2] == 1'b0) begin
							byte_lo = pf_rom_data[31:24];
							byte_hi = pf_rom_data[23:16];
						end else begin
							byte_lo = pf_rom_data[15:8];
							byte_hi = pf_rom_data[7:0];
						end
						// MAME readbit: src[bitnum/8] & (0x80 >> (bitnum%8))  (MSB-first)
						// Verilog è LSB-first: bit posizione = 7 - (bitnum%8).
						// Per dcon_tilelayout planes={8,12,0,4}, xoff[col]=3..0 (col 0..3):
						//   plane 2 col 0: bit_offs = 0+3+0 = 3 → byte_lo bit (7-3) = bit 4
						//   plane 3 col 0: bit_offs = 4+3+0 = 7 → byte_lo bit (7-7) = bit 0
						//   plane 0 col 0: bit_offs = 8+3+0 = 11 → byte_hi bit (7-3) = bit 4
						//   plane 1 col 0: bit_offs = 12+3+0 = 15 → byte_hi bit (7-7) = bit 0
						sub = 2'd3 - decode_step[1:0];   // 3..0 per col 0..3
						// (7 - sub) = bit del nibble basso (planes 2,0)
						// (3 - sub) = bit del nibble alto (planes 3,1)
						// D3: swap nibble alto/basso del byte (planes 2↔3 e 0↔1)
						pen[2] = byte_lo[3 - {1'b0, sub}];   // plane 2 (era 7-sub)
						pen[3] = byte_lo[7 - {1'b0, sub}];   // plane 3 (era 3-sub)
						pen[0] = byte_hi[3 - {1'b0, sub}];   // plane 0
						pen[1] = byte_hi[7 - {1'b0, sub}];   // plane 1
						transp = (HAS_TRANSP != 0) && (pen == 4'd15);
						dx = dst_x_base_r + (pf_side ? 11'sd8 : 11'sd0) + {8'd0, decode_step[2:0]};
						if (dx >= 0 && dx < 320) begin
							if (active_buf == 1'b0)
								linebuf1[dx[8:0]] <= {pf_tile_clr, transp, 3'd0, pen};
							else
								linebuf0[dx[8:0]] <= {pf_tile_clr, transp, 3'd0, pen};
						end
					end
					if (decode_step == 4'd7) begin
						pf_state <= PF_NEXT;
					end else begin
						decode_step <= decode_step + 4'd1;
					end
				end

				PF_NEXT: begin
					if (pf_side == 1'b0) begin
						pf_side  <= 1'b1;
						pf_state <= PF_ROM_REQ;
					end else begin
						pf_side <= 1'b0;
						if (tile_col_pf == 5'd20) begin
							pf_state <= PF_DONE;
						end else begin
							tile_col_pf <= tile_col_pf + 5'd1;
							pf_state    <= PF_VRAM_R;
						end
					end
				end

				PF_DONE: begin
					if (gated_new_line) begin
						active_buf  <= ~active_buf;
						tile_col_pf <= 5'd0;
						pf_side     <= 1'b0;
						pf_state    <= PF_VRAM_R;
					end
				end

				default: pf_state <= PF_IDLE;
			endcase
		end
	end

	// ─── Read side REGISTRATO (M10K, stabile, latenza compensata) ────────────
	// Linebuf forzato M10K e letto in modo REGISTRATO (read-port sincrono) ->
	// M10K read registrato (stabile). Leggo linebuf[hpos] e ritardo de/hpos di
	// 1 ce_pix per compensare la latenza -> allineamento pixel CORRETTO.
	reg [11:0] read_data;
	reg        de_d;
	reg        valid_d;
	always @(posedge clk) if (ce_pix) begin
		read_data <= active_buf ? linebuf1[hpos[8:0]] : linebuf0[hpos[8:0]];
		de_d      <= de;
		valid_d   <= layer_en & (hpos < 10'd320);
	end
	wire [3:0] read_color = read_data[11:8];
	wire       read_transp = read_data[7];
	wire [3:0] read_pen   = read_data[3:0];

	always @(posedge clk) begin
		if (reset) begin
			opaque    <= 1'b0;
			pen_index <= 11'd0;
		end else if (ce_pix) begin
			if (de_d & valid_d & ~read_transp) begin
				opaque    <= 1'b1;
				pen_index <= COLOR_BASE + {3'd0, read_color, read_pen};
			end else begin
				opaque    <= 1'b0;
				pen_index <= 11'd0;
			end
		end
	end

endmodule

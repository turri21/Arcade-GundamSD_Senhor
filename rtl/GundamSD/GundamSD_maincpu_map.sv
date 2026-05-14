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

/*  Main CPU memory map (FSM TXN per accessi BRAM).

    Pattern FSM Darius (darius_maincpu_map): per ogni BRAM-backed region
    facciamo IDLE → WAIT (1 ciclo per latenza BRAM) → DONE (cs=1, busy=0).
    Per ROM SDRAM: busy=~rom_ready (level signal del bridge).

    Memory map SD Gundam (da MAME dcon.cpp + sdgndmps_map override):
      $000000-$07FFFF  ROM 68K (512KB)         → SDRAM via bridge
      $080000-$08BFFF  Main RAM (48KB)         → BRAM
      $08C000-$08C7FF  BG  tile RAM            → BRAM dual-port
      $08C800-$08CFFF  FG  tile RAM            → BRAM dual-port
      $08D000-$08D7FF  MG  tile RAM            → BRAM dual-port
      $08D800-$08E7FF  Text tile RAM           → BRAM dual-port
      $08E800-$08F7FF  Palette RAM             → BRAM dual-port
      $08F800-$08FFFF  Sprite RAM              → BRAM
      $09D000-$09D7FF  GFX bank select         → reg
      $0A0000-$0A000D  Seibu sound comm        → reg
      $0C0000-$0C004F  Seibu CRTC              → modulo CRTC esterno
      $0E0000-$0E0001  DIP switches            → input
      $0E0002-$0E0003  Player inputs (P1+P2)   → input
      $0E0004-$0E0005  System inputs           → input
*/

module GundamSD_maincpu_map (
	input  wire        clk,
	input  wire        reset,
	// CPU bus (dal cpu_node)
	input  wire [23:0] bus_addr,
	input  wire        bus_asn,
	input  wire        bus_rnw,
	input  wire  [1:0] bus_dsn,
	input  wire [15:0] bus_wdata,
	output reg  [15:0] bus_rdata,
	output reg         bus_cs,
	output reg         bus_busy,
	// Inputs
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire [15:0] system_input,
	input  wire [15:0] dsw_input,
	// Main ROM (SDRAM bridge)
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,
	output wire [23:0] main_rom_addr,
	output wire        main_rom_req,
	// Main RAM
	input  wire [15:0] ram_rdata,
	output wire        ram_we,
	output wire [14:0] ram_addr,
	output wire [15:0] ram_wdata,
	output wire  [1:0] ram_be,
	// BG/MG/FG/Text/Palette/Sprite VRAM (CPU side)
	input  wire [15:0] bg_rdata,
	output wire        bg_we,
	input  wire [15:0] mg_rdata,
	output wire        mg_we,
	input  wire [15:0] fg_rdata,
	output wire        fg_we,
	input  wire [15:0] txt_rdata,
	output wire        txt_we,
	input  wire [15:0] pal_rdata,
	output wire        pal_we,
	input  wire [15:0] spr_rdata,
	output wire        spr_we,
	output wire [10:0] vram_addr,    // bus_addr[11:1] = 11 bit, copre tutte le VRAM (max Text 2Kw)
	output wire [15:0] vram_wdata,
	output wire  [1:0] vram_be,
	// Seibu CRTC (modulo esterno)
	output wire        crtc_cs,
	output wire        crtc_wr,
	output wire        crtc_rd,
	output wire  [6:1] crtc_addr,
	input  wire [15:0] crtc_rdata,
	// GFX bank register
	output reg  [15:0] gfx_bank,
	// Sound comm (Seibu COP)
	output wire        snd_cs,
	output wire        snd_wr,
	output wire        snd_rd,
	output wire  [3:1] snd_addr,
	output wire [15:0] snd_wdata,
	input  wire [15:0] snd_rdata
);

	// ─── Region detect ───────────────────────────────────────────────────────
	wire bus_active = ~bus_asn;
	wire is_rom     = bus_active && (bus_addr <  24'h080000);
	wire is_ram     = bus_active && (bus_addr >= 24'h080000) && (bus_addr < 24'h08C000);
	wire is_bg      = bus_active && (bus_addr >= 24'h08C000) && (bus_addr < 24'h08C800);
	wire is_fg      = bus_active && (bus_addr >= 24'h08C800) && (bus_addr < 24'h08D000);
	wire is_mg      = bus_active && (bus_addr >= 24'h08D000) && (bus_addr < 24'h08D800);
	wire is_text    = bus_active && (bus_addr >= 24'h08D800) && (bus_addr < 24'h08E800);
	wire is_pal     = bus_active && (bus_addr >= 24'h08E800) && (bus_addr < 24'h08F800);
	wire is_spr     = bus_active && (bus_addr >= 24'h08F800) && (bus_addr < 24'h090000);
	wire is_gfxbank = bus_active && (bus_addr >= 24'h09D000) && (bus_addr < 24'h09D800);
	wire is_snd     = bus_active && (bus_addr >= 24'h0A0000) && (bus_addr < 24'h0A0010);
	wire is_crtc    = bus_active && (bus_addr >= 24'h0C0000) && (bus_addr < 24'h0C0050);
	wire is_dip     = bus_active && (bus_addr >= 24'h0E0000) && (bus_addr < 24'h0E0002);
	wire is_pin     = bus_active && (bus_addr >= 24'h0E0002) && (bus_addr < 24'h0E0004);
	wire is_sin     = bus_active && (bus_addr >= 24'h0E0004) && (bus_addr < 24'h0E0006);

	wire is_bram    = is_ram | is_bg | is_fg | is_mg | is_text | is_pal | is_spr;
	wire is_io      = is_dip | is_pin | is_sin;

	// ─── ROM access (SDRAM bridge) ───────────────────────────────────────────
	assign main_rom_addr = {1'b0, bus_addr[22:1], 1'b0};
	assign main_rom_req  = is_rom & bus_rnw;

	// ─── BRAM common write/byte-enable ──────────────────────────────────────
	wire write = bus_active & ~bus_rnw & (|(~bus_dsn));
	assign vram_addr  = bus_addr[11:1];
	assign vram_wdata = bus_wdata;
	assign vram_be    = ~bus_dsn;
	assign ram_addr   = bus_addr[15:1];
	assign ram_wdata  = bus_wdata;
	assign ram_be     = ~bus_dsn;
	assign ram_we     = is_ram  & write;
	assign bg_we      = is_bg   & write;
	assign mg_we      = is_mg   & write;
	assign fg_we      = is_fg   & write;
	assign txt_we     = is_text & write;
	assign pal_we     = is_pal  & write;
	assign spr_we     = is_spr  & write;

	// ─── CRTC ────────────────────────────────────────────────────────────────
	assign crtc_cs    = is_crtc;
	assign crtc_wr    = is_crtc & write;
	assign crtc_rd    = is_crtc & bus_rnw;
	assign crtc_addr  = bus_addr[6:1];

	// ─── Sound comm (Seibu COP) ──────────────────────────────────────────────
	assign snd_cs    = is_snd;
	assign snd_wr    = is_snd & write;
	assign snd_rd    = is_snd & bus_rnw;
	assign snd_addr  = bus_addr[3:1];
	assign snd_wdata = bus_wdata;

	// ─── GFX bank register ───────────────────────────────────────────────────
	// MAME dcon.cpp gfxbank_w: SOLO bit0 → m_gfx_bank_select = 0x1000 oppure 0.
	// Il valore esposto è un mask 13-bit (bit 12 attivo) che il MG OR-a al tile_idx.
	always @(posedge clk) begin
		if (reset)                   gfx_bank <= 16'd0;
		else if (is_gfxbank & write) gfx_bank <= bus_wdata[0] ? 16'h1000 : 16'h0000;
	end

	// ─── FSM TXN per gestire latenza BRAM ───────────────────────────────────
	// Pattern Darius: ogni accesso BRAM passa per IDLE → WAIT1 → DONE
	// in modo che bus_busy stia high per 1 ciclo dopo address valid, dando
	// tempo alla BRAM di restituire il dato.
	// Per ROM/CRTC/IO/regs: nessun wait (cs subito).
	localparam S_IDLE = 2'd0;
	localparam S_WAIT = 2'd1;
	localparam S_DONE = 2'd2;

	reg [1:0] state;

	always @(posedge clk) begin
		if (reset) begin
			state <= S_IDLE;
		end else begin
			case (state)
				S_IDLE: if (is_bram) state <= S_WAIT;
				S_WAIT:              state <= S_DONE;
				// Quando il bus si abbassa (asn=1), torno a IDLE e attendo nuovo accesso
				S_DONE: if (~bus_active) state <= S_IDLE;
				default: state <= S_IDLE;
			endcase
		end
	end

	// ─── Read mux + bus_cs / bus_busy ───────────────────────────────────────
	always @(*) begin
		bus_rdata = 16'hFFFF;
		bus_cs    = 1'b0;
		bus_busy  = 1'b0;

		if (is_rom) begin
			bus_rdata = main_rom_rdata;
			bus_cs    = 1'b1;
			bus_busy  = ~main_rom_ready;
		end
		else if (is_bram) begin
			// BRAM: cs=1 e busy=0 SOLO quando state=DONE (dato pronto).
			// Durante S_IDLE/S_WAIT, busy=1 per tenere CPU stallata.
			if (state == S_DONE) begin
				bus_cs = 1'b1;
				if (is_ram)        bus_rdata = ram_rdata;
				else if (is_bg)    bus_rdata = bg_rdata;
				else if (is_fg)    bus_rdata = fg_rdata;
				else if (is_mg)    bus_rdata = mg_rdata;
				else if (is_text)  bus_rdata = txt_rdata;
				else if (is_pal)   bus_rdata = pal_rdata;
				else /* is_spr */  bus_rdata = spr_rdata;
			end else begin
				bus_busy = 1'b1;
			end
		end
		else if (is_gfxbank) begin
			bus_rdata = gfx_bank;
			bus_cs    = 1'b1;
		end
		else if (is_snd) begin
			bus_rdata = snd_rdata;
			bus_cs    = 1'b1;
		end
		else if (is_crtc) begin
			bus_rdata = crtc_rdata;
			bus_cs    = 1'b1;
		end
		else if (is_dip) begin
			bus_rdata = dsw_input;
			bus_cs    = 1'b1;
		end
		else if (is_pin) begin
			bus_rdata = {p2_input, p1_input};
			bus_cs    = 1'b1;
		end
		else if (is_sin) begin
			bus_rdata = system_input;   // 16-bit pieno (bit 12 = SERVICE, era troncato)
			bus_cs    = 1'b1;
		end
		else if (bus_active) begin
			// Out-of-map: open bus, ack subito per evitare deadlock
			bus_rdata = 16'hFFFF;
			bus_cs    = 1'b1;
		end
	end

endmodule

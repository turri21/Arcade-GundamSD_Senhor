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

// GundamSD_main_top — Top SD Gundam (1× M68000 @ 10 MHz, hardware Seibu D-Con).
//
// Sostituisce il top dual-68k Darius. Mantiene la STESSA interfaccia di
// darius_dual68k_top per non toccare GundamSD.sv:
//   - tutte le porte sub_* restano nel modulo ma vengono ignorate o forzate a 0
//   - tutti i segnali video/audio escono per ora come stub (schermo nero,
//     audio già stubbato in GundamSD_audio_stub.sv)
//
// Memory map SD Gundam (da MAME dcon.cpp + SD Gundam override):
//   $000000-$07FFFF  ROM 68K (512KB)
//   $080000-$08BFFF  Main RAM (48KB)
//   $08C000-$08C7FF  BG  tile RAM      (2KB)
//   $08C800-$08CFFF  FG  tile RAM      (2KB)
//   $08D000-$08D7FF  MG  tile RAM      (2KB)
//   $08D800-$08E7FF  Text tile RAM     (4KB)
//   $08E800-$08F7FF  Palette RAM       (4KB, xBGR_555)
//   $08F800-$08FFFF  Sprite RAM        (2KB)
//   $09D000-$09D7FF  GFX bank select
//   $0A0000-$0A000D  Seibu sound comm (COP-style)
//   $0C0000-$0C004F  Seibu CRTC registers
//   $0E0000-$0E0001  DIP switches
//   $0E0002-$0E0003  Player inputs
//   $0E0004-$0E0005  System inputs (coin/start/service)
//
// In questa fase il modulo implementa SOLO ROM + Main RAM + I/O read,
// mentre tutte le RAM video sono BRAM scrivibili dalla CPU ma non lette
// da nessun renderer (= POST della ROM, schermo nero).

module darius_dual68k_top
#(
	parameter [1:0] MAIN_CORE_IMPL    = 2'd1,
	parameter [1:0] SUB_CORE_IMPL     = 2'd1,
	// (parametri Darius residui — ignorati nel build Gundam)
	parameter       HOLD_SUB_IN_RESET = 1'b0,
	parameter       ENABLE_C00050_NOP = 1'b1,
	parameter       ENABLE_WATCHDOG   = 1'b1,
	parameter       ENABLE_PC080_CTRL = 1'b1,
	parameter       ENABLE_DC0000     = 1'b1,
	parameter       ENABLE_C00060     = 1'b1,
	parameter       ENABLE_C00020     = 1'b1,
	parameter       ENABLE_C00022     = 1'b1,
	parameter       ENABLE_C00024     = 1'b1,
	parameter       ENABLE_C00030     = 1'b1,
	parameter       ENABLE_C00032     = 1'b1,
	parameter       ENABLE_C00034     = 1'b1,
	parameter       ENABLE_D40000     = 1'b1,
	parameter       ENABLE_D40002     = 1'b1,
	parameter       ENABLE_D20000     = 1'b1,
	parameter       ENABLE_D20002     = 1'b1,
	parameter       ENABLE_C0000C     = 1'b1,
	parameter       ENABLE_C00010     = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_PORT = 1'b1,
	parameter       ENABLE_MAIN_PC060HA_COMM = 1'b1,
	parameter       ENABLE_MAIN_D00000 = 1'b1,
	parameter       ENABLE_MAIN_PALETTE = 1'b1,
	parameter       ENABLE_FG_RAM      = 1'b1,
	parameter       ENABLE_MAIN_CTRL  = 1'b1,
	parameter       ENABLE_MAIN_SHARED = 1'b1,
	parameter       ENABLE_MAIN_SPRITE = 1'b1,
	parameter       ENABLE_MAIN_IO    = 1'b1,
	parameter       ENABLE_MAIN_VIDEO = 1'b1,
	parameter       ENABLE_MAIN_PLAYER_IO = 1'b1,
	parameter       ENABLE_SUB_SHARED = 1'b1,
	parameter       ENABLE_SUB_SPRITE = 1'b1,
	parameter       ENABLE_SUB_PALETTE = 1'b1,
	parameter       ENABLE_SUB_IO     = 1'b1,
	parameter       ENABLE_VBLANK_IRQ = 1'b1
)
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	input  wire  [2:0] clk_sel,
	input  wire  [2:0] sub_clk_sel,
	input  wire  [1:0] z80_clk_sel,
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire [15:0] system_input,
	input  wire [15:0] dsw_input,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,
	input  wire [15:0] sub_rom_rdata,
	input  wire        sub_rom_ready,
	input  wire [9:0]  render_x,
	input  wire [8:0]  render_y,
	input  wire        vblank_in,    // VBLANK dal video_timing (per IRQ4)
	input  wire [31:0] tilerom_data,
	input  wire        tilerom_valid,
	output wire [23:0] main_rom_addr,
	output wire        main_rom_req,
	output wire [23:0] sub_rom_addr,
	output wire        sub_rom_req,
	// tilerom_* portati a 0 dal main top: l'arbiter Gundam pilota il bridge da GundamSD.sv
	output wire [23:0] tilerom_addr,
	output wire        tilerom_req,
	output wire  [2:0] tilerom_kind,
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	output wire [15:0] xscroll_l0,
	output wire [15:0] xscroll_l1,
	output wire [15:0] yscroll_l0,
	output wire [15:0] yscroll_l1,
	output wire [15:0] xscroll_mg,
	output wire [15:0] yscroll_mg,
	output wire [15:0] ctrl_l0,
	// Palette read port (per video pipeline)
	input  wire [10:0] pal_b_addr,
	output wire  [7:0] pal_b_r,
	output wire  [7:0] pal_b_g,
	output wire  [7:0] pal_b_b,
	// Text VRAM read port (per renderer): output indirizzo, ritorno dato
	input  wire [10:0] text_vram_addr,
	output wire [15:0] text_vram_data,
	// BG VRAM read port
	input  wire [10:0] bg_vram_addr,
	output wire [15:0] bg_vram_data,
	// MG VRAM read port
	input  wire [10:0] mg_vram_addr,
	output wire [15:0] mg_vram_data,
	// FG VRAM read port
	input  wire [10:0] fg_vram_addr,
	output wire [15:0] fg_vram_data,
	// Sprite RAM read port (per sprite scanner)
	input  wire  [9:0] spr_vram_addr,
	output wire [15:0] spr_vram_data,
	// gfx_bank_select (per MG, scritto da CPU a $9D000)
	output wire [15:0] gfx_bank,
	// Coin/start input HW (passa via Z80 → seibu_sound coin_r)
	input  wire  [7:0] coin_input,
	// OKI ADPCM ROM bridge ↔ jt6295
	output wire [17:0] oki_rom_addr,
	input  wire  [7:0] oki_rom_data,
	input  wire        oki_rom_ok,
	// Volumi OSD (Q4.4)
	input  wire  [5:0] fm_vol_q44,
	input  wire  [5:0] oki_vol_q44,
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r
);

// ─── Sub-CPU & tile-ROM non usati (1× 68k, no video renderer in questa fase) ──
assign sub_rom_addr      = 24'd0;
assign sub_rom_req       = 1'b0;
assign tilerom_addr = 24'd0;
assign tilerom_req  = 1'b0;
assign tilerom_kind = 3'd0;

// Scroll esposti al video stage (BG/FG/MG dal CRTC Seibu).
// Convenzione SD Gundam: scrollX += 128 nel dispatcher di disegno (lato GundamSD.sv).
assign xscroll_l0     = crtc_scroll_bg_x;
assign yscroll_l0     = crtc_scroll_bg_y;
assign xscroll_l1     = crtc_scroll_fg_x;
assign yscroll_l1     = crtc_scroll_fg_y;
assign xscroll_mg     = crtc_scroll_mg_x;
assign yscroll_mg     = crtc_scroll_mg_y;
// ctrl_l0 espone layer enable + flip:
//   [0]=BG, [1]=MG, [2]=FG, [3]=Text, [4]=Spr, [5]=flip, [6]=dyn_size
assign ctrl_l0        = {9'd0, crtc_dyn_size, crtc_flip_screen,
                          crtc_layer_en_spr, crtc_layer_en_text,
                          crtc_layer_en_fg, crtc_layer_en_mg, crtc_layer_en_bg};

// --- VBlank-synced pause (frame-aligned, Darius2 pattern) ---
// pause raw asincrono → paused_safe registrato che cambia SOLO al rising edge
// vblank. Sincronizza pause boundary su tutti i moduli (CPU cen, audio cen).
reg vblank_in_prev;
reg paused_safe_r;
always @(posedge clk) begin
	if (reset) begin
		vblank_in_prev <= 1'b0;
		paused_safe_r  <= 1'b0;
	end else begin
		vblank_in_prev <= vblank_in;
		if (vblank_in && !vblank_in_prev) paused_safe_r <= pause;
	end
end
wire paused_safe = paused_safe_r;

// ─── Audio Seibu reale: Z80 + YM2151 + OKI6295 ──────────────────────────────
GundamSD_audio_z80 u_audio (
	.clk(clk), .reset(reset),
	.pause(paused_safe),
	.clk_sel(z80_clk_sel),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.snd_cs(snd_cs),
	.snd_addr(snd_addr),
	.snd_wr(snd_wr),
	.snd_rd(snd_rd),
	.snd_wdata(snd_wdata),
	.snd_rdata(snd_rdata),
	.snd_nmi_n(1'b1),
	.snd_reset_in(1'b0),
	.coin_input(coin_input),
	.oki_rom_addr(oki_rom_addr),
	.oki_rom_data(oki_rom_data),
	.oki_rom_ok(oki_rom_ok),
	.fm_vol_q44(fm_vol_q44),
	.oki_vol_q44(oki_vol_q44),
	.audio_l(audio_l), .audio_r(audio_r)
);

// ─── 68000 main ──────────────────────────────────────────────────────────────
// Clock divider: 96MHz → 10MHz target (96/10 ≈ 9.6, num/den = 5/48 ⇒ ~10MHz)
// Per ora 8MHz (5/60) come Darius — riproponiamo i clk_sel del donor.
reg [6:0] clk_num;
reg [7:0] clk_den;
always @(*) case (clk_sel)
	3'd0: begin clk_num = 7'd5;  clk_den = 8'd60; end // 8 MHz
	3'd1: begin clk_num = 7'd5;  clk_den = 8'd40; end // 12 MHz
	3'd2: begin clk_num = 7'd5;  clk_den = 8'd48; end // 10 MHz (target reale Gundam)
	3'd3: begin clk_num = 7'd5;  clk_den = 8'd30; end // 16 MHz
	3'd4: begin clk_num = 7'd5;  clk_den = 8'd20; end // 24 MHz
	3'd5: begin clk_num = 7'd5;  clk_den = 8'd15; end // 32 MHz
	default: begin clk_num = 7'd5;  clk_den = 8'd48; end // 10 MHz default Gundam
endcase

wire [23:0] cpu_addr;
wire        cpu_asn;
wire        cpu_rnw;
wire [1:0]  cpu_dsn;
wire [15:0] cpu_dout;
wire [15:0] cpu_din;
wire        cpu_cs;
wire        cpu_busy;
wire        cpu_iack;

// VBLANK IRQ4 — MAME dcon.cpp: m_maincpu->set_vblank_int(irq4_line_hold)
// Rising edge di vblank → assert IRQ4 pending; IACK CPU → clear.
// IRQ level 4 → ipl_n = ~4 = 3'b011.
wire vblank_area = vblank_in;
reg  vblank_prev;
reg  main_irq4_pending;
always @(posedge clk) begin
	if (reset) begin
		vblank_prev       <= 1'b0;
		main_irq4_pending <= 1'b0;
	end else begin
		vblank_prev <= vblank_area;
		if (vblank_area && !vblank_prev) main_irq4_pending <= 1'b1;
		if (cpu_iack)                     main_irq4_pending <= 1'b0;
	end
end
wire [2:0] ipl_n = main_irq4_pending ? 3'b011 : 3'b111;

darius_cpu_node #(.CPU_ID(1'b0), .CORE_IMPL(MAIN_CORE_IMPL)) u_cpu (
	.clk(clk),
	.reset(reset),
	.soft_reset(1'b0),
	.halt_n(~paused_safe),
	.clk_num(clk_num),
	.clk_den(clk_den),
	.ipl_n(ipl_n),
	.bus_din(cpu_din),
	.bus_cs(cpu_cs),
	.bus_busy(cpu_busy),
	.dev_br(1'b0),
	.bus_addr(cpu_addr),
	.bus_asn(cpu_asn),
	.bus_rnw(cpu_rnw),
	.bus_dsn(cpu_dsn),
	.bus_dout(cpu_dout),
	.dbg_pc(),
	.dbg_fc(),
	.dbg_dtackn(),
	.dbg_fave(),
	.dbg_fworst(),
	.iack(cpu_iack)
);

// ─── Memory map (FSM TXN per BRAM read latency) ─────────────────────────────
// Wire BRAM
wire [15:0] ram_rdata, bg_rdata, fg_rdata, mg_rdata, txt_rdata, pal_rdata, spr_rdata;
wire        ram_we, bg_we, fg_we, mg_we, txt_we, pal_we, spr_we;
wire [10:0] map_vram_addr;   // 11-bit = 2Kw, copre tutte le VRAM (Text max 2048w)
wire [15:0] map_vram_wdata;
wire  [1:0] map_vram_be;
wire [14:0] map_ram_addr;
wire [15:0] map_ram_wdata;
wire  [1:0] map_ram_be;

// CRTC
wire        crtc_cs, crtc_wr, crtc_rd;
wire  [6:1] crtc_addr;
wire [15:0] crtc_rdata;
wire        crtc_layer_en_bg, crtc_layer_en_mg, crtc_layer_en_fg, crtc_layer_en_text, crtc_layer_en_spr;
wire [15:0] crtc_scroll_bg_x, crtc_scroll_bg_y;
wire [15:0] crtc_scroll_mg_x, crtc_scroll_mg_y;
wire [15:0] crtc_scroll_fg_x, crtc_scroll_fg_y;
wire        crtc_flip_screen, crtc_dyn_size;

// Sound comm bus: pilotato da Z80 audio reale (GundamSD_audio_z80).
wire        snd_cs, snd_wr, snd_rd;
wire  [3:1] snd_addr;
wire [15:0] snd_wdata;
wire [15:0] snd_rdata;

// Memory map module
GundamSD_maincpu_map u_map (
	.clk            (clk),
	.reset          (reset),
	.bus_addr       (cpu_addr),
	.bus_asn        (cpu_asn),
	.bus_rnw        (cpu_rnw),
	.bus_dsn        (cpu_dsn),
	.bus_wdata      (cpu_dout),
	.bus_rdata      (cpu_din),
	.bus_cs         (cpu_cs),
	.bus_busy       (cpu_busy),
	.p1_input       (p1_input),
	.p2_input       (p2_input),
	.system_input   (system_input),
	.dsw_input      (dsw_input),
	.main_rom_rdata (main_rom_rdata),
	.main_rom_ready (main_rom_ready),
	.main_rom_addr  (main_rom_addr),
	.main_rom_req   (main_rom_req),
	.ram_rdata      (ram_rdata),
	.ram_we         (ram_we),
	.ram_addr       (map_ram_addr),
	.ram_wdata      (map_ram_wdata),
	.ram_be         (map_ram_be),
	.bg_rdata       (bg_rdata),
	.bg_we          (bg_we),
	.mg_rdata       (mg_rdata),
	.mg_we          (mg_we),
	.fg_rdata       (fg_rdata),
	.fg_we          (fg_we),
	.txt_rdata      (txt_rdata),
	.txt_we         (txt_we),
	.pal_rdata      (pal_rdata),
	.pal_we         (pal_we),
	.spr_rdata      (spr_rdata),
	.spr_we         (spr_we),
	.vram_addr      (map_vram_addr),
	.vram_wdata     (map_vram_wdata),
	.vram_be        (map_vram_be),
	.crtc_cs        (crtc_cs),
	.crtc_wr        (crtc_wr),
	.crtc_rd        (crtc_rd),
	.crtc_addr      (crtc_addr),
	.crtc_rdata     (crtc_rdata),
	.gfx_bank       (gfx_bank),
	.snd_cs         (snd_cs),
	.snd_wr         (snd_wr),
	.snd_rd         (snd_rd),
	.snd_addr       (snd_addr),
	.snd_wdata      (snd_wdata),
	.snd_rdata      (snd_rdata)
);

// ─── BRAM istanze ────────────────────────────────────────────────────────────
GundamSD_ram_48k u_main_ram (
	.clk(clk), .addr(map_ram_addr), .din(map_ram_wdata), .dout(ram_rdata),
	.we(ram_we), .be(map_ram_be)
);

GundamSD_vram_dp #(.AW(11)) u_bg_ram (
	.clk(clk), .a_we(bg_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr), .a_din(map_vram_wdata), .a_dout(bg_rdata),
	.b_addr(bg_vram_addr), .b_dout(bg_vram_data)
);
// FG VRAM: bus_addr 0x8C800-0x8CFFF → bus_addr[11:1] = 0x400-0x7FF.
// Renderer FG legge BRAM[0..0x3FF]. XOR 0x400 lato CPU per allineare.
GundamSD_vram_dp #(.AW(11)) u_fg_ram (
	.clk(clk), .a_we(fg_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr ^ 11'h400), .a_din(map_vram_wdata), .a_dout(fg_rdata),
	.b_addr(fg_vram_addr), .b_dout(fg_vram_data)
);
GundamSD_vram_dp #(.AW(11)) u_mg_ram (
	.clk(clk), .a_we(mg_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr), .a_din(map_vram_wdata), .a_dout(mg_rdata),
	.b_addr(mg_vram_addr), .b_dout(mg_vram_data)
);
// Text VRAM: bus_addr 0x8D800-0x8E7FF → bit11 alto su prima metà,
// stesso pattern di FG e Palette. XOR 0x400 lato CPU per allineare
// BRAM[N] = MAME text_vram[N] (renderer parte da addr 0).
GundamSD_vram_dp #(.AW(11)) u_txt_ram (
	.clk(clk), .a_we(txt_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr ^ 11'h400), .a_din(map_vram_wdata), .a_dout(txt_rdata),
	.b_addr(text_vram_addr), .b_dout(text_vram_data)
);
// Palette: CPU bus_addr 0x8E800..0x8F7FF (4KB = 2048 word) → bus_addr[11:1] vale
// 0x400 a 0x8E800, 0x000 a 0x8F000, 0x3FF a 0x8F7FE. Quindi MAME palette[N] sta
// in vram_addr = (N + 0x400) & 0x7FF. Per allineare BRAM[N] = MAME palette[N]
// applichiamo XOR 0x400 SOLO al lato CPU (a_addr). Il renderer passa pen_index
// MAME nativo (BG=0x400+, MG=0x500+, ecc) e la BRAM è già allineata.
GundamSD_palette u_pal (
	.clk(clk),
	.a_we(pal_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr ^ 11'h400),
	.a_din(map_vram_wdata), .a_dout(pal_rdata),
	.b_addr(pal_b_addr),
	.b_r(pal_b_r), .b_g(pal_b_g), .b_b(pal_b_b)
);
// Sprite RAM CPU-side (write/read) — il main 68K vede questo
GundamSD_vram_dp #(.AW(10)) u_spr_ram_cpu (
	.clk(clk), .a_we(spr_we), .a_be(map_vram_be),
	.a_addr(map_vram_addr[9:0]), .a_din(map_vram_wdata), .a_dout(spr_rdata),
	.b_addr(spr_copy_src_addr), .b_dout(spr_copy_src_data)
);

// Sprite RAM SHADOW — letto dallo sprite scanner durante render.
// Copy CPU→shadow al rising edge di vblank (replica DMA chip Seibu SEI0211).
//
// FSM con counter unico spr_copy_cnt:
//   cnt=0..1023:   src_addr = cnt        → setta b_addr al ciclo corrente
//   cnt=1..1024:   src_data = mem[cnt-1] arriva (porta B latency 1)
//   cnt=1..1024:   write shadow[cnt-1] = src_data
//   cnt>=1025:     done
//
// Tutto in 1 always block, no pipeline confusa. Counter unico.
reg [10:0] spr_copy_cnt = 11'd1100;   // idle: > 1024 = done
reg        vblank_d = 1'b0;
wire       spr_copy_active = (spr_copy_cnt < 11'd1025);

wire [9:0]  spr_copy_src_addr = spr_copy_cnt[9:0];   // 0..1023 a regime
wire [15:0] spr_copy_src_data;                       // = u_spr_ram_cpu.b_dout (latency 1)

// dst_addr = cnt - 1 (1 ciclo dopo addr in input alla BRAM)
wire [9:0] spr_copy_dst_addr = spr_copy_cnt[9:0] - 10'd1;
wire       spr_copy_we = spr_copy_active && (spr_copy_cnt >= 11'd1) && (spr_copy_cnt <= 11'd1024);

always @(posedge clk) begin
	vblank_d <= vblank_in;
	if (reset) begin
		spr_copy_cnt <= 11'd1100;
	end else begin
		if (vblank_in && !vblank_d) begin
			spr_copy_cnt <= 11'd0;
		end else if (spr_copy_active) begin
			spr_copy_cnt <= spr_copy_cnt + 11'd1;
		end
	end
end

// Sostituisco port B address di u_spr_ram_cpu con spr_copy_src_addr già fatto
// (vedi assign sopra)

// Shadow BRAM — porta A: write da copy FSM, porta B: read da sprite scanner
(* ramstyle = "M10K,no_rw_check" *) reg [15:0] spr_ram_shadow [0:1023];
reg [15:0] spr_shadow_b_q;
// synthesis translate_off
integer shadow_init_i;
initial begin
	for (shadow_init_i = 0; shadow_init_i < 1024; shadow_init_i = shadow_init_i + 1)
		spr_ram_shadow[shadow_init_i] = 16'h0000;
end
// synthesis translate_on
always @(posedge clk) begin
	if (spr_copy_we) spr_ram_shadow[spr_copy_dst_addr] <= spr_copy_src_data;
	spr_shadow_b_q <= spr_ram_shadow[spr_vram_addr];
end
assign spr_vram_data = spr_shadow_b_q;

// ─── Seibu CRTC ──────────────────────────────────────────────────────────────
GundamSD_seibu_crtc u_crtc (
	.clk(clk), .reset(reset),
	.cs(crtc_cs), .wr(crtc_wr), .rd(crtc_rd),
	.addr(crtc_addr), .dsn(cpu_dsn), .wdata(cpu_dout),
	.rdata(crtc_rdata),
	.layer_en_bg(crtc_layer_en_bg), .layer_en_mg(crtc_layer_en_mg),
	.layer_en_fg(crtc_layer_en_fg), .layer_en_text(crtc_layer_en_text),
	.layer_en_spr(crtc_layer_en_spr),
	.scroll_bg_x(crtc_scroll_bg_x), .scroll_bg_y(crtc_scroll_bg_y),
	.scroll_mg_x(crtc_scroll_mg_x), .scroll_mg_y(crtc_scroll_mg_y),
	.scroll_fg_x(crtc_scroll_fg_x), .scroll_fg_y(crtc_scroll_fg_y),
	.flip_screen(crtc_flip_screen), .dyn_layer_size(crtc_dyn_size)
);

endmodule


// ─── BRAM helper: 48KB main RAM (24Kw × 16, byte-enable) ─────────────────────
// Pattern Darius2: initial begin azzera BRAM al power-on per evitare garbage
// post-switch core (stato lasciato dal core precedente nelle M10K fisiche).
module GundamSD_ram_48k (
	input  wire        clk,
	input  wire [14:0] addr,
	input  wire [15:0] din,
	output reg  [15:0] dout,
	input  wire        we,
	input  wire  [1:0] be     // be[1]=high byte, be[0]=low byte
);
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_hi [0:24575];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_lo [0:24575];
	// synthesis translate_off
	integer i;
	initial begin
		for (i = 0; i < 24576; i = i + 1) begin
			mem_hi[i] = 8'h00;
			mem_lo[i] = 8'h00;
		end
	end
	// synthesis translate_on
	always @(posedge clk) begin
		if (we & be[1]) mem_hi[addr] <= din[15:8];
		if (we & be[0]) mem_lo[addr] <= din[7:0];
		dout <= {mem_hi[addr], mem_lo[addr]};
	end
endmodule


// ─── BRAM helper: video word RAM true dual-port (CPU + renderer) ─────────────
module GundamSD_vram_dp #(parameter AW = 11) (
	input  wire           clk,
	// Port A (CPU): RW byte-enabled
	input  wire           a_we,
	input  wire     [1:0] a_be,
	input  wire [AW-1:0]  a_addr,
	input  wire    [15:0] a_din,
	output reg     [15:0] a_dout,
	// Port B (renderer): RO
	input  wire [AW-1:0]  b_addr,
	output reg     [15:0] b_dout
);
	localparam DEPTH = 1 << AW;
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_hi [0:DEPTH-1];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_lo [0:DEPTH-1];
	// synthesis translate_off
	integer i;
	initial begin
		for (i = 0; i < DEPTH; i = i + 1) begin
			mem_hi[i] = 8'h00;
			mem_lo[i] = 8'h00;
		end
	end
	// synthesis translate_on
	always @(posedge clk) begin
		// Port A
		if (a_we & a_be[1]) mem_hi[a_addr] <= a_din[15:8];
		if (a_we & a_be[0]) mem_lo[a_addr] <= a_din[7:0];
		a_dout <= {mem_hi[a_addr], mem_lo[a_addr]};
		// Port B
		b_dout <= {mem_hi[b_addr], mem_lo[b_addr]};
	end
endmodule

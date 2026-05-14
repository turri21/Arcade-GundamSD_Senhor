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

/*  Audio subsystem Seibu (Z80 + YM2151 + OKI6295)

    Spec da MAME (reference/mame_seibu/seibusound.cpp + dcon.cpp):
      - Z80A @ 14.31818 MHz / 4 = 3.579545 MHz
      - YM2151 (jt51) @ 14.31818 / 4 = 3.579545 MHz
      - OKI M6295 (jt6295) @ 20 MHz / 16 = 1.25 MHz, PIN7=LOW

    Z80 memory map (seibu_sound_map):
      0x0000-0x1FFF  ROM fissa 8KB
      0x2000-0x27FF  RAM 2KB
      0x4000         pending_w (sound→main pending)
      0x4001         irq_clear_w (RST18 EOI)
      0x4002         rst10_ack_w (RST10 EOI)
      0x4003         rst18_ack_w (RST18 EOI)
      0x4007         bank_w (Z80 ROM bank, 1 bit)
      0x4008-0x4009  YM2151 r/w (a0=addr[0])
      0x4010-0x4011  soundlatch_r (main→sub latch byte 0/1)
      0x4012         main_data_pending_r (main2sub pending flag)
      0x4013         coin_r (legge coin/start input HW)
      0x4018-0x4019  main_data_w (sub→main latch byte 0/1)
      0x401B         coin_w (counter, ignorato in MiSTer)
      0x6000         OKI M6295 r/w
      0x8000-0xFFFF  ROM bank 32KB (in SD Gundam ROM=32KB lineari, no banking)

    Main↔sub comm @ 0xA0000-0xA000D (mappato in main_top.sv):
      offset 0/1: main_w → m_main2sub[0/1]
      offset 2/3: main_r → m_sub2main[0/1] (BUT offset 4 main_w → assert RST18)
      offset 4: main_w → assert RST18 IRQ to Z80
      offset 5: main_r → m_main2sub_pending (bit0)
      offset 6: main_w → set pending flags (mirror)

    IRQ Z80 (IM0):
      RST10 (vector 0xD7) ← YM2151 IRQ (fm_irqhandler)
      RST18 (vector 0xDF) ← main RST18_ASSERT
      Priorità: RST18 > RST10 (im0_vector_cb)

    Coin path:
      HW button → coin_input → coin_r (Z80 read) → Z80 elabora →
      sub2main soundlatch → main legge 0xA0004 → coin_credit incrementato
*/

module GundamSD_audio_z80 (
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	input  wire  [1:0] clk_sel,    // OSD audio clock select (legacy, ignored)

	// ROM download (ioctl)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,

	// Sound comm bus dal main 68k (mappato a 0xA0000-0xA000D)
	input  wire        snd_cs,         // is_snd region active
	input  wire  [3:1] snd_addr,       // bus_addr[3:1] = offset/2 (0..6)
	input  wire        snd_wr,         // ~bus_rnw & active
	input  wire        snd_rd,         // bus_rnw & active (per pending check)
	input  wire [15:0] snd_wdata,
	output wire [15:0] snd_rdata,
	input  wire        snd_nmi_n,      // legacy (unused, Seibu non usa NMI)
	input  wire        snd_reset_in,   // legacy

	// HW input coin (lette dal Z80 a 0x4013)
	input  wire  [7:0] coin_input,     // bit0=COIN1, bit1=COIN2 (ACTIVE_HIGH)

	// OKI ADPCM ROM bridge (256KB SDRAM, port 3)
	output wire [17:0] oki_rom_addr,
	input  wire  [7:0] oki_rom_data,
	input  wire        oki_rom_ok,

	// Volumi OSD (Q4.4: 16 = 100%, 32 = 200%, 0 = mute)
	input  wire  [5:0] fm_vol_q44,
	input  wire  [5:0] oki_vol_q44,

	// Audio output stereo 16-bit signed
	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r
);

	// ─── Clock enable: clk_sys (96 MHz) → Z80/YM 3.579545 MHz, OKI 1.25 MHz ──
	// Z80/YM: 96/3.579545 = 26.82 → divisore 27 (3.555 MHz, accettabile)
	// OKI: 96/1.25 = 76.8 → divisore 77 (1.246 MHz)
	// Z80/YM cen: pulse di 1 ciclo ogni 27 cicli clk → 3.555 MHz
	// jt51 vuole cen_p1 PULSE (1 ciclo ogni 2x cen) → metà della velocità di cen.
	// Implementazione: alternato tra due cen consecutivi (toggle interno).
	reg [4:0] cen_z80_cnt;
	reg       cen_z80;
	reg       cen_ym_p1;
	reg       cen_alt;         // toggle ogni cen_z80
	always @(posedge clk) begin
		if (reset) begin
			cen_z80_cnt <= 5'd0;
			cen_z80     <= 1'b0;
			cen_ym_p1   <= 1'b0;
			cen_alt     <= 1'b0;
		end else begin
			if (cen_z80_cnt == 5'd26) begin
				cen_z80_cnt <= 5'd0;
				cen_z80     <= 1'b1;
				cen_alt     <= ~cen_alt;
				cen_ym_p1   <= cen_alt;        // pulse 1 cen ogni 2 cen
			end else begin
				cen_z80_cnt <= cen_z80_cnt + 5'd1;
				cen_z80     <= 1'b0;
				cen_ym_p1   <= 1'b0;
			end
		end
	end

	reg [6:0] cen_oki_cnt;
	reg       cen_oki;
	always @(posedge clk) begin
		if (reset) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b0;
		end else if (cen_oki_cnt == 7'd76) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b1;
		end else begin
			cen_oki_cnt <= cen_oki_cnt + 7'd1;
			cen_oki     <= 1'b0;
		end
	end

	// Pause gating (pattern Darius2: cen & ~pause)
	wire cen_z80_g   = cen_z80   & ~pause;
	wire cen_ym_p1_g = cen_ym_p1 & ~pause;
	wire cen_oki_g   = cen_oki   & ~pause;

	// ─── Z80 signals ─────────────────────────────────────────────────────────
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_din;
	wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_m1_n;
	wire        z80_int_n;
	wire        z80_busak_n, z80_halt_n;

	// CS decoder forward declarations (rom_lo/rom_hi servono nel ROM block sotto)
	wire rom_lo_cs   = ~z80_mreq_n && (z80_addr[15:13] == 3'b000);   // 0x0000-0x1FFF
	wire rom_hi_cs   = ~z80_mreq_n && (z80_addr[15] == 1'b1);        // 0x8000-0xFFFF
	wire ram_cs      = ~z80_mreq_n && (z80_addr[15:11] == 5'b00100); // 0x2000-0x27FF
	wire reg_cs      = ~z80_mreq_n && (z80_addr[15:5] == 11'h200);   // 0x4000-0x401F
	wire oki_cs      = ~z80_mreq_n && (z80_addr[15:12] == 4'h6);     // 0x6000-0x6FFF

	// ─── ROM Z80 64KB raw: 2 BRAM split byte-low / byte-high (32K word) ──────
	// MRA layout: audiocpu @ ioctl_addr 0x4E0000-0x4EFFFF (64KB raw, byte-stream).
	// File 911-a05.010 fa 64KB. WIDE=1 ioctl: 2 byte per word (LSB=primo byte).
	// Split in 2 BRAM 8-bit × 32Kw: rom_lo[wordaddr]=byte_pari, rom_hi[wordaddr]=byte_dispari.
	//
	// MAME audiocpu region layout (sdgndmps):
	//   ROM_LOAD     "911-a05.010" 0x00000, 0x8000   → primi 32KB del file → region 0x00000-0x07FFF
	//   ROM_CONTINUE                0x10000, 0x8000  → secondi 32KB del file → region 0x10000-0x17FFF
	//   ROM_COPY     "audiocpu"     0x00000 → 0x18000, 0x8000 → region 0x18000-0x1FFFF (alias bank1)
	//
	// Seibu rom_bank con length>0x10000:
	//   bank 0 → region[0x10000-0x17FFF] = secondi 32KB del file
	//   bank 1 → region[0x18000-0x1FFFF] = primi 32KB del file (alias)
	//
	// Z80 access map effettiva per noi:
	//   0x0000-0x1FFF (rom_lo_cs): primi 8KB della ROM = file[0x0000-0x1FFF]
	//   0x8000-0xFFFF (rom_hi_cs banked):
	//     bank=0 → file[0x8000-0xFFFF]   (secondi 32KB)
	//     bank=1 → file[0x0000-0x7FFF]   (primi 32KB alias)
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_lo [0:32767];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_hi [0:32767];
	reg [7:0] z80_rom_lo_q, z80_rom_hi_q;

	wire z80_rom_dl_wr =
		ioctl_download && ioctl_wr && (ioctl_addr >= 27'h4E0000) && (ioctl_addr < 27'h4F0000);
	wire [14:0] z80_rom_dl_word = ioctl_addr[15:1];   // word index 0..32767

	// Bank register (1 bit, scritto da Z80 a 0x4007)
	reg rom_bank;

	// Effective ROM byte address (16-bit lineare nel file 64KB):
	//   rom_lo_cs (0x0000-0x1FFF):       z80_addr[15:0]
	//   rom_hi_cs (0x8000-0xFFFF):
	//     bank=0 → z80_addr[15:0]                  (file[0x8000-0xFFFF])
	//     bank=1 → {1'b0, z80_addr[14:0]}          (file[0x0000-0x7FFF])
	wire [15:0] z80_rom_byte_addr =
		rom_lo_cs              ? z80_addr :
		(rom_hi_cs & ~rom_bank) ? z80_addr :
		(rom_hi_cs &  rom_bank) ? {1'b0, z80_addr[14:0]} :
		                          z80_addr;

	reg z80_addr_lsb_d;
	always @(posedge clk) begin
		if (z80_rom_dl_wr) begin
			z80_rom_lo[z80_rom_dl_word] <= ioctl_dout[7:0];
			z80_rom_hi[z80_rom_dl_word] <= ioctl_dout[15:8];
		end
		// word index = byte_addr[15:1], byte select = byte_addr[0]
		z80_rom_lo_q   <= z80_rom_lo[z80_rom_byte_addr[15:1]];
		z80_rom_hi_q   <= z80_rom_hi[z80_rom_byte_addr[15:1]];
		z80_addr_lsb_d <= z80_rom_byte_addr[0];
	end

	wire [7:0] z80_rom_q = z80_addr_lsb_d ? z80_rom_hi_q : z80_rom_lo_q;

	// ─── RAM Z80 2KB ─────────────────────────────────────────────────────────
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_ram [0:2047];
	reg [7:0] z80_ram_q;

	// synthesis translate_off
	integer z80_ram_init_i;
	initial begin
		for (z80_ram_init_i = 0; z80_ram_init_i < 2048; z80_ram_init_i = z80_ram_init_i + 1)
			z80_ram[z80_ram_init_i] = 8'h00;
	end
	// synthesis translate_on

	always @(posedge clk) begin
		if (ram_cs && !z80_wr_n) z80_ram[z80_addr[10:0]] <= z80_dout;
		z80_ram_q <= z80_ram[z80_addr[10:0]];
	end

	// ─── Sub-region decoder dentro reg_cs (z80_addr[4:0] = offset 0..31) ─────
	wire is_pending_w   = reg_cs && (z80_addr[4:0] == 5'h00) && !z80_wr_n;
	wire is_irq_clear   = reg_cs && (z80_addr[4:0] == 5'h01) && !z80_wr_n;
	wire is_rst10_ack   = reg_cs && (z80_addr[4:0] == 5'h02) && !z80_wr_n;
	wire is_rst18_ack   = reg_cs && (z80_addr[4:0] == 5'h03) && !z80_wr_n;
	wire is_bank_w      = reg_cs && (z80_addr[4:0] == 5'h07) && !z80_wr_n;
	wire is_ym_access   = reg_cs && (z80_addr[4:1] == 4'h4);                      // 0x4008-0x4009
	wire is_ym_w        = is_ym_access && !z80_wr_n;
	wire is_ym_r        = is_ym_access && !z80_rd_n;
	wire is_latch_lo_r  = reg_cs && (z80_addr[4:0] == 5'h10) && !z80_rd_n;
	wire is_latch_hi_r  = reg_cs && (z80_addr[4:0] == 5'h11) && !z80_rd_n;
	wire is_pending_r   = reg_cs && (z80_addr[4:0] == 5'h12) && !z80_rd_n;
	wire is_coin_r      = reg_cs && (z80_addr[4:0] == 5'h13) && !z80_rd_n;
	wire is_data_lo_w   = reg_cs && (z80_addr[4:0] == 5'h18) && !z80_wr_n;
	wire is_data_hi_w   = reg_cs && (z80_addr[4:0] == 5'h19) && !z80_wr_n;
	wire is_coin_w      = reg_cs && (z80_addr[4:0] == 5'h1B) && !z80_wr_n;

	// ─── ROM bank register (Z80 0x4007: bit0 → bank 0/1) ─────────────────────
	// MAME seibu_sound_device::bank_w: m_rom_bank->set_entry(BIT(data,0))
	always @(posedge clk) begin
		if (reset)
			rom_bank <= 1'b0;
		else if (cen_z80 && is_bank_w)
			rom_bank <= z80_dout[0];
	end

	// ─── Soundlatch main↔sub state ───────────────────────────────────────────
	// 2-byte main2sub + 2-byte sub2main + flags pending
	reg [7:0] main2sub [0:1];
	reg [7:0] sub2main [0:1];
	reg       main2sub_pending;
	reg       sub2main_pending;

	// ─── IRQ controller (IM0 vector RST10/RST18) ─────────────────────────────
	// Stato: rst10_irq, rst10_service, rst18_irq, rst18_service
	// IRQ assertion logic:
	//   ASSERT: rst10_irq=1 (FM IRQ) o rst18_irq=1 (main wakeup)
	//   CLEAR: rst10_service=1 (durante service) o EOI restoraservice=0
	reg rst10_irq, rst10_service;
	reg rst18_irq, rst18_service;
	wire ym_irq_n;
	wire ym_irq = ~ym_irq_n;
	reg  ym_irq_d;

	// IM0 vector inject: durante m1+iorq (interrupt acknowledge) il device
	// fornisce 0xDF (RST18) o 0xD7 (RST10). RST18 ha priorità.
	// Il vector deve essere LATCHED all'inizio dell'IACK e tenuto stabile
	// per tutta la durata dell'IACK (può durare più cicli clk). Se calcolato
	// combinatoriale, quando rst18_irq viene cleared il vector torna a 00
	// e Z80 fetcha 00 invece del vector corretto. Bug verificato in sim.
	wire iack_active = ~z80_m1_n && ~z80_iorq_n;
	reg  iack_active_d;
	reg  [7:0] iack_vector_latched;
	wire [7:0] iack_vector_now =
	    (rst18_irq && !rst18_service) ? 8'hDF :
	    (rst10_irq && !rst10_service) ? 8'hD7 :
	                                    8'h00;
	// Latch al rising edge di iack_active
	always @(posedge clk) begin
		if (reset) begin
			iack_active_d       <= 1'b0;
			iack_vector_latched <= 8'h00;
		end else begin
			iack_active_d <= iack_active;
			if (iack_active && !iack_active_d) begin
				iack_vector_latched <= iack_vector_now;
			end
		end
	end
	wire [7:0] iack_vector = iack_active_d ? iack_vector_latched : iack_vector_now;

	// IRQ line al Z80: ASSERT se RST10 pending (e non in service) OR RST18 pending
	wire irq_active = (rst10_irq && !rst10_service) || (rst18_irq && !rst18_service);
	assign z80_int_n = ~irq_active;

	always @(posedge clk) begin
		if (reset) begin
			rst10_irq     <= 1'b0;
			rst10_service <= 1'b0;
			rst18_irq     <= 1'b0;
			rst18_service <= 1'b0;
			ym_irq_d      <= 1'b0;
		end else begin
			ym_irq_d <= ym_irq;
			// YM IRQ rising/falling → RST10 assert/clear
			if (ym_irq && !ym_irq_d)        rst10_irq <= 1'b1;
			else if (!ym_irq && ym_irq_d)   rst10_irq <= 1'b0;

			// Main writes to 0xA0008 (MAME offset 4) → assert RST18
			// snd_addr = bus_addr[3:1], 0xA0008 → bit[3:1]=100 = 4
			if (snd_cs && snd_wr && snd_addr == 3'd4)
				rst18_irq <= 1'b1;

			// Z80 acknowledges IRQ: FALLING edge di iack_active (= fine IACK)
			// Solo allora clear rst*_irq e set service. Durante IACK il vector
			// rimane latched (vedi sopra) e il Z80 lo fetcha correttamente.
			if (iack_active_d && !iack_active) begin
				if (iack_vector_latched == 8'hDF) begin
					rst18_service <= 1'b1;
					rst18_irq     <= 1'b0;
				end else if (iack_vector_latched == 8'hD7) begin
					rst10_service <= 1'b1;
				end
			end

			// Z80 EOI writes
			if (cen_z80) begin
				if (is_irq_clear)  rst18_service <= 1'b0;
				if (is_rst10_ack)  rst10_service <= 1'b0;
				if (is_rst18_ack)  rst18_service <= 1'b0;
			end
		end
	end

	// ─── Soundlatch main_w/r logic ──────────────────────────────────────────
	// snd_addr = bus_addr[3:1] = offset/2 (0=word 0, 1=word 1, 2=word 2, 3=word 3, 4=word 4, 5=word 5, 6=word 6)
	// MAME usa byte access (umask16 0x00ff = byte basso). Mappa offset MAME → snd_addr:
	//   offset 0 (0xA0000) → snd_addr 0
	//   offset 1 (0xA0002) → snd_addr 1
	//   offset 2 (0xA0004) → snd_addr 2
	//   offset 3 (0xA0006) → snd_addr 3
	//   offset 5 (0xA000A) → snd_addr 5
	//   offset 6 (0xA000C) → snd_addr 6
	always @(posedge clk) begin
		if (reset) begin
			main2sub[0]      <= 8'd0;
			main2sub[1]      <= 8'd0;
			sub2main[0]      <= 8'd0;
			sub2main[1]      <= 8'd0;
			main2sub_pending <= 1'b0;
			sub2main_pending <= 1'b0;
		end else begin
			// Main writes (MAME seibu_sound_device::main_w):
			//   case 0/1: m_main2sub[offset] = data
			//   case 4:   update_irq_lines(RST18_ASSERT) — gestito sopra
			//   case 2/6: pending flags (sub2main=0, main2sub=1)
			if (snd_cs && snd_wr) begin
				case (snd_addr)
					3'd0: main2sub[0] <= snd_wdata[7:0];
					3'd1: main2sub[1] <= snd_wdata[7:0];
					3'd2, 3'd6: begin                        // MAME case 2/6
						sub2main_pending <= 1'b0;
						main2sub_pending <= 1'b1;
					end
					default: ;
				endcase
			end
			// Z80 reads soundlatch (→ MAME implicit: nessun side effect)
			// Z80 writes sub2main
			if (cen_z80) begin
				if (is_data_lo_w) sub2main[0] <= z80_dout;
				if (is_data_hi_w) sub2main[1] <= z80_dout;
				if (is_pending_w) begin
					main2sub_pending <= 1'b0;
					sub2main_pending <= 1'b1;
				end
			end
		end
	end

	// snd_rdata: main legge 0xA0004 (offset 2), 0xA0006 (offset 3), 0xA000A (offset 5).
	// MAME sdgndmps_sound_comms_r override (dcon.cpp:288): offset 5 hardcoded 1.
	// Routine 68k @ 0x134C: se bit0==0 → main NON manda comandi sound (skip).
	// offset 2/3 = sub2main bytes (Z80 → main), offset 5 = pending flag.
	wire [7:0] main_r_data =
		(snd_addr == 3'd2) ? sub2main[0] :
		(snd_addr == 3'd3) ? sub2main[1] :
		(snd_addr == 3'd5) ? 8'h01 :        // sdgndmps override → bit0=1 hardcoded
		                      8'hFF;
	assign snd_rdata = {8'h00, main_r_data};

	// ─── YM2151 (jt51) stereo ─────────────────────────────────────────────────
	wire [7:0] ym_dout;
	wire signed [15:0] ym_xleft, ym_xright;
	jt51 u_jt51 (
		.rst       (reset),
		.clk       (clk),
		.cen       (cen_z80_g),
		.cen_p1    (cen_ym_p1_g),
		.cs_n      (~is_ym_access),
		.wr_n      (z80_wr_n),
		.a0        (z80_addr[0]),
		.din       (z80_dout),
		.dout      (ym_dout),
		.ct1       (),
		.ct2       (),
		.irq_n     (ym_irq_n),
		.sample    (),
		.left      (),
		.right     (),
		.xleft     (ym_xleft),
		.xright    (ym_xright)
	);

	// ─── OKI M6295 (jt6295) ──────────────────────────────────────────────────
	// rom_addr/rom_data/rom_ok arrivano dai port modulo (collegati a SDRAM port 3)
	wire [7:0] oki_dout;
	wire signed [13:0] oki_sound;
	wire        oki_sample;

	jt6295 #(.INTERPOL(0)) u_jt6295 (
		.rst       (reset),
		.clk       (clk),
		.cen       (cen_oki_g),
		.ss        (1'b0),                // PIN7 = LOW (sample rate base)
		.wrn       (~(oki_cs & ~z80_wr_n)),
		.din       (z80_dout),
		.dout      (oki_dout),
		.rom_addr  (oki_rom_addr),
		.rom_data  (oki_rom_data),
		.rom_ok    (oki_rom_ok),
		.sound     (oki_sound),
		.sample    (oki_sample)
	);

	// ─── Z80 din mux ─────────────────────────────────────────────────────────
	always @(*) begin
		if (iack_active)         z80_din = iack_vector;
		else if (rom_lo_cs)      z80_din = z80_rom_q;
		else if (rom_hi_cs)      z80_din = z80_rom_q;       // SD Gundam ROM lineare
		else if (ram_cs)         z80_din = z80_ram_q;
		else if (is_ym_r)        z80_din = ym_dout;
		else if (is_latch_lo_r)  z80_din = main2sub[0];
		else if (is_latch_hi_r)  z80_din = main2sub[1];
		else if (is_pending_r)   z80_din = {7'd0, main2sub_pending};
		else if (is_coin_r)      z80_din = coin_input;
		else if (oki_cs)         z80_din = oki_dout;
		else                     z80_din = 8'hFF;
	end

	// ─── T80s Z80 core ───────────────────────────────────────────────────────
	wire t80_halt_n_g  = ~pause;
	wire t80_busrq_n   = 1'b1;
	wire t80_wait_n    = 1'b1;
	wire t80_nmi_n     = 1'b1;
	wire t80_reset_n   = ~reset & ~snd_reset_in;

	T80s u_z80 (
		.RESET_n (t80_reset_n),
		.CLK     (clk),
		.CEN     (cen_z80 & t80_halt_n_g),
		.WAIT_n  (t80_wait_n),
		.INT_n   (z80_int_n),
		.NMI_n   (t80_nmi_n),
		.BUSRQ_n (t80_busrq_n),
		.M1_n    (z80_m1_n),
		.MREQ_n  (z80_mreq_n),
		.IORQ_n  (z80_iorq_n),
		.RD_n    (z80_rd_n),
		.WR_n    (z80_wr_n),
		.RFSH_n  (),
		.HALT_n  (z80_halt_n),
		.BUSAK_n (z80_busak_n),
		.OUT0    (1'b0),
		.A       (z80_addr),
		.DI      (z80_din),
		.DO      (z80_dout),
		.REG     ()
	);

	// ─── Mixer audio: YM stereo + OKI mono → AUDIO_L/R ──────────────────────
	// Volumi OSD Q4.4 (16 = 100%). Mul a signed 23-bit poi >>4 per riportare.
	wire signed [22:0] ym_l_v  = $signed(ym_xleft)  * $signed({1'b0, fm_vol_q44});
	wire signed [22:0] ym_r_v  = $signed(ym_xright) * $signed({1'b0, fm_vol_q44});
	wire signed [22:0] oki_v   = $signed({oki_sound, 2'b00}) * $signed({1'b0, oki_vol_q44});
	wire signed [18:0] ym_l_s  = ym_l_v[22:4];
	wire signed [18:0] ym_r_s  = ym_r_v[22:4];
	wire signed [18:0] oki_s   = oki_v[22:4];
	wire signed [19:0] mix_l = {ym_l_s[18], ym_l_s} + {oki_s[18], oki_s};
	wire signed [19:0] mix_r = {ym_r_s[18], ym_r_s} + {oki_s[18], oki_s};

	always @(posedge clk) begin
		if (reset) begin
			audio_l <= 16'sd0;
			audio_r <= 16'sd0;
		end else begin
			// Saturate a 16-bit
			audio_l <= (mix_l > 20'sd32767)   ? 16'sh7FFF :
			           (mix_l < -20'sd32767) ? 16'sh8000 :
			                                    mix_l[15:0];
			audio_r <= (mix_r > 20'sd32767)   ? 16'sh7FFF :
			           (mix_r < -20'sd32767) ? 16'sh8000 :
			                                    mix_r[15:0];
		end
	end

endmodule

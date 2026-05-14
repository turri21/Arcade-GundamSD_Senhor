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

/*  Video timing single-screen Seibu D-Con.

    SD Gundam Psycho Salamander gira su Seibu D-Con (PB91008), stessa famiglia
    di Blood Bros (1990). PCB measurement Blood Bros: VSync 59.4094 Hz,
    HSync 15.6246 kHz, master XTAL 20 MHz.

    Pixel clock dedotto: 20MHz / 4? non torna con HVisible=320 di SD Gundam
    (HTotal sarebbe < 320). Il pixel clock effettivo per matchare HSync
    15.625 kHz con HTotal=384 (320 attivi + 64 blank ≈ 80% duty) è:
        pix_clk = HTotal × HSync = 384 × 15625 = 6.0 MHz
    Frame rate: 6e6 / (384 × 263) = 59.40 Hz ✓ (PCB target 59.4094)

    Active area da MAME (sdgndmps_map): visarea 0..40*8-1, 2*8..30*8-1
    quindi 320×224, V offset = 16 (top blank).

    Modalità selezionabili da OSD:
      mode_60hz=0 : Original 59.40 Hz (VTotal=263)
      mode_60hz=1 : 60.10 Hz          (VTotal=260) — più liscio per LCD 60Hz
*/

module GundamSD_video_timing
(
	input  wire        clk,            // 96 MHz core
	input  wire        reset,
	input  wire        mode_60hz,      // 0=59.4Hz, 1=60.1Hz
	output reg         ce_pix,         // pixel clock enable (clk/16 → 6 MHz)
	output reg [9:0]   hpos,           // 0..HTotal-1
	output reg [9:0]   vpos,           // 0..VTotal-1
	output wire [9:0]  active_x,       // 0..319 durante area attiva
	output wire [8:0]  active_y,       // 0..223 durante area attiva
	output wire        hblank,
	output wire        vblank,
	output wire        hsync,
	output wire        vsync,
	output wire        de              // active display enable
);

	// ── Pixel clock enable: 96 MHz / 16 = 6 MHz ──────────────────────────────
	reg [3:0] cediv;
	always @(posedge clk) begin
		if (reset) begin
			cediv  <= 4'd0;
			ce_pix <= 1'b0;
		end else begin
			cediv  <= cediv + 4'd1;
			ce_pix <= (cediv == 4'd0);
		end
	end

	// ── Constants timing ─────────────────────────────────────────────────────
	// Layout SYNC → BP → VISIBLE → FP (arcade CRT standard).
	// HBP=16 cicli prima di VISIBLE assorbono la latency pipeline (palette 1
	// ce_pix + transizione mux) → pixel 0 attivo è già stabile.
	localparam [9:0] H_TOTAL    = 10'd384;
	localparam [9:0] H_SYNC     = 10'd32;     // 0..31
	localparam [9:0] H_BP       = 10'd16;     // 32..47
	localparam [9:0] H_VISIBLE  = 10'd320;    // 48..367
	localparam [9:0] H_FP       = 10'd16;     // 368..383

	localparam [9:0] H_VIS_START = H_SYNC + H_BP;          // 48
	localparam [9:0] H_VIS_END   = H_VIS_START + H_VISIBLE; // 368

	localparam [9:0] V_SYNC     = 10'd3;      // 0..2
	localparam [9:0] V_BP       = 10'd27;     // 3..29 (= V_TOTAL-V_VISIBLE-V_SYNC-V_FP)
	localparam [9:0] V_VISIBLE  = 10'd224;    // 30..253
	localparam [9:0] V_FP       = 10'd9;      // 254..262 (59Hz) o 254..259 (60Hz, V_FP=6)

	localparam [9:0] V_VIS_START = V_SYNC + V_BP;          // 30
	localparam [9:0] V_VIS_END_59 = V_VIS_START + V_VISIBLE; // 254
	localparam [9:0] V_TOTAL_59  = 10'd263;    // → 6e6/(384*263)=59.40 Hz
	localparam [9:0] V_TOTAL_60  = 10'd260;    // → 6e6/(384*260)=60.10 Hz

	wire [9:0] V_TOTAL = mode_60hz ? V_TOTAL_60 : V_TOTAL_59;

	// ── HV counter ───────────────────────────────────────────────────────────
	always @(posedge clk) begin
		if (reset) begin
			hpos <= 10'd0;
			vpos <= 10'd0;
		end else if (ce_pix) begin
			if (hpos == H_TOTAL - 10'd1) begin
				hpos <= 10'd0;
				if (vpos == V_TOTAL - 10'd1) vpos <= 10'd0;
				else                         vpos <= vpos + 10'd1;
			end else begin
				hpos <= hpos + 10'd1;
			end
		end
	end

	// ── Sync, blanking, DE ───────────────────────────────────────────────────
	assign hsync  = (hpos < H_SYNC);
	assign vsync  = (vpos < V_SYNC);
	assign hblank = (hpos < H_VIS_START) || (hpos >= H_VIS_END);
	assign vblank = (vpos < V_VIS_START) || (vpos >= V_VIS_END_59);
	assign de     = ~hblank & ~vblank;

	// ── Active coordinates per renderer (0..319, 0..223) ─────────────────────
	assign active_x = de ? (hpos - H_VIS_START)        : 10'd0;
	assign active_y = de ? (vpos[8:0] - V_VIS_START[8:0]) : 9'd0;

endmodule

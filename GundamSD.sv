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

// GundamSD (Banpresto/Bandai 1991) - MiSTer core
// Porting base: Darius MiSTer core. MiSTer Template by Sorgelig.

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
// Pause: toggle on rising edge of joy[12] (standard MiSTer pause bit)
reg pause_toggle;
reg joy_pause_prev;
always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle <= 1'b0;
		joy_pause_prev <= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
wire pause = pause_toggle | status[17];  // pad OR OSD
assign HDMI_FREEZE = 1'b0;  // overlay pause renderizzato real-time, no freeze scaler
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;  // signed audio
wire signed [15:0] game_audio_l, game_audio_r;
assign AUDIO_L = game_audio_l;
assign AUDIO_R = game_audio_r;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// Volumi audio OSD (Q4.4: 16 = 100%, 32 = 200%, 0 = mute)
wire [2:0] osd_fm_vol  = status[88:86];
wire [2:0] osd_oki_vol = status[91:89];
reg [5:0] fm_vol_q44, oki_vol_q44;
always @(*) begin
	case (osd_fm_vol)
		3'd0: fm_vol_q44 = 6'd16;   // 100%
		3'd1: fm_vol_q44 = 6'd2;    // 12%
		3'd2: fm_vol_q44 = 6'd4;    // 25%
		3'd3: fm_vol_q44 = 6'd8;    // 50%
		3'd4: fm_vol_q44 = 6'd12;   // 75%
		3'd5: fm_vol_q44 = 6'd24;   // 150%
		3'd6: fm_vol_q44 = 6'd32;   // 200%
		3'd7: fm_vol_q44 = 6'd0;    // mute
	endcase
	case (osd_oki_vol)
		3'd0: oki_vol_q44 = 6'd16;
		3'd1: oki_vol_q44 = 6'd2;
		3'd2: oki_vol_q44 = 6'd4;
		3'd3: oki_vol_q44 = 6'd8;
		3'd4: oki_vol_q44 = 6'd12;
		3'd5: oki_vol_q44 = 6'd24;
		3'd6: oki_vol_q44 = 6'd32;
		3'd7: oki_vol_q44 = 6'd0;
	endcase
end

// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
wire signed [9:0] osd_l0_xoff  = {{4{status[43]}}, status[43:38]};
wire signed [9:0] osd_l0_yoff  = {{4{status[49]}}, status[49:44]};
wire signed [9:0] osd_l1_xoff  = {{4{status[55]}}, status[55:50]};
wire signed [9:0] osd_l1_yoff  = {{4{status[61]}}, status[61:56]};
wire signed [9:0] osd_spr_xoff = {{4{status[67]}}, status[67:62]};
wire signed [9:0] osd_spr_yoff = {{4{status[73]}}, status[73:68]};
// FG OSD bits spostati per garantire risposta. Bit bassi.
wire signed [9:0] osd_fg_xoff  = {{4{status[28]}}, status[28:23]};
wire signed [9:0] osd_fg_yoff  = {{4{status[107]}}, status[107:102]};
// Text OSD offset (CREDIT, HUD)
wire signed [9:0] osd_txt_xoff = {{4{status[113]}}, status[113:108]};
wire signed [9:0] osd_txt_yoff = {{4{status[119]}}, status[119:114]};
// Riuso OSD "Mid" per MG (Gundam non ha layer L1 separato Darius-style)
wire signed [9:0] osd_mg_xoff  = osd_l1_xoff;
wire signed [9:0] osd_mg_yoff  = osd_l1_yoff;
// Riuso OSD "BG" come BG offset
wire signed [9:0] osd_bg_xoff  = osd_l0_xoff;
wire signed [9:0] osd_bg_yoff  = osd_l0_yoff;

`include "build_id.v"
localparam CONF_STR = {
	"GundamSD;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[7:5],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"P1O[19],Refresh Rate,Original 59.4Hz,60Hz;",
	"P1O[18],Clean Pause,Off,On;",
	"P1O[101],CRT Adjust,Off,On;",
	"H1P1O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"P3,Audio;",
	"P3O[88:86],FM (YM2151) volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P3O[91:89],OKI ADPCM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"-;",
	"P4,Debug;",
	"P4O[30],BG Layer,On,Off;",
	"P4O[31],Mid Layer,On,Off;",
	"P4O[32],FG Layer,On,Off;",
	"P4O[29],Text Layer,On,Off;",
	"P4O[33],Sprites,On,Off;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	// J1: bit 4=Fire(A), 5=Jump(B), 6,7,8,9=unused, 10=Start1, 11=Coin1, 12=Pause
	// 13=Start2, 14=Coin2 (MiSTer arcade convention fissa)
	"J1,Fire,Jump,-,-,-,-,Start,Coin,Pause,Start 2P,Coin 2P;",
	"jn,A,B,,,,,Start,R,L,Select,;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;   // 16-bit: WIDE=1
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[101], 1'b0}),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

// --- Joystick to SD Gundam input mapping ---
// MAME P1_P2 port ($E0002): active low.
// Low byte P1 / high byte P2: bit0=U, bit1=D, bit2=L, bit3=R, bit4=Btn1, bit5=Btn2.
// MiSTer joy bits: joy[0]=R, joy[1]=L, joy[2]=D, joy[3]=U, joy[4]=A, joy[5]=B.
wire [7:0] p1_input = {2'b11, ~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]};
wire [7:0] p2_input = {2'b11, ~joy1[5], ~joy1[4], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]};
wire [15:0] p1_p2_input = {p2_input, p1_input};

// SD Gundam SYSTEM port ($E0004) — verified MAME dcon.cpp:345-356
//   bit0  = START1     (active LOW)
//   bit4  = START2     (active LOW)
//   bit8  = SERVICE    (active LOW)  PORT_SERVICE_NO_TOGGLE
//   altri = UNKNOWN/UNUSED → tied 1
// Coin inputs NON sono qui: vanno via SEIBU_COIN_INPUTS → Z80 → soundlatch sub2main.
// Service esposto come DIP bit 14: dip_sw[14]=0 (id "On") → service attivo (bit8=0).
wire service_mode = ~dip_sw[14];
wire [15:0] system_input16 = {7'h7F, ~service_mode,         // [15:8]
                              3'b111, ~joy1[10], 3'b111, ~joy0[10]}; // [7:0]

// Seibu coin input (ACTIVE_HIGH per SEIBU_COIN_INPUTS macro): bit0=COIN1, bit1=COIN2.
// Letto dal Z80 a 0x4013 → coin_r → soundlatch sub2main → main 68k legge 0xA0004.
wire [7:0] coin_input = {6'd0, joy1[11], joy0[11]};

// DIP switches — loaded from MRA via ioctl (index 254)
// Active-LOW: default "FF,FF" = all OFF = all 1s
reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys)
	if (ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[26:1])
		dip_sw <= ioctl_dout;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Game reset: includes download (game held in reset while ROM loads).
// Pattern Darius 2 (Arcade-Darius2_MiSTer/Template.sv:315-324):
// reset_hold 17-bit = ~1.4ms @ 96MHz dopo che ioctl_download cala. Il game è
// tenuto in reset durante caricamento ROM e per ~1.4ms extra dopo, per
// far stabilizzare bridge SDRAM banks. NON 88ms (quello rompeva HPS sync).
wire reset_cause = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
reg [16:0] reset_hold_cnt = 17'h1FFFF;
always @(posedge clk_sys) begin
	if (reset_cause)                  reset_hold_cnt <= 17'h1FFFF;
	else if (reset_hold_cnt != 17'd0) reset_hold_cnt <= reset_hold_cnt - 17'd1;
end
wire reset = (reset_hold_cnt != 17'd0);
// Bridge reset: ONLY pll_locked — bridge must run during download, before RESET drops
wire bridge_reset = ~pll_locked;
// Video reset: ONLY pll_locked — CRT needs sync always, even during RESET and download
wire video_reset = ~pll_locked;

///////////////////////   SDRAM   ///////////////////////////////

// Genesis 4-port SDRAM controller (Sorgelig + donor bridge)
// Port 0: graphics ROM + download
// Port 1: main 68000 ROM
// Port 2: temporarily unused donor ROM path
// Port 3: audio/sample ROM path

wire [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0, sd_din1, sd_din2, sd_din3;
wire        sd_wrl0, sd_wrh0, sd_wrl1, sd_wrh1, sd_wrl2, sd_wrh2, sd_wrl3, sd_wrh3;
wire        sd_req0, sd_req1, sd_req2, sd_req3;
wire        sd_ack0, sd_ack1, sd_ack2, sd_ack3;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sdram_ready;

// OKI ADPCM ROM bridge ↔ jt6295 (via main_top)
wire [17:0] oki_rom_addr;
wire  [7:0] oki_rom_data;
wire        oki_rom_ok;

sdram sdram_ctrl
(
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_sys),
	.prio_mode(2'd0),
	.ready(sdram_ready),

	.addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0),
	.din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),

	.addr1(sd_addr1), .wrl1(sd_wrl1), .wrh1(sd_wrh1),
	.din1(sd_din1), .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),

	.addr2(sd_addr2), .wrl2(sd_wrl2), .wrh2(sd_wrh2),
	.din2(sd_din2), .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),

	.addr3(sd_addr3), .wrl3(sd_wrl3), .wrh3(sd_wrh3),
	.din3(sd_din3), .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

///////////////////////   BRIDGE   ///////////////////////////////

// Bridge between game logic (level protocol) and Genesis SDRAM (toggle protocol)
wire [23:0] game_tile_addr, game_main_addr, game_sub_addr;
wire        game_tile_req, game_main_req, game_sub_req;
wire  [2:0] game_tile_kind;     // 0=BG, 1=MG, 2=FG, 3=SPR, 4=TXT
wire [31:0] game_tile_data;
wire        game_tile_valid;
wire [15:0] game_main_data, game_sub_data;
// Audio Z80 ROM removed from SDRAM — will use BRAM when audio implemented
wire        game_main_ready, game_sub_ready;

// ROM instruction cache — between game and SDRAM bridge
wire [23:0] bridge_main_addr, bridge_sub_addr;
wire        bridge_main_req, bridge_sub_req;
wire [15:0] bridge_main_data, bridge_sub_data;
wire        bridge_main_ready, bridge_sub_ready;

rom_cache #(.CACHE_BITS(9)) u_main_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_main_addr), .cpu_req(game_main_req),
	.cpu_data(game_main_data), .cpu_ready(game_main_ready),
	.sdram_addr(bridge_main_addr), .sdram_req(bridge_main_req),
	.sdram_data(bridge_main_data), .sdram_ready(bridge_main_ready)
);

rom_cache #(.CACHE_BITS(9)) u_sub_cache (
	.clk(clk_sys), .reset(reset),
	.cpu_addr(game_sub_addr), .cpu_req(game_sub_req),
	.cpu_data(game_sub_data), .cpu_ready(game_sub_ready),
	.sdram_addr(bridge_sub_addr), .sdram_req(bridge_sub_req),
	.sdram_data(bridge_sub_data), .sdram_ready(bridge_sub_ready)
);

sdram_bridge bridge
(
	.clk(clk_sys),
	.reset(bridge_reset),
	.sdram_ready(sdram_ready),

	// HPS download
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	// Game: Tile ROM (32-bit)
	.tile_byte_addr(game_tile_addr),
	.tile_req(game_tile_req),
	.gfx_kind(game_tile_kind),
	.tile_data(game_tile_data),
	.tile_valid(game_tile_valid),

	// Game: Main CPU ROM (16-bit)
	.main_byte_addr(bridge_main_addr),
	.main_req(bridge_main_req),
	.main_data(bridge_main_data),
	.main_ready(bridge_main_ready),

	// Game: temporarily unused donor ROM port
	.sub_byte_addr(bridge_sub_addr),
	.sub_req(bridge_sub_req),
	.sub_data(bridge_sub_data),
	.sub_ready(bridge_sub_ready),

	// OKI ADPCM ROM (port 3)
	.oki_byte_addr(oki_rom_addr),
	.oki_data(oki_rom_data),
	.oki_ok(oki_rom_ok),

	// SDRAM ports
	.sdram_addr0(sd_addr0), .sdram_din0(sd_din0),
	.sdram_wrl0(sd_wrl0), .sdram_wrh0(sd_wrh0),
	.sdram_req0(sd_req0), .sdram_ack0(sd_ack0), .sdram_dout0(sd_dout0),

	.sdram_addr1(sd_addr1), .sdram_din1(sd_din1),
	.sdram_wrl1(sd_wrl1), .sdram_wrh1(sd_wrh1),
	.sdram_req1(sd_req1), .sdram_ack1(sd_ack1), .sdram_dout1(sd_dout1),

	.sdram_addr2(sd_addr2), .sdram_din2(sd_din2),
	.sdram_wrl2(sd_wrl2), .sdram_wrh2(sd_wrh2),
	.sdram_req2(sd_req2), .sdram_ack2(sd_ack2), .sdram_dout2(sd_dout2),

	.sdram_addr3(sd_addr3), .sdram_din3(sd_din3),
	.sdram_wrl3(sd_wrl3), .sdram_wrh3(sd_wrh3),
	.sdram_req3(sd_req3), .sdram_ack3(sd_ack3), .sdram_dout3(sd_dout3)
);

///////////////////////   GAME   ///////////////////////////////

wire [9:0]  render_x;
wire [8:0]  render_y;
wire [15:0] map_xscroll_l0, map_xscroll_l1;
wire [15:0] map_ctrl_l0;
wire [15:0] map_yscroll_l0, map_yscroll_l1;
wire [15:0] map_xscroll_mg, map_yscroll_mg;

darius_dual68k_top game
(
	.clk(clk_sys),
	.reset(reset),
	.pause(pause),
	.clk_sel(3'd2),              // Main CPU 10 MHz (target reale Gundam)
	.sub_clk_sel(3'd0),          // donor Darius path kept until the sub CPU is removed
	.z80_clk_sel(2'd0),          // Sound CPU default (3.58 MHz)
	.p1_input(p1_input),
	.p2_input(p2_input),
	.system_input(system_input16),
	.dsw_input(dip_sw),

	// SDRAM ROM (via bridge)
	.main_rom_rdata(game_main_data),
	.main_rom_ready(game_main_ready),
	.sub_rom_rdata(game_sub_data),
	.sub_rom_ready(game_sub_ready),
	.tilerom_data(game_tile_data),
	.tilerom_valid(game_tile_valid),

	.main_rom_addr(game_main_addr),
	.main_rom_req(game_main_req),
	.sub_rom_addr(game_sub_addr),
	.sub_rom_req(game_sub_req),
	// tilerom_* main_top tied off: arbiter Gundam pilota il bridge direttamente
	.tilerom_addr(),
	.tilerom_req(),
	.tilerom_kind(),

	// Audio ROM download (ioctl → BRAM)
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	// Video
	.render_x(render_x),
	.render_y(render_y),
	.vblank_in(VBlank),
	// Scroll esposti dal CRTC Seibu
	.xscroll_l0(map_xscroll_l0),
	.xscroll_l1(map_xscroll_l1),
	.yscroll_l0(map_yscroll_l0),
	.yscroll_l1(map_yscroll_l1),
	.xscroll_mg(map_xscroll_mg),
	.yscroll_mg(map_yscroll_mg),
	.ctrl_l0(map_ctrl_l0),
	// Palette read port (per video pipeline)
	.pal_b_addr(pal_b_addr),
	.pal_b_r(pal_b_r),
	.pal_b_g(pal_b_g),
	.pal_b_b(pal_b_b),
	// Text VRAM read (renderer text legge tile word)
	.text_vram_addr(text_vram_addr),
	.text_vram_data(text_vram_data),
	// BG VRAM read (renderer BG legge tile word)
	.bg_vram_addr(bg_vram_addr),
	.bg_vram_data(bg_vram_data),
	// MG VRAM read
	.mg_vram_addr(mg_vram_addr),
	.mg_vram_data(mg_vram_data),
	// FG VRAM read
	.fg_vram_addr(fg_vram_addr),
	.fg_vram_data(fg_vram_data),
	// Sprite VRAM read (per scanner sprite)
	.spr_vram_addr(spr_vram_addr),
	.spr_vram_data(spr_vram_data),
	// gfx_bank (per MG)
	.gfx_bank(gfx_bank),
	// Coin input (HW button → Z80 → soundlatch → main 0xA0004)
	.coin_input(coin_input),
	// OKI ADPCM ROM bridge (port 3)
	.oki_rom_addr(oki_rom_addr),
	.oki_rom_data(oki_rom_data),
	.oki_rom_ok(oki_rom_ok),
	// Volumi OSD
	.fm_vol_q44(fm_vol_q44),
	.oki_vol_q44(oki_vol_q44),
	// Audio
	.audio_l(game_audio_l),
	.audio_r(game_audio_r)
);

// Palette read-side: indirizzo deciso dal pixel pipeline (priorità tra layer)
wire [10:0] pal_b_addr;
wire [7:0]  pal_b_r, pal_b_g, pal_b_b;

// Text VRAM read wires
wire [10:0] text_vram_addr;
wire [15:0] text_vram_data;

///////////////////////   VIDEO   ///////////////////////////////

// SD Gundam timing single-screen 320x224 @ 59.4 Hz (original) / 60.1 Hz.
// Pixel clock 6 MHz = clk_sys/16. HTotal=384, VTotal=263 (59.4) o 260 (60Hz).
wire ce_pix;
wire HBlank, VBlank, HSync, VSync, video_de;
wire [9:0] timing_hpos;
wire [9:0] timing_vpos;

GundamSD_video_timing u_video_timing (
	.clk        (clk_sys),
	.reset      (video_reset),
	.mode_60hz  (status[19]),
	.ce_pix     (ce_pix),
	.hpos       (timing_hpos),
	.vpos       (timing_vpos),
	.active_x   (render_x),
	.active_y   (render_y),
	.hblank     (HBlank),
	.vblank     (VBlank),
	.hsync      (HSync),
	.vsync      (VSync),
	.de         (video_de)
);

// ── Flip screen (CRTC reg 0x1A bit 0) ───────────────────────────────────────
// MAME: BIT(reg_1a, 0) → flip_screen. Arcade reale = monitor CRT capovolto;
// game scrive in VRAM convinto che lo schermo sia ruotato 180° → noi vediamo
// flippato finchè non invertiamo.
//
// Strategia:
//  - X flip: il read-side dei line_buffer (dentro tile_layer/text_renderer)
//    legge linebuf[hpos]. Sostituisco hpos con (319-hpos) → mostra mirror H.
//  - Y flip: la prefetch durante display vpos=N riempie il buffer per il
//    display vpos=N+1. In flip ON serve che mostri riga ROM (V_VISIBLE-1-(N+1))
//    = (V_VISIBLE-2-N). Sostituisco vpos del prefetch con (V_VISIBLE-2-vpos)
//    quando flip on, così target_y = V_VISIBLE-2-vpos + 1 = V_VISIBLE-1-vpos.
wire        flip_screen = map_ctrl_l0[5];
// Coordinate LOGICHE display (0..319, 0..223), shiftate dal timing CRTC raw.
// Il timing CRTC ora è SYNC→BP→VISIBLE→FP, quindi VISIBLE inizia a hpos=48,
// vpos=30. I renderer devono vedere coordinate "del gioco" 0..319/0..223.
localparam [9:0] H_VIS_START_TOP = 10'd48;   // = H_SYNC + H_BP del video_timing
localparam [8:0] V_VIS_START_TOP = 9'd30;    // = V_SYNC + V_BP
wire [9:0]  hpos_logic = timing_hpos - H_VIS_START_TOP;
wire [8:0]  vpos_logic = timing_vpos[8:0] - V_VIS_START_TOP;
// Tile_layer prefetch usa target_y = vpos+1 (la riga ROMda mostrare al display
// vpos=N+1). Quando flip ON serve target_y = V_VISIBLE-1-(N+1) = 222-N.
wire [8:0]  vpos_for_pf   = flip_screen ? (9'd222 - vpos_logic) : vpos_logic;
// Text renderer legge tile direttamente da eff_y = vpos (no prefetch ahead).
wire [8:0]  vpos_for_text = flip_screen ? (9'd223 - vpos_logic) : vpos_logic;
// Read path (X): tile_layer linebuf[hpos]. Per text è eff_x = hpos+scroll.
wire [9:0]  hpos_for_read = flip_screen ? (10'd319 - hpos_logic) : hpos_logic;

// ── Text layer renderer (8x8, 4bpp, 64x32 grid) ─────────────────────────────
// Char ROM caricata via ioctl da MRA: txtiles SDRAM region 0x040000..0x05FFFF
// (TXT_BASE byte = 0x040000*2 = 0x080000 byte? NO: TXT_BASE è word address.
//  ioctl_addr è BYTE address. Quindi ioctl carica byte da 0x080000..0x0BFFFF
//  per 128KB di txtiles in word-base 0x040000).
wire        text_opaque;
wire [10:0] text_pen;

wire        text_rom_dl_wr =
	ioctl_download && ioctl_wr && (ioctl_index == 16'd0) &&
	(ioctl_addr >= 27'h080000) && (ioctl_addr < 27'h0A0000);
// 17-bit address relativo a txtiles base byte (= ioctl_addr - 0x080000)
// bit[16] = 0 → metà bassa (plane 0,1), bit[16] = 1 → metà alta (plane 2,3)
wire [16:0] text_rom_dl_offset = ioctl_addr[16:0];
// SD Gundam Text scroll fissi: 128 X (MAME), 16 Y (centratura HW reale)
GundamSD_text_renderer u_text (
	.clk          (clk_sys),
	.reset        (reset),
	.ce_pix       (ce_pix),
	.hpos         (hpos_for_read),
	.vpos         (vpos_for_text),
	.de           (video_de),
	.layer_en     (map_ctrl_l0[3] & ~status[29]),       // bit3 = Text enable, OSD off
	.scroll_x     (16'd128),
	.scroll_y     (16'd16),
	.xoff         (osd_txt_xoff),
	.yoff         (osd_txt_yoff),
	.vram_addr    (text_vram_addr),
	.vram_data    (text_vram_data),
	.rom_dl_wr    (text_rom_dl_wr),
	.rom_dl_addr  (text_rom_dl_offset),
	.rom_dl_data  (ioctl_dout),
	.opaque       (text_opaque),
	.pen_index    (text_pen)
);

// ── BG/MG/FG layer renderer (16x16, 4bpp, 32x32) — fetch SDRAM via arbiter ──
wire        bg_opaque, mg_opaque, fg_opaque;
wire [10:0] bg_pen, mg_pen, fg_pen;
wire [10:0] bg_vram_addr, mg_vram_addr, fg_vram_addr;
wire [15:0] bg_vram_data, mg_vram_data, fg_vram_data;
wire [15:0] gfx_bank;

// new_line pulse: hpos passa da H_TOTAL-1 a 0
reg [9:0] hpos_prev;
always @(posedge clk_sys) if (ce_pix) hpos_prev <= timing_hpos;
wire layer_new_line = ce_pix && (timing_hpos == 10'd0) && (hpos_prev != 10'd0);

// CRTC scroll (Gundam dispatcher: scroll_ram + 128 X)
// map_xscroll_l0 = BG scroll X, map_yscroll_l0 = BG scroll Y
// map_xscroll_l1 = FG scroll X, map_yscroll_l1 = FG scroll Y
// MG scroll non esposto via main top: lo prendo direttamente dal CRTC se serve.
// Per ora il main top non espone MG scroll, uso 128/0 come placeholder.
// TODO: esporre crtc_scroll_mg_* dal main top.
// MAME +128 X + offset HW Y +16 (centratura calibrata su PCB Seibu D-Con)
wire [15:0] bg_scroll_x = map_xscroll_l0 + 16'd128;
wire [15:0] bg_scroll_y = map_yscroll_l0 + 16'd16;
wire [15:0] mg_scroll_x = map_xscroll_mg + 16'd128;
wire [15:0] mg_scroll_y = map_yscroll_mg + 16'd16;
wire [15:0] fg_scroll_x = map_xscroll_l1 + 16'd128;
wire [15:0] fg_scroll_y = map_yscroll_l1 + 16'd16;

// Arbiter wires
wire        arb_bg_req,  arb_mg_req,  arb_fg_req;
wire [23:0] arb_bg_addr, arb_mg_addr, arb_fg_addr;
wire [31:0] arb_bg_data, arb_mg_data, arb_fg_data;
wire        arb_bg_valid, arb_mg_valid, arb_fg_valid;

GundamSD_tile_layer #(
	.COLOR_BASE   (11'h400),
	.HAS_TRANSP   (0),
	.HAS_GFX_BANK (0),
	.TILE_KIND    (3'd0)
) u_bg (
	.clk(clk_sys), .reset(reset), .ce_pix(ce_pix),
	.hpos(hpos_for_read), .vpos(vpos_for_pf),
	.de(video_de), .layer_en(map_ctrl_l0[0] & ~status[30]),
	.new_line(layer_new_line),
	.scroll_x(bg_scroll_x), .scroll_y(bg_scroll_y),
	.xoff(osd_bg_xoff), .yoff(osd_bg_yoff),
	.gfx_bank(16'd0),
	.vram_addr(bg_vram_addr), .vram_data(bg_vram_data),
	.rom_req(arb_bg_req), .rom_addr(arb_bg_addr),
	.rom_data(arb_bg_data), .rom_valid(arb_bg_valid),
	.opaque(bg_opaque), .pen_index(bg_pen)
);

GundamSD_tile_layer #(
	.COLOR_BASE   (11'h500),
	.HAS_TRANSP   (1),
	.HAS_GFX_BANK (1),
	.TILE_KIND    (3'd1)
) u_mg (
	.clk(clk_sys), .reset(reset), .ce_pix(ce_pix),
	.hpos(hpos_for_read), .vpos(vpos_for_pf),
	.de(video_de), .layer_en(map_ctrl_l0[1] & ~status[31]),
	.new_line(layer_new_line),
	.scroll_x(mg_scroll_x), .scroll_y(mg_scroll_y),
	.xoff(osd_mg_xoff), .yoff(osd_mg_yoff),
	.gfx_bank(gfx_bank),
	.vram_addr(mg_vram_addr), .vram_data(mg_vram_data),
	.rom_req(arb_mg_req), .rom_addr(arb_mg_addr),
	.rom_data(arb_mg_data), .rom_valid(arb_mg_valid),
	.opaque(mg_opaque), .pen_index(mg_pen)
);

GundamSD_tile_layer #(
	.COLOR_BASE   (11'h600),
	.HAS_TRANSP   (1),
	.HAS_GFX_BANK (0),
	.TILE_KIND    (3'd2)
) u_fg (
	.clk(clk_sys), .reset(reset), .ce_pix(ce_pix),
	.hpos(hpos_for_read), .vpos(vpos_for_pf),
	.de(video_de), .layer_en(map_ctrl_l0[2] & ~status[32]),
	.new_line(layer_new_line),
	.scroll_x(fg_scroll_x), .scroll_y(fg_scroll_y),
	.xoff(osd_fg_xoff), .yoff(osd_fg_yoff),
	.gfx_bank(16'd0),
	.vram_addr(fg_vram_addr), .vram_data(fg_vram_data),
	.rom_req(arb_fg_req), .rom_addr(arb_fg_addr),
	.rom_data(arb_fg_data), .rom_valid(arb_fg_valid),
	.opaque(fg_opaque), .pen_index(fg_pen)
);

// ── Sprite renderer (SEI0211) ───────────────────────────────────────────────
wire        spr_opaque;
wire [10:0] spr_pen;
wire  [1:0] spr_pri;
wire  [9:0] spr_vram_addr;
wire [15:0] spr_vram_data;
wire        arb_spr_req;
wire [23:0] arb_spr_addr;
wire [31:0] arb_spr_data;
wire        arb_spr_valid;

GundamSD_sprite_renderer u_spr (
	.clk(clk_sys), .reset(reset), .ce_pix(ce_pix),
	.hpos(hpos_for_read), .vpos(vpos_logic),
	.de(video_de), .layer_en(map_ctrl_l0[4] & ~status[33]),    // bit4 = sprite enable, OSD off
	.new_line(layer_new_line),
	.spr_addr(spr_vram_addr), .spr_data(spr_vram_data),
	.rom_req(arb_spr_req), .rom_addr(arb_spr_addr),
	.rom_data(arb_spr_data), .rom_valid(arb_spr_valid),
	.opaque(spr_opaque), .pen_index(spr_pen), .pri_code(spr_pri)
);

// ── Tile ROM arbiter (5 client; r3=sprite, r4=text BRAM tied off) ──────────
tile_rom_arbiter u_arb (
	.clk(clk_sys), .reset(reset), .hblank(HBlank),
	.r0_req(arb_bg_req),  .r0_addr(arb_bg_addr),  .r0_data(arb_bg_data),  .r0_valid(arb_bg_valid),
	.r1_req(arb_mg_req),  .r1_addr(arb_mg_addr),  .r1_data(arb_mg_data),  .r1_valid(arb_mg_valid),
	.r2_req(arb_fg_req),  .r2_addr(arb_fg_addr),  .r2_data(arb_fg_data),  .r2_valid(arb_fg_valid),
	.r3_req(arb_spr_req), .r3_addr(arb_spr_addr), .r3_data(arb_spr_data), .r3_valid(arb_spr_valid),
	.r4_req(1'b0), .r4_addr(24'd0), .r4_data(), .r4_valid(),
	.tile_req(game_tile_req), .tile_addr(game_tile_addr), .tile_kind(game_tile_kind),
	.tile_data(game_tile_data), .tile_valid(game_tile_valid)
);

// Pixel pipeline con sprite + priority callback (MAME pri_cb dcon.cpp).
// pri_code semantics (MAME pri_mask 0xF0/0xFC/0xFE/0):
//   pri=3 → sprite ABOVE ALL (mask=0, copre Text/FG/MG/BG, INSERT COIN, HUD)
//   pri=0 → sprite ABOVE FG  (copre FG, MG, BG; coperto solo da Text)
//   pri=1 → sprite ABOVE MG  (copre MG, BG; coperto da FG, Text)
//   pri=2 → sprite ABOVE BG  (copre BG; coperto da MG, FG, Text)
// NOTA: ordine MAME pri_cb è 0/1/2/3 → 0xF0/0xFC/0xFE/0x00 = mask decrescente.
// Mask 0 (pri=3) significa "sopra tutto" non "sotto tutto" come avevo letto.
// Sprite va valutato PRIMA del layer che deve coprire (prio_transpen scrive
// sopra anche se layer opaque).
wire [10:0] backdrop_pen = 11'h00F;
wire spr_above_all  = spr_opaque & (spr_pri == 2'd3);  // pri=3: mask 0 = sopra tutto
wire spr_above_fg   = spr_opaque & (spr_pri == 2'd0);  // pri=0
wire spr_above_mg   = spr_opaque & (spr_pri <= 2'd1);  // pri=0 o 1
wire spr_above_bg   = spr_opaque & (spr_pri <= 2'd2);  // pri=0,1,2

// Ordine: sprite(pri=3) > Text > sprite(pri=0) > FG > sprite(pri=1) > MG > sprite(pri=2) > BG
assign pal_b_addr = spr_above_all ? spr_pen  :   // pri=3: sopra tutto (INSERT COIN)
                    text_opaque   ? text_pen :
                    spr_above_fg  ? spr_pen  :   // pri=0: copre FG/MG/BG, sotto Text
                    fg_opaque     ? fg_pen   :
                    spr_above_mg  ? spr_pen  :   // pri<=1: copre MG/BG
                    mg_opaque     ? mg_pen   :
                    spr_above_bg  ? spr_pen  :   // pri<=2: copre BG
                    bg_opaque     ? bg_pen   :
                                    backdrop_pen;

wire [7:0] video_r = video_de ? pal_b_r : 8'h00;
wire [7:0] video_g = video_de ? pal_b_g : 8'h00;
wire [7:0] video_b = video_de ? pal_b_b : 8'h00;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = crt_on ? rd_ce : ce_pix;

// Pause overlay: dim video + logo + SUPPORTERS + patron scroll.
// Output su bus av_r/g/b, poi direttamente ai pin VGA_R/G/B.
wire [7:0] av_r, av_g, av_b;
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (pause),
	.clean     (status[18]),
	.vblank    (VBlank),
	.render_x  (render_x[8:0]),
	.render_y  (render_y),
	.rgb_r_in  (video_r),
	.rgb_g_in  (video_g),
	.rgb_b_in  (video_b),
	.rgb_r_out (av_r),
	.rgb_g_out (av_g),
	.rgb_b_out (av_b)
);

// ── Analog H-Size + H-Position + V-Shift (modulo unico, pattern Raiden) ──────
// Tutti i controlli spostano/scalano il CONTENUTO lasciando i sync nativi
// (H-Size: read rate; H-Pos: rd_addr; V-Shift: shreg VSync). Nessun desync CRT.
localparam int H_TOTAL_GD = 384;
localparam int V_TOTAL_GD = 263;

// ON/OFF (status[101]): OFF = bypass nativo, ON = modulo attivo (i controlli
// funzionano anche con valori a 0).
reg crt_on;
always @(posedge clk_sys) if (ce_pix) crt_on <= status[101];

// H-Size bidirezionale (status[100:96], two's complement 5-bit): 0 = nativo,
// +1..+15 = enlarge (read piu' lento), -1..-16 = shrink (read piu' veloce).
reg signed [4:0] hsize_s;
always @(posedge clk_sys) if (ce_pix) hsize_s <= $signed(status[100:96]);

// H-Position (status[85:79], 7 bit): sposta il contenuto orizzontale. Encoding
// 0..48 = +0..+48 (destra), 79..127 = -48..-1 (sinistra).
reg [6:0] hpos_d;
always @(posedge clk_sys) if (ce_pix) hpos_d <= status[85:79];
wire signed [8:0] hpos_off = (hpos_d <= 7'd48)
	? $signed({2'b0, hpos_d})
	: $signed({2'b0, hpos_d}) - 9'sd128;

// V-Shift (status[78:74], signed 5-bit -16..+15 righe) -> passato al modulo.
reg signed [5:0] vshift_off;
always @(posedge clk_sys) if (ce_pix) vshift_off <= $signed(status[78:74]);

// Read rate a QUARTI di ciclo (step 1.56%), accumulatore. Periodo = (64+hsize)
// quarti. Reset sull'HSync nativo -> pattern deterministico per riga.
wire line_tick = ce_pix && (timing_hpos == 10'(H_TOTAL_GD - 1));
reg HSync_d;
always @(posedge clk_sys) HSync_d <= HSync;
wire native_hs_rise = HSync & ~HSync_d;
wire [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};  // hsize -16..+15 -> 48..79 quarti
reg  [7:0] rd_acc;
wire rd_tick = (rd_acc + 8'd4) >= {1'b0, rd_period};
always @(posedge clk_sys) begin
	if      (native_hs_rise) rd_acc <= 8'd0;
	else if (rd_tick)        rd_acc <= rd_acc + 8'd4 - {1'b0, rd_period};
	else                     rd_acc <= rd_acc + 8'd4;
end
wire rd_ce = crt_on ? rd_tick : ce_pix;

wire [7:0] str_r, str_g, str_b;
wire       str_hs, str_vs, str_hb, str_vb;
crt_adjust #(.VTOTAL(V_TOTAL_GD)) u_crt_adjust (
	.clk      (clk_sys),
	.pxl_cen  (ce_pix),
	.pxl2_cen (rd_ce),
	.active   (crt_on),
	.hsize    (hsize_s),
	.hoffset  (hpos_off),
	.voffset  (vshift_off),
	.r_in     (av_r), .g_in (av_g), .b_in (av_b),
	.hs_in    (HSync),           // HSync NATIVO -> no desync
	.vs_in    (VSync),
	.hb_in    (HBlank | VBlank),
	.vb_in    (VBlank),
	.r_out    (str_r), .g_out (str_g), .b_out (str_b),
	.hs_out   (str_hs), .vs_out (str_vs),
	.hb_out   (str_hb), .vb_out (str_vb)
);

// Finestra DE per l'OSD: apre all'attivo nativo (ritardato 1 riga), chiude a
// larghezza stretchata piena (pattern Blood Bros).
reg vblank_1l;
always @(posedge clk_sys) if (line_tick) vblank_1l <= VBlank;
wire native_active = ~(HBlank | vblank_1l);
reg  native_active_d;
always @(posedge clk_sys) if (ce_pix) native_active_d <= native_active;
wire native_rise = native_active & ~native_active_d;
wire str_active = ~str_hb;
reg  str_active_d;
always @(posedge clk_sys) if (rd_ce) str_active_d <= str_active;
wire str_fall = str_active_d & ~str_active;
reg de_osd;
always @(posedge clk_sys) begin
	if      (native_rise) de_osd <= 1'b1;
	else if (str_fall)    de_osd <= 1'b0;
end

// Output: ON -> dal modulo; OFF -> nativo.
assign VGA_R  = crt_on ? str_r  : av_r;
assign VGA_G  = crt_on ? str_g  : av_g;
assign VGA_B  = crt_on ? str_b  : av_b;
assign VGA_HS = crt_on ? str_hs : HSync;
assign VGA_VS = crt_on ? str_vs : VSync;

// Aspect ratio: Original = 4:3 arcade display, Full Screen = 0:0
wire [11:0] arx = (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd3 : 12'd0;

// Integer scaling forzato: Narrower HV-Integer (default), V-Integer, HV-Integer.
// Normal scaling rimosso perché senza setup utente preciso dà sempre risultato sbagliato.
video_freak video_freak
(
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(crt_on ? rd_ce : ce_pix),
	.VGA_VS(VSync),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(crt_on ? de_osd : ~(HBlank | VBlank)),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[7:5])    // 0=Normal,1=V-Int,2=Narrower,3=Wider,4=HV-Integer
);

// LED: blink during download
assign LED_USER = ioctl_download;

// ============================================================
// JTAG Debug Probes (readable via quartus_stp / System Console)
// ============================================================
// JTAG boot trace removed to save M10K for 64KB work RAM

endmodule

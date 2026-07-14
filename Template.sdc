derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# Audio subsystem runs at ce_4m (96MHz/24 = 4MHz)
# All internal paths are CE-gated with 24 cycles between active edges.
# Multicycle = 24 for setup, 23 for hold.
# Target everything under GundamSD_audio_z80 module (jt03, T80pa, mixer, ...).
# ============================================================
set_multicycle_path -setup -from [get_registers {*GundamSD_audio_z80*}] -to [get_registers {*GundamSD_audio_z80*}] 24
set_multicycle_path -hold  -from [get_registers {*GundamSD_audio_z80*}] -to [get_registers {*GundamSD_audio_z80*}] 23

# ============================================================
# Video subsystem runs at ce_pix (96MHz/16 = 6MHz): 16 clk_sys cycles
# between active pixels. Quartus evaluates these CE-gated paths as
# single-cycle, so the analog H-Size glue (H-Shift / V-Shift shift registers
# + selection mux) pushes borderline video paths negative. These paths have
# 16 cycles available; a conservative multicycle of 4/3 restores positive
# slack WITHOUT touching any RTL. Scoped to the video modules only.
# ============================================================
set VID_CE_PIX {
    *GundamSD_video_timing*
    *GundamSD_seibu_crtc*
    *crt_adjust*
    *hsync_shreg*
    *vsync_line_shreg*
}
# NOTA: *GundamSD_sprite_renderer* e *GundamSD_tile* (che matcha anche
# GundamSD_tile_layer) RIMOSSI dalla lista multicycle.
# Le loro FSM di prefetch sono `always @(posedge clk)` SENZA if(ce_pix):
# avanzano uno stato ad OGNI ciclo di clock (clk pieno, non ce_pix).
# I path interni (rom_addr = idx*128+..., dx, scrittura linebuf) chiudono in
# 1 CICLO. Applicare loro multicycle 4/3 concede 4 cicli a path da 1 ciclo:
# lo STA li vede rilassati (slack positivo) ma il fitter non li chiude ->
# instabilita' dipendente dal fitting = pixel che vibrano (MG peggio, ha
# gfx_bank che allarga il sommatore rom_addr). Vanno vincolati SINGLE-CYCLE.
# *GundamSD_text* rimosso pure (non ha FSM ce_pix da rilassare: e' wrapper).
foreach a $VID_CE_PIX {
    foreach b $VID_CE_PIX {
        set_multicycle_path -setup -from [get_registers $a] -to [get_registers $b] 4
        set_multicycle_path -hold  -from [get_registers $a] -to [get_registers $b] 3
    }
}

# ============================================================
# Reset release -> audio (jt51 phase accumulators): the async reset counter
# (reset_hold_cnt) runs at full clk_sys but its release is a one-shot at
# power-up. The jt51 phase/EG paths are ce-gated slow. These reset->audio
# paths need not close single-cycle. Multicycle to relieve them.
# ============================================================
set_multicycle_path -setup -from [get_registers {*reset_hold_cnt*}] -to [get_registers {*GundamSD_audio_z80*}] 4
set_multicycle_path -hold  -from [get_registers {*reset_hold_cnt*}] -to [get_registers {*GundamSD_audio_z80*}] 3

# ============================================================
# Sprite renderer robustness: the sprite linebuffers / opaque / pri_code paths
# are ce_pix-gated (16 cycles) but the fitter can place them tightly and they
# become fragile across refits (visible sprite glitches). Give the reset->sprite
# and sprite-internal paths explicit multicycle headroom so placement always
# closes with margin, immune to refit variance.
# ============================================================
set_multicycle_path -setup -from [get_registers {*reset_hold_cnt*}] -to [get_registers {*GundamSD_sprite_renderer*}] 4
set_multicycle_path -hold  -from [get_registers {*reset_hold_cnt*}] -to [get_registers {*GundamSD_sprite_renderer*}] 3

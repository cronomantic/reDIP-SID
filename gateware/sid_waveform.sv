// ----------------------------------------------------------------------------
// This file is part of reDIP SID, a MOS 6581/8580 SID FPGA emulation platform.
// Copyright (C) 2022  Dag Lem <resid@nimrod.no>
//
// This source describes Open Hardware and is licensed under the CERN-OHL-S v2.
//
// You may redistribute and modify this source and make products using it under
// the terms of the CERN-OHL-S v2 (https://ohwr.org/cern_ohl_s_v2.txt).
//
// This source is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-S v2 for applicable conditions.
//
// Source location: https://github.com/daglem/reDIP-SID
// ----------------------------------------------------------------------------

`default_nettype none

module sid_waveform #(
    // Default to init, since the oscillator stays at 'h555555 after reset.
    localparam INIT_OSC   = 1,
    // Default to init, since the noise LFSR stays at 'h7ffffe after reset.
    // FIXME: Is the initial value 'h7fffff possibly caused by a long reset?
    localparam INIT_NOISE = 1,
    // Time for noise LFSR to be filled with 1 bits when reset or test is held.
    localparam NOISE_TTL_6581 = 24'h8000,
    localparam NOISE_TTL_8580 = 24'h950000
)(
    input  logic               clk,
    input  logic               res,
    input  sid::model_e        model,
    input  sid::phase_t        phase,
    input  sid::waveform_reg_t reg_i,
    input  sid::sync_t         sync_i,
    output sid::sync_t         sync_o,
    output sid::waveform_i_t   out
);

    // Phase-accumulating oscillator.
    // Even bits are high on powerup, and there is no reset.
    // Since initial values != 0 require LUTs, we make this configurable.
    sid::reg24_t osc        = INIT_OSC ? { 12{2'b01} } : 0;
    sid::reg24_t osc_next;
    logic        msb_i_prev = 0;
    logic        msb_i_up;
    logic        sync_res;

    // Waveforms.
    logic        osc19_prev = 0;
    logic        nclk       = 0;
    logic        nclk_prev  = 0;
    logic        nres       = 0;
    logic        nres_prev  = 0;
    sid::reg23_t noise      = INIT_NOISE ? '1 : '0;
    logic        pulse      = 0;
    logic        tri_xor;
    sid::reg12_t saw_tri    = INIT_OSC ? { 6{2'b01} } : 0;
    sid::reg24_t noise_age  = 0;

    always_comb begin
        // A sync source will normally sync its destination when the MSB of the
        // sync source rises. However if the sync source is itself synced on the
        // same cycle, its MSB is zeroed, and the destination will not be synced.
        // In the real SID, the sync dependencies form a circular combinational
        // circuit, which takes the form of a ring oscillator when all three
        // oscillators are synced on the same cycle. Here, like in reSID, no
        // oscillator will be synced in this special case of the special case.
        osc_next    = osc + { 8'b0, reg_i.freq_hi, reg_i.freq_lo };
        sync_o.msb  = osc_next[23];
        msb_i_up    = ~msb_i_prev & sync_i.msb;
        sync_o.sync = reg_i.test | (reg_i.sync & msb_i_up);
        sync_res    = reg_i.test | (reg_i.sync & msb_i_up & ~sync_i.sync);

        // The sawtooth and triangle waveforms are constructed from the upper
        // 12 bits of the oscillator. When sawtooth is not selected, and the MSB
        // is high, the lower 11 of these 12 bits are inverted. When triangle is
        // selected, the lower 11 bits are shifted up to produce the final
        // output. The MSB may be modulated by the preceding oscillator for ring
        // modulation.
        tri_xor = ~reg_i.sawtooth & ((reg_i.ring_mod & ~sync_i.msb) ^ osc[23]);

        // Waveform output, to waveform mixer / DAC.
        out.selector = { reg_i.noise, reg_i.pulse, reg_i.sawtooth, reg_i.triangle };
        out.noise    = { noise[20], noise[18], noise[14], noise[11], noise[9], noise[5], noise[2], noise[0] };
        out.pulse    = pulse;
        out.saw_tri  = saw_tri;
    end

    always_ff @(posedge clk) begin
        // Update oscillator.
        // In the real SID, an intermediate sum is latched by phi2, and this
        // sum is simultaneously synced, output to waveform generation bits,
        // and written back to osc on phi1.
        if (phase[sid::PHI2_PHI1]) begin
            if (sync_res) begin
                osc <= '0;
            end else begin
                osc <= osc_next;
            end
        end

        // In the 8580, sawtooth / triangle is latched by phi2, and is thus
        // delayed by one SID cycle.
        if ((model == sid::MOS6581 && phase[sid::PHI1]) ||
            (model == sid::MOS8580 && phase[sid::PHI2_PHI1]))
        begin
            saw_tri <= { osc[23], osc[22:12] ^ { 11{tri_xor} } };
        end

        // Noise and pulse.
        if (phase[sid::PHI2_PHI1]) begin
            // OSC bit 19 is read before the update of OSC at PHI2_PHI1, i.e.
            // it's delayed by one cycle.
            nclk       <= ~(res | reg_i.test | (~osc19_prev & osc[19]));
            nclk_prev  <= nclk;
            nres       <= res | reg_i.test;
            nres_prev  <= nres;
            osc19_prev <= osc[19];

            if (~nclk) begin
                // LFSR shift phase 1.
                if (noise_age == (model == sid::MOS6581 ?
                                  NOISE_TTL_6581 :
                                  NOISE_TTL_8580))
                begin
                    // Reset LFSR.
                    noise <= '1;
                end else begin
                    noise_age <= noise_age + 1;
                end
            end else begin
                noise_age <= 0;

                // The noise LFSR is clocked after OSC bit 19 goes high, or when
                // reset or test is released.
                if (~nclk_prev & nclk) begin
                    // LFSR shift phase 2.
                    // Completion of the shift is delayed by 2 cycles after OSC
                    // bit 19 goes high.
                    noise <= { noise[21:0], (nres_prev | noise[22]) ^ noise[17] };
                end else if (reg_i.noise & (reg_i.pulse | reg_i.sawtooth | reg_i.triangle)) begin
                    // Writeback to LFSR from combined waveforms when nclk = 1.
                    // FIXME: This should AND in actual bit values, which are
                    // first calculated in sid_voice.sv. For now, we assume that
                    // combined waveforms are used to write zeros to the LFSR.
                    { noise[20], noise[18], noise[14], noise[11], noise[9], noise[5], noise[2], noise[0] } <= '0;
                end
            end

            // The pulse width comparison is done at phi2, before the oscillator
            // is updated at phi1. Thus the pulse waveform is delayed by one cycle
            // with respect to the oscillator.
            pulse <= (osc[23:12] >= { reg_i.pw_hi[3:0], reg_i.pw_lo }) | reg_i.test;
        end

        if (phase[sid::PHI1]) begin
            // The input oscillator MSB must be stored after sync.
            msb_i_prev <= sync_i.msb;
        end
    end
endmodule

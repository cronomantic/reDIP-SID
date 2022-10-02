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

// FIXME: The 8580 combined waveforms are sampled / calculated using a non-
// delayed OSC index. Since saw_tri is delayed by one cycle on the 8580, this
// will presently yield a further one cycle delay for combined waveforms.

// Waveform selector, voice DCA (digitally controlled amplifier).
// Modeling of non-linearities in MOS6581 waveform and envelope DACs.
module sid_voice #(
    localparam WAVEFORM_DC_6581 = -16'sh380,  // OSC3 = 'h38 at 5.94V.
    localparam WAVEFORM_DC_8580 = -16'sh800,  // No DC offsets in the MOS8580.
    localparam VOICE_DC_6581    = 32'('sh800*'shff), // 1/2 the dynamic range.
    localparam VOICE_DC_8580    = 32'sh0      // No DC offsets in the MOS8580.
)(
    input  logic          clk,
    input  sid::model_e   model,
    input  sid::voice_i_t voice_i,
    // The outputs are delayed by 1 cycle.
    output sid::s24_t     voice_o,
    output sid::reg8_t    osc_o
);

    // Registered values for pipelined calculation.
    sid::model_e model_prev    = 0;
    sid::reg4_t  selector_prev = 0;

    // Pre-calculated waveforms for waveform selection.
    sid::reg12_t npst;          // Any regular waveform
    sid::reg12_t npst_6581;     // Output from 6581 DAC
    sid::reg12_t npst_dac = 0;  // 6581 / 8580 result
    sid::reg8_t  pst      = 0;  // Combined waveforms
    sid::reg8_t  ps__6581 = 0;
    sid::reg8_t  ps__8580 = 0;
    sid::reg8_t  p_t_6581 = 0;
    sid::reg8_t  p_t_8580 = 0;
    sid::reg8_t  _st      = 0;

    // Resulting digital waveform.
    sid::reg12_t waveform;

    // Non-linear 6581 envelope DAC.
    sid::reg8_t env_6581;

    // Inputs to voice DCA.
    sid::s32_t voice_DC;
    sid::s16_t wave_dac;
    sid::s16_t env_dac  = 0;
    // Output from voice DCA.
    sid::s32_t voice_res;

    // MOS6581 waveform DAC output.
    sid_dac #(
        .BITS (12)
    ) waveform_dac (
        .vin  (npst),
        .vout (npst_6581)
    );

    // MOS6581 envelope DAC output.
    sid_dac #(
        .BITS (8)
    ) envelope_dac (
        .vin  (voice_i.envelope),
        .vout (env_6581)
    );
              
    // Voice DCA (digitally controlled amplifier).
    // voice_res = voice_DC + waveform_o*envelope_o
    // The result fits in 21 bits.
    muladd voice_dca (
        .c (voice_DC),
        .s (1'b0),
        .a (wave_dac),
        .b (env_dac),
        .o (voice_res)
    );

    always_comb begin
        // With respect to the oscillator, the waveform cycle delays are:
        // * saw_tri: 0 (6581) / 1 (8580)
        // * pulse:   1
        // * noise:   2

        // Regular waveforms are computed on cycle 1. These are passed through
        // the non-linear MOS6581 waveform DAC.
        // The result for pulse is identical, but we include it for simplicity.
        // All combined waveforms which include noise output zero after a few
        // cycles.
        unique case (voice_i.waveform.selector)
          'b1000:  npst = { voice_i.waveform.noise, 4'b0 };
          'b0100:  npst = { 12{voice_i.waveform.pulse} };
          'b0010:  npst = voice_i.waveform.saw_tri;
          'b0001:  npst = { voice_i.waveform.saw_tri[10:0], 1'b0 };
          default: npst = 0;
        endcase

        // Final waveform selection on cycle 2.
        // All inputs to the combinational logic are from cycle 1.
        unique case (selector_prev)
          'b0111:  waveform = { pst, 4'b0 };
          'b0110:  waveform = { ((model_prev == sid::MOS6581) ? ps__6581 : ps__8580), 4'b0 };
          'b0101:  waveform = { ((model_prev == sid::MOS6581) ? p_t_6581 : p_t_8580), 4'b0 };
          'b0011:  waveform = { _st, 4'b0 };
          default: waveform = npst_dac;
        endcase

        // Setup for voice DCA multiply-add, ready on cycle 2.
        voice_DC = (model_prev == sid::MOS6581) ?
                   VOICE_DC_6581 :
                   VOICE_DC_8580;
        wave_dac = signed'(16'(waveform)) +
                   ((model_prev == sid::MOS6581) ?
                    WAVEFORM_DC_6581 :
                    WAVEFORM_DC_8580);

        // The outputs are delayed by 1 cycle.
        osc_o   = waveform[11-:8];
        voice_o = voice_res[23-:24];
    end

    always_ff @(posedge clk) begin
        // FIXME: Should we use a clock enable in order to save power?

        // Cycle 1: Register all candidate waveforms, to synchronize with
        // output from BRAM, and deliver one result per cycle from a pipeline.

        // For pipelined selection of waveform.
        model_prev    <= model;
        selector_prev <= voice_i.waveform.selector;

        // Regular waveforms, passed through the non-linear MOS6581
        // waveform DAC.
        npst_dac <= (model == sid::MOS6581) ?
                    npst_6581 :
                    npst;

        // Combined waveforms.
        // These aren't accurately modeled in the analog domain, so passing
        // them through the non-linear MOS6581 DAC wouldn't make much sense.
        // Skipping this avoids further muxing, and speeds up the design.
        pst      <= sid_waveform_PST(model, voice_i.waveform.saw_tri);
        ps__6581 <= sid_waveform_PS__6581[voice_i.waveform.saw_tri[10:0]];
        ps__8580 <= sid_waveform_PS__8580[voice_i.waveform.saw_tri];
        p_t_6581 <= sid_waveform_P_T_6581[voice_i.waveform.saw_tri[10:0]];
        p_t_8580 <= sid_waveform_P_T_8580[voice_i.waveform.saw_tri[10:0]];
        _st      <= sid_waveform__ST(model, voice_i.waveform.saw_tri);

        // Setup for voice DCA multiply-add, ready on cycle 2.
        env_dac  <= (model == sid::MOS6581) ?
                    signed'(16'(env_6581)) :
                    signed'(16'(voice_i.envelope));
    end

    // Combined waveform lookup tables.
    sid::reg8_t sid_waveform_PS__6581[2048];
    sid::reg8_t sid_waveform_PS__8580[4096];
    sid::reg8_t sid_waveform_P_T_6581[2048];
    sid::reg8_t sid_waveform_P_T_8580[2048];

    // od -An -tx1 -v reSID/src/wave6581_PS_.dat | head -128 | cut -b2- > sid_waveform_PS__6581.hex
    // od -An -tx1 -v reSID/src/wave8580_PS_.dat |             cut -b2- > sid_waveform_PS__8580.hex
    // od -An -tx1 -v reSID/src/wave6581_P_T.dat | head -128 | cut -b2- > sid_waveform_P_T_6581.hex
    // od -An -tx1 -v reSID/src/wave8580_P_T.dat | head -128 | cut -b2- > sid_waveform_P_T_8580.hex
    initial begin
        $readmemh("sid_waveform_PS__6581.hex", sid_waveform_PS__6581);
        $readmemh("sid_waveform_PS__8580.hex", sid_waveform_PS__8580);
        $readmemh("sid_waveform_P_T_6581.hex", sid_waveform_P_T_6581);
        $readmemh("sid_waveform_P_T_8580.hex", sid_waveform_P_T_8580);
    end
endmodule

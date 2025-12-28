// Copyright Wenting Zhang 2024
//
// This source describes Open Hardware and is licensed under the CERN-OHL-P v2
//
// You may redistribute and modify this documentation and make products using
// it under the terms of the CERN-OHL-P v2 (https:/cern.ch/cern-ohl). This
// documentation is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-P v2 for applicable conditions
//
// pixel_processing.v
// Combinational single pixel processing
`timescale 1ns / 1ps
`default_nettype none
`include "defines.vh"
module pixel_processing(
    input  wire [5:0]  csr_lutframe,// Total frames in LUT
    input  wire [1:0]  csr_mindrv,  // Dynamic frame rate cap setting
    input  wire [3:0]  proc_p_or,   // Original pixel
    input  wire        proc_p_bd_1b,// Bayer dithered pixel to 1-bit (FAST_MONO)
    input  wire [1:0]  proc_p_bd_2b,// Bayer dithered pixel to 2-bit (FAST_GREY)
    input  wire        proc_p_n1,   // Blue noise dithered pixel to 1-bit
    input  wire [3:0]  proc_p_n4,   // Blue noise dithered pixel to 4-bit
    input  wire        proc_p_r2,   // R2 LDG dithered pixel to 1-bit
    input  wire [15:0] proc_bi,     // Pixel state input from VRAM
    output reg  [15:0] proc_bo,     // Pixel state output to VRAM
    input  wire [1:0]  proc_lut_rd, // Read out from LUT
    output reg  [1:0]  proc_output, // Output to screen
    input  wire [1:0]  op_state,    // Current overall operating state
    input  wire        op_valid,    // External operation enable
    input  wire [7:0]  op_cmd,      // External operation command
    input  wire [7:0]  op_param,    // External operation parameter
    input  wire [7:0]  op_framecnt, // Current overall frame counter for state
    input  wire [5:0]  al_framecnt, // Auto LUT mode frame counter
    input  wire        neighbor_video, // Neighbor pixel is in video mode (FAST_GREY)
    input  wire        doping_active, // Global doping sequence in progress
    input  wire        doping_phase,  // 0 = extreme drive, 1 = reverse drive
    input  wire        doping_first_frame // First frame of doping sequence (for B/W 1-frame pulse)
);

    // Pixel state: 16bits
    // Bit 15-12: Mode
    // Bit 13-12 is shared
    localparam MODE_MANUAL_LUT_NO_DITHER = 2'd0; // 00xx
    localparam MODE_MANUAL_LUT_BLUE_NOISE = 2'd1; // 01xx
    localparam MODE_FAST_MONO_NO_DITHER = 4'd8; // 1000
    localparam MODE_FAST_MONO_BAYER = 4'd9; // 1001
    localparam MODE_FAST_MONO_BLUE_NOISE = 4'd10; // 1010
    localparam MODE_FAST_GREY = 4'd11; // 1011
    localparam MODE_AUTO_LUT_NO_DITHER = 4'd12; // 1100
    localparam MODE_AUTO_LUT_BLUE_NOISE = 4'd13; // 1101
    localparam MODE_FAST_MONO_R2 = 4'd14; // 1110 - R2 LDG dithering

    localparam FASTM_B2W_FRAMES = 6'd7;      // MONO duration for all pixels
    localparam FASTM_W2B_FRAMES = 6'd7;

    // FAST_GREY timing (13 frames total: B/W=6+7=13, Grey=6+2+5=13)
    // Use defines from defines.vh for consistency

    localparam AUTOLUT_HOLDOFF_FRAMES = 6'd60;

    wire [5:0] fastg_g2w_frames =
        (pixel_prev == 4'd0) ? 6'd9 : // Black to white
        (pixel_prev == 4'd1) ? 6'd9 :
        (pixel_prev == 4'd2) ? 6'd9 :
        (pixel_prev == 4'd3) ? 6'd9 :
        (pixel_prev == 4'd4) ? 6'd8 :
        (pixel_prev == 4'd5) ? 6'd8 :
        (pixel_prev == 4'd6) ? 6'd8 :
        (pixel_prev == 4'd7) ? 6'd7 :
        (pixel_prev == 4'd8) ? 6'd7 :
        (pixel_prev == 4'd9) ? 6'd6 :
        (pixel_prev == 4'd10) ? 6'd6 :
        (pixel_prev == 4'd11) ? 6'd5 :
        (pixel_prev == 4'd12) ? 6'd4 :
        (pixel_prev == 4'd13) ? 6'd3 :
        (pixel_prev == 4'd14) ? 6'd2 :
                             6'd1;
    wire [5:0] fastg_g2b_frames =
        (pixel_prev == 4'd0) ? 6'b1 : // Black to black
        (pixel_prev == 4'd1) ? 6'd2 :
        (pixel_prev == 4'd2) ? 6'd2 :
        (pixel_prev == 4'd3) ? 6'd3 :
        (pixel_prev == 4'd4) ? 6'd3 :
        (pixel_prev == 4'd5) ? 6'd4 :
        (pixel_prev == 4'd6) ? 6'd4 :
        (pixel_prev == 4'd7) ? 6'd5 :
        (pixel_prev == 4'd8) ? 6'd6 :
        (pixel_prev == 4'd9) ? 6'd7 :
        (pixel_prev == 4'd10) ? 6'd8 :
        (pixel_prev == 4'd11) ? 6'd9 :
        (pixel_prev == 4'd12) ? 6'd9 :
        (pixel_prev == 4'd13) ? 6'd9 :
        (pixel_prev == 4'd14) ? 6'd9 : 6'd9;

    // In auto LUT mode:
    // Bit 11-10: Stage
    // In MONO stage:
    // Bit 9-4: Frame counter
    // Bit 3-2: Dynamic frame rate cap
    // Bit 1: Reserved, keep at 0
    // Bit 0: Previous frame pixel value (0 black 1 white)
    // In DONE/HOLD stage:
    // Bit 9-4: Frame counter
    // Bit 3-0: Last pixel value
    // In GREY stage:
    // Bit 9-8: Reserved
    // Bit 7-4: Source pixel value
    // Bit 3-0: Target pixel value
    // Auto LUT mode is a hybrid between fast mono mode and dithered LUT mode.
    // The update process of each pixel is divided into 4 stages:
    localparam STAGE_DONE = 2'd0; // Screen already settled. No operation
    localparam STAGE_MONO = 2'd1; // Driving to mono (same as fast mono mode)
    localparam STAGE_HOLD = 2'd2; // Hold off (wait before start driving greyscale)
    localparam STAGE_GREY = 2'd3; // Driving to greyscale (non-cancellable)
    // When change is detected on the DONE pixel, it kicks off the update process
    // immediately similar to the fast mono mode, entering the MONO stage.
    // Once the mono update is done, it enters the HOLD stage.
    // If changes are detected during HOLD stage, it goes back to the MONO stage.
    // If the HOLD stage times out (means no changes are ever detected) and global
    // greyscale counter is at 1 (next round starts the next frame), it updates
    // The source and destination colors and enters GREY stage.
    // In the GREY stage it follows the waveform LUT to drive the screen. Once
    // that's done it goes back to the DONE stage.

    // In manual LUT mode:
    // Bit 13-10: Source pixel value
    // Bit 9-4: Frame counter
    // Bit 3-0: Target pixel value
    // When frame counter is not 0, waveform lookup is in progress.
    // When lookup is in progress, both target and source pixel value are hold
    // still, and the frame counter is decremented.
    // When lookup is not in progress and an external update is request on the
    // region, the input pixel is copied to target pixel value, the old target
    // pixel value (current screen status) is copied to target pixel value, and
    // the frame counter is set to LUT frame length.

    // In fast mono mode:
    // Bit 11-10: Reserved
    // Bit 9-4: Frame counter
    // Bit 3-2: Dynamic frame rate cap
    // Bit 1: Reserved, keep at 0
    // Bit 0: Previous frame pixel value (0 black 1 white)

    // In fast grey 4-level mode:
    // Bit 11-10: Stage
    // Bit 9-4: Frame counter
    // Bit 3-2: Reserved, keep at 0
    // Bit 1-0: Previous frame pixel value

    // Pixel processing
    wire [1:0] pixel_mode_hi = proc_bi[15:14];
    wire [3:0] pixel_mode = proc_bi[15:12];
    wire [1:0] pixel_stage = proc_bi[11:10];
    wire [5:0] pixel_framecnt = proc_bi[9:4];
    wire [3:0] pixel_prev = proc_bi[3:0];
    wire [1:0] pixel_mindrv = proc_bi[3:2];
    wire [5:0] pixel_framecnt_dec = pixel_framecnt - 1;
    wire [1:0] pixel_mindrv_dec = (pixel_mindrv != 2'd0) ? (pixel_mindrv - 2'd1) : 2'd0;
    // Specific to fast mono mode
    wire [5:0] pixel_framecnt_2w = FASTM_B2W_FRAMES - pixel_framecnt + 1;
    wire [5:0] pixel_framecnt_2b = FASTM_W2B_FRAMES - pixel_framecnt + 1;
    wire [3:0] pixel_prev_bext = {4{pixel_prev[0]}};
    wire [3:0] pixel_vin_bext = {4{proc_vin[3]}};

    // Decode base mode and dither mode
    localparam BASEMODE_MANUAL_LUT = 2'b00;
    localparam BASEMODE_FAST_MONO = 2'b01;
    localparam BASEMODE_FAST_GREY = 2'b10;
    localparam BASEMODE_AUTO_LUT = 2'b11;

    localparam DITHER_NONE = 3'b000;
    localparam DITHER_BAYER = 3'b001;
    localparam DITHER_BN_1BIT = 3'b010;
    localparam DITHER_BN_4BIT = 3'b011;
    localparam DITHER_R2 = 3'b100;

    // EX op decoding sorta
    wire manual_lut_update_en = op_valid && (op_cmd == `OP_EXT_REDRAW);
    wire set_mode_en = op_valid && (op_cmd == `OP_EXT_SETMODE);
    wire clear_en = op_valid && (op_cmd == `OP_EXT_REDRAW);
    wire force_clear = (set_mode_en && (op_framecnt != 0)) || clear_en;
    wire set_mode_apply = set_mode_en && (op_framecnt == 0);

    reg [1:0] pixel_basemode;
    reg [2:0] pixel_dither;
    always @(*) begin
        case (pixel_mode_hi)
        MODE_MANUAL_LUT_NO_DITHER: begin
            pixel_basemode = BASEMODE_MANUAL_LUT;
            pixel_dither = DITHER_NONE;
        end
        MODE_MANUAL_LUT_BLUE_NOISE: begin
            pixel_basemode = BASEMODE_MANUAL_LUT;
            pixel_dither = DITHER_BN_4BIT;
        end
        default: begin
            case (pixel_mode) 
            MODE_FAST_MONO_NO_DITHER: begin
                pixel_basemode = BASEMODE_FAST_MONO;
                pixel_dither = DITHER_NONE;
            end
            MODE_FAST_MONO_BAYER: begin
                pixel_basemode = BASEMODE_FAST_MONO;
                pixel_dither = DITHER_BAYER;
            end
            MODE_FAST_MONO_BLUE_NOISE: begin
                pixel_basemode = BASEMODE_FAST_MONO;
                pixel_dither = DITHER_BN_1BIT;
            end
            MODE_FAST_GREY: begin
                pixel_basemode = BASEMODE_FAST_GREY;
                pixel_dither = DITHER_NONE;
            end
            MODE_AUTO_LUT_NO_DITHER: begin
                pixel_basemode = BASEMODE_AUTO_LUT;
                pixel_dither = DITHER_NONE;
            end
            MODE_AUTO_LUT_BLUE_NOISE: begin
                pixel_basemode = BASEMODE_AUTO_LUT;
                pixel_dither = DITHER_BN_4BIT;
            end
            MODE_FAST_MONO_R2: begin
                pixel_basemode = BASEMODE_FAST_MONO;
                pixel_dither = DITHER_R2;
            end
            default: begin
                // Fallback, todo: report this as an error
                pixel_basemode = BASEMODE_FAST_MONO;
                pixel_dither = DITHER_NONE;
            end
            endcase
        end
        endcase
    end

    wire [3:0] clear_color =
        (pixel_basemode == BASEMODE_MANUAL_LUT) ? 4'hF :
        ((op_framecnt[2:1] == 2'b11) ? 4'h0 :
        (op_framecnt[3] ? 4'h0 : 4'hF));

    /* verilator lint_off UNUSEDSIGNAL */
    // Only 4 MSBs used
    wire [7:0] proc_p_li; // linear
    /* verilator lint_on UNUSEDSIGNAL */
    // Let it optimize, only 4b in and 4b out used
    /*degamma degamma (
        .in({proc_p_or, proc_p_or[1:0]}),
        .out(proc_p_li)
    );*/
    assign proc_p_li = {proc_p_or, 4'b0};

    wire [3:0] proc_vin = force_clear ? clear_color :
        (pixel_basemode == BASEMODE_FAST_GREY) ? ({proc_p_bd_2b, 2'b0}) :
        (pixel_dither == DITHER_NONE) ? (proc_p_or) :
        (pixel_dither == DITHER_BAYER) ? ({4{proc_p_bd_1b}}) :
        (pixel_dither == DITHER_BN_1BIT) ? ({4{proc_p_n1}}) :
        (pixel_dither == DITHER_BN_4BIT) ? (proc_p_n4) :
        (pixel_dither == DITHER_R2) ? ({4{proc_p_r2}}) : {4'd0};

    wire [3:0] proc_vinnd = force_clear ? clear_color : proc_p_li[7:4];

    `define NO_DRIVE    2'b00
    `define DRIVE_BLACK 2'b01
    `define DRIVE_WHITE 2'b10

    wire [1:0] drive_towards_input = proc_vin[3] ? `DRIVE_WHITE: `DRIVE_BLACK;
    wire [1:0] drive_against_input = proc_vin[3] ? `DRIVE_BLACK: `DRIVE_WHITE;

    // FAST_GREY helper: check if target is grey (01 or 10)
    wire fg_is_grey_target = (proc_vin[3:2] == 2'b01) || (proc_vin[3:2] == 2'b10);
    // MONO frames: 6 for all targets (reduced from 7)
    wire [3:0] fg_mono_frames_2w = 4'd6;
    wire [3:0] fg_mono_frames_2b = 4'd6;
    // Round target to mono (B=00 or W=11) based on MSB - for video/rapid changes
    wire [1:0] proc_vin_mono = {proc_vin[3], proc_vin[3]};
    // FAST_GREY frame counter split: [5:4]=change counter, [3:0]=stage frames
    wire [1:0] fg_counter = pixel_framecnt[5:4];
    wire [3:0] fg_frames = pixel_framecnt[3:0];
    // Doping mode: fg_frames[3:1] = 111 (fg_frames = 14 or 15)
    // In doping mode, doping_count uses 3 bits: {fg_counter[1:0], fg_frames[0]}
    wire fg_in_doping_mode = (fg_frames[3:1] == 3'b111);
    wire [1:0] fg_counter_for_video = fg_in_doping_mode ? 2'd0 : fg_counter;
    wire [1:0] fg_counter_inc = (fg_counter_for_video == 2'd3) ? 2'd3 : (fg_counter_for_video + 2'd1);
    wire [1:0] fg_counter_dec = (fg_counter == 2'd0) ? 2'd0 : (fg_counter - 2'd1);
    wire [3:0] fg_frames_dec = fg_frames - 4'd1;
    // Mid-transition direction change: calculate new frame count
    wire [3:0] fg_frames_2w = FASTM_B2W_FRAMES[3:0] - fg_frames + 4'd1;
    wire [3:0] fg_frames_2b = FASTM_W2B_FRAMES[3:0] - fg_frames + 4'd1;
    // Video mode: 3+ changes within cooldown window, OR neighbor is in video mode
    // In doping mode, treat as non-video (fg_counter is doping_count, not video counter)
    wire fg_video_mode = (pixel_stage == STAGE_DONE) && !fg_in_doping_mode && ((fg_counter >= 2'd3) || neighbor_video);

    // FAST_GREY overdrive helper wires (must be outside always block)
    wire switching_dir = (proc_vin[3] != pixel_prev[1]);
    wire [3:0] mono_frames_base = `FASTG_MONO_FRAMES;
    wire [3:0] mono_frames_od = switching_dir ? (mono_frames_base + {2'b0, pixel_prev[3:2]}) : mono_frames_base;
    wire [1:0] new_dc_bias = switching_dir ? 2'd0 : pixel_prev[3:2];
    // STAGE_DONE helper wires
    wire fg_truly_idle = (fg_counter == 2'd0) && (fg_frames == 4'd0);
    // 3-bit doping_count: {fg_counter[1:0], fg_frames[0]} when in doping mode
    wire [2:0] doping_count = {fg_counter, fg_frames[0]};
    wire [2:0] doping_count_inc = doping_count + 3'd1;
    wire [1:0] dc_bias_done = pixel_prev[3:2];
    wire doping_count_ok = (doping_count != 3'd5);  // B/W limited to 5 pulses
    wire bw_bias_ok = (dc_bias_done != `DC_BIAS_MAX);  // B/W also limited by dc_bias

    always @(*) begin
        // Normal mode, init mode override later
        case (pixel_basemode)
        BASEMODE_MANUAL_LUT: begin
            if (pixel_framecnt != 0) begin
                // Update in progress, ignore update/ external request
                proc_output = proc_lut_rd;
                proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
            end
            else begin
                proc_output = `NO_DRIVE; // TODO: Reduce this latency
                if (manual_lut_update_en || force_clear) begin
                    // Update requested, initiate update
                    proc_bo = {proc_bi[15:14], pixel_prev, csr_lutframe, proc_vin};
                end
                else begin
                    proc_bo = proc_bi;
                end
            end
        end
        BASEMODE_AUTO_LUT: begin
            if (pixel_stage == STAGE_MONO) begin
                // Framecnt != 0 means in MONO stage
                // Currently updating
                if ((proc_vinnd[3] != pixel_prev[0]) && (pixel_mindrv == 2'd0)) begin
                    // Pixel state changed
                    proc_output = drive_towards_input;
                    proc_bo = proc_vinnd[3] ? (
                        {proc_bi[15:10], pixel_framecnt_2w, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:10], pixel_framecnt_2b, csr_mindrv, 2'd0};
                end
                else begin
                    // Pixel state not changed
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    // Finishing mono update next frame
                    if (pixel_framecnt == 0) begin
                        // Hold off for some time before start grayscale render
                        proc_bo = {proc_bi[15:12], STAGE_HOLD, AUTOLUT_HOLDOFF_FRAMES - FASTM_B2W_FRAMES, {4{pixel_prev[0]}}};
                    end
                    else begin
                        proc_bo = {proc_bi[15:10], pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
                    end
                end
            end
            else if (pixel_stage == STAGE_HOLD) begin
                // Not currently updating, display in BINARY/ GREYSCALE mode
                if (proc_vinnd[3] != pixel_prev[3]) begin
                    // Binary pixel state changed
                    proc_output = drive_towards_input;
                    proc_bo = proc_vinnd[3] ? (
                        {proc_bi[15:12], STAGE_MONO, FASTM_B2W_FRAMES, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:12], STAGE_MONO, FASTM_W2B_FRAMES, csr_mindrv, 2'd0};
                end
                else begin
                    // Pixel state not meaningfully changed
                    proc_output = `NO_DRIVE;
                    if (pixel_framecnt == 0) begin
                        // Greyscale mode can be entered only if global counter is at last frame
                        if (al_framecnt == 0) begin
                            // Check pixel target color again, if it equals the current color,
                            // don't bother, enter DONE
                            // This could be due to a greyscale only change in the HOLD stage
                            if (pixel_prev != proc_vin)
                                proc_bo = {proc_bi[15:12], STAGE_GREY, 2'b0, pixel_prev, proc_vin};
                            else
                                proc_bo = {proc_bi[15:12], STAGE_DONE, 6'd0, pixel_prev};
                        end
                        else begin
                            proc_bo = proc_bi; // Wait
                        end
                    end
                    else begin
                        // Count down
                        proc_bo = {proc_bi[15:10], pixel_framecnt_dec, proc_bi[3:0]};
                    end
                end
            end
            else if (pixel_stage == STAGE_GREY) begin
                // In grey stage
                proc_output = proc_lut_rd;
                if (al_framecnt == 0) begin
                    // Finished refresh cycle, enter done stage
                    proc_bo = {proc_bi[15:12], STAGE_DONE, 6'd0, pixel_prev};
                end
                else begin
                    proc_bo = proc_bi;
                end
            end
            else if (pixel_stage == STAGE_DONE) begin
                // Not currently updating, display in BINARY/ GREYSCALE mode
                if (proc_vin[3:0] != pixel_prev[3:0]) begin
                    // In GREYSCALE mode, any change triggers an update, frame count depends on the delta
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        // To white, see if it's current dark grey or light grey
                        {proc_bi[15:12], STAGE_MONO, fastg_g2w_frames, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:12], STAGE_MONO, fastg_g2b_frames, csr_mindrv, 2'd0};
                end
                else begin
                    // Nothing has changed, do nothing
                    proc_output = `NO_DRIVE;
                    proc_bo = proc_bi;
                end
            end
        end
        BASEMODE_FAST_MONO: begin
            if (pixel_framecnt != 0) begin
                // Dynamic frame rate cap:
                // Once the pixel state is changed, the DYFRC field is reset to
                // the CSR val.
                // The field value is then decremented every frame until 0
                // Change to a new color is only allowed if the field is 0
                // Currently updating
                if ((proc_vin[3] != pixel_prev[0]) && (pixel_mindrv == 2'd0)) begin
                    // Pixel state changed
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:10], pixel_framecnt_2w, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:10], pixel_framecnt_2b, csr_mindrv, 2'd0};
                end
                else begin
                    // Pixel state not changed
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    proc_bo = {proc_bi[15:10], pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
                end
            end
            else begin
                // Not currently updating
                if (proc_vin[3] != pixel_prev[0]) begin
                    // Pixel state changed
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:10], FASTM_B2W_FRAMES, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:10], FASTM_W2B_FRAMES, csr_mindrv, 2'd0};
                end
                else begin
                    // Pixel state not changed
                    proc_output = `NO_DRIVE;
                    proc_bo = proc_bi;
                end
            end
        end
        BASEMODE_FAST_GREY: begin
            // Synchronized driving with reversal for grey targets (13 frames total)
            // Base MONO: 6 frames, with 0-3 overdrive frames based on dc_bias
            // B/W: MONO (6-9) + REST in HOLD (7-4) = 13 frames
            // Grey: MONO (6-9) + REVERSE (2) + SETTLE (5-2) = 13 frames
            // Frame counter encoding: [5:4]=video counter, [3:0]=stage frames
            // pixel_prev[1:0] = target (00=B, 01=DG, 10=LG, 11=W)
            // pixel_prev[3:2] = mindrv (MONO) or dc_bias (HOLD/GREY/DONE)

            if (pixel_stage == STAGE_MONO) begin
                // Drive towards binary target (MSB of grey level)
                // pixel_prev[3:2] = mindrv during MONO stage
                // pixel_prev[1:0] = target color
                proc_output = pixel_prev[1] ? `DRIVE_WHITE : `DRIVE_BLACK;
                if ((proc_vin[3] != pixel_prev[1]) && (pixel_mindrv == 2'd0)) begin
                    // Binary direction changed mid-transition - restart with MONO target (video mode)
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], STAGE_MONO, fg_counter, fg_frames_2w, csr_mindrv, proc_vin_mono}
                    ) : {proc_bi[15:12], STAGE_MONO, fg_counter, fg_frames_2b, csr_mindrv, proc_vin_mono};
                end
                else if (fg_frames == 0) begin
                    // MONO done - B/W goes to HOLD (REST), Grey goes to GREY (REVERSE+SETTLE)
                    // Calculate REST/SETTLE based on how many MONO frames we used (for overdrive)
                    // dc_bias starts at 0 when entering HOLD/GREY (overdrive already applied in MONO)
                    if (fg_is_grey_target)
                        proc_bo = {proc_bi[15:12], STAGE_GREY, fg_counter, `FASTG_REVERSE_FRAMES + `FASTG_SETTLE_FRAMES, 2'b00, proc_vin[3:2]};
                    else
                        proc_bo = {proc_bi[15:12], STAGE_HOLD, fg_counter, `FASTG_BW_REST_FRAMES, 2'b00, proc_vin[3:2]};
                end
                else begin
                    proc_bo = {proc_bi[15:12], STAGE_MONO, fg_counter, fg_frames_dec, pixel_mindrv_dec, proc_bi[1:0]};
                end
            end
            else if (pixel_stage == STAGE_HOLD) begin
                // REST for B/W targets (NO_DRIVE)
                // pixel_prev[3:2] = dc_bias (preserved from DONE, reset to 0 when entering)
                // pixel_prev[1:0] = target color
                proc_output = `NO_DRIVE;
                if (proc_vin[3] != pixel_prev[1]) begin
                    // Binary direction changed - restart MONO with mono target (video mode)
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], STAGE_MONO, fg_counter, `FASTG_MONO_FRAMES, csr_mindrv, proc_vin_mono}
                    ) : {proc_bi[15:12], STAGE_MONO, fg_counter, `FASTG_MONO_FRAMES, csr_mindrv, proc_vin_mono};
                end
                else if (fg_frames == 0) begin
                    // Enter DONE: preserve counter, set cooldown timer
                    // Use proc_vin[3:2] for color (not proc_bi) to catch same-side grey changes
                    proc_bo = {proc_bi[15:12], STAGE_DONE, fg_counter, `FASTG_VIDEO_COOLDOWN, 2'b00, proc_vin[3:2]};
                end
                else begin
                    proc_bo = {proc_bi[15:12], STAGE_HOLD, fg_counter, fg_frames_dec, proc_bi[3:0]};
                end
            end
            else if (pixel_stage == STAGE_GREY) begin
                // REVERSE drive for grey targets, then SETTLE (REST)
                // pixel_prev[3:2] = dc_bias (preserved, reset to 0 when entering from MONO)
                // pixel_prev[1]: 0=drove to black (DG), 1=drove to white (LG)
                // pixel_prev[0]: same as [1] for grey
                // Reverse: if drove black, now drive white (and vice versa)
                if (proc_vin[3] != pixel_prev[1]) begin
                    // Binary direction changed mid-grey - restart MONO with mono target (video mode)
                    proc_output = `NO_DRIVE;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], STAGE_MONO, fg_counter, `FASTG_MONO_FRAMES, csr_mindrv, proc_vin_mono}
                    ) : {proc_bi[15:12], STAGE_MONO, fg_counter, `FASTG_MONO_FRAMES, csr_mindrv, proc_vin_mono};
                end
                else if (fg_frames == 0) begin
                    // Enter DONE: preserve counter, set cooldown timer, reset dc_bias
                    proc_output = `NO_DRIVE;
                    proc_bo = {proc_bi[15:12], STAGE_DONE, fg_counter, `FASTG_VIDEO_COOLDOWN, 2'b00, proc_bi[1:0]};
                end
                else begin
                    // REVERSE for first FASTG_REVERSE_FRAMES, then SETTLE (NO_DRIVE)
                    if (fg_frames > `FASTG_SETTLE_FRAMES) begin
                        proc_output = pixel_prev[1] ? `DRIVE_BLACK : `DRIVE_WHITE;
                    end
                    else begin
                        proc_output = `NO_DRIVE;
                    end
                    proc_bo = {proc_bi[15:12], STAGE_GREY, fg_counter, fg_frames_dec, proc_bi[3:0]};
                end
            end
            else if (pixel_stage == STAGE_DONE) begin
                // fg_frames[3:1] = 111: doping mode, doping_count = {fg_counter, fg_frames[0]} (0-5)
                // fg_frames = 0-13: cooldown mode, fg_counter = video mode counter
                // pixel_prev[3:2] = dc_bias (0-3) in DONE stage
                // pixel_prev[1:0] = current color (00=B, 01=DG, 10=LG, 11=W)

                if (proc_vin[3:2] != pixel_prev[1:0]) begin
                    // Target changed - increment counter and start transition
                    proc_output = `NO_DRIVE;

                    // Video mode: 3+ changes within cooldown window, force mono
                    if (fg_video_mode) begin
                        proc_bo = proc_vin[3] ? (
                            {proc_bi[15:12], STAGE_MONO, fg_counter, mono_frames_od, csr_mindrv, proc_vin_mono}
                        ) : {proc_bi[15:12], STAGE_MONO, fg_counter, mono_frames_od, csr_mindrv, proc_vin_mono};
                    end
                    // Same-side grey transition (W→LG or B→DG): skip MONO
                    else if (fg_is_grey_target && (proc_vin[3] == pixel_prev[1])) begin
                        proc_bo = {proc_bi[15:12], STAGE_GREY, fg_counter_inc, `FASTG_REVERSE_FRAMES + `FASTG_SETTLE_FRAMES, new_dc_bias, proc_vin[3:2]};
                    end
                    else begin
                        // Different side or B/W target: need MONO with possible overdrive
                        proc_bo = proc_vin[3] ? (
                            {proc_bi[15:12], STAGE_MONO, fg_counter_inc, mono_frames_od, csr_mindrv, proc_vin[3:2]}
                        ) : {proc_bi[15:12], STAGE_MONO, fg_counter_inc, mono_frames_od, csr_mindrv, proc_vin[3:2]};
                    end
                end
                else begin
                    // No change - manage cooldown, doping mode, and global doping response

                    if (fg_in_doping_mode) begin
                        if (doping_active && doping_count_ok) begin
                            // B/W pixels only: 1 frame pulse (first frame), check dc_bias
                            // Gray pixels: NO doping (too distracting)
                            if (pixel_prev[1:0] == 2'b00 && bw_bias_ok) begin
                                // Black pixel: 1 frame pulse on first frame only
                                proc_output = doping_first_frame ? `DRIVE_BLACK : `NO_DRIVE;
                                if (doping_first_frame) begin
                                    // Increment both doping_count (3-bit) and dc_bias
                                    proc_bo = {proc_bi[15:12], STAGE_DONE, doping_count_inc[2:1], 3'b111, doping_count_inc[0],
                                        dc_bias_done + 2'd1, pixel_prev[1:0]};
                                end
                                else begin
                                    proc_bo = proc_bi;  // Keep state on non-first frames
                                end
                            end
                            else if (pixel_prev[1:0] == 2'b11 && bw_bias_ok) begin
                                // White pixel: 1 frame pulse on first frame only
                                proc_output = doping_first_frame ? `DRIVE_WHITE : `NO_DRIVE;
                                if (doping_first_frame) begin
                                    // Increment both doping_count (3-bit) and dc_bias
                                    proc_bo = {proc_bi[15:12], STAGE_DONE, doping_count_inc[2:1], 3'b111, doping_count_inc[0],
                                        dc_bias_done + 2'd1, pixel_prev[1:0]};
                                end
                                else begin
                                    proc_bo = proc_bi;  // Keep state on non-first frames
                                end
                            end
                            else if (pixel_prev[1] != pixel_prev[0]) begin
                                // Gray (01 or 10): NO doping - just stay idle
                                proc_output = `NO_DRIVE;
                                proc_bo = proc_bi;
                            end
                            else begin
                                // B/W with dc_bias maxed (bw_bias_ok=false) - no pulse, stay in doping mode
                                proc_output = `NO_DRIVE;
                                proc_bo = proc_bi;
                            end
                        end
                        else if (doping_active && doping_first_frame && (doping_count == 3'd5) && (dc_bias_done != 2'd0)) begin
                            // Doping complete (count=5), decay dc_bias by 1 per cycle
                            proc_output = `NO_DRIVE;
                            proc_bo = {proc_bi[15:12], STAGE_DONE, doping_count[2:1], 3'b111, doping_count[0],
                                dc_bias_done - 2'd1, pixel_prev[1:0]};
                        end
                        else begin
                            // In doping mode but not active or fully decayed - stay idle
                            proc_output = `NO_DRIVE;
                            proc_bo = proc_bi;
                        end
                    end
                    else if (fg_truly_idle && doping_first_frame) begin
                        // Truly idle and doping cycle starting - enter doping mode and pulse
                        // Only enter on first frame to avoid sitting idle in doping mode
                        // B/W only - gray pixels don't enter doping mode (too distracting)
                        if (pixel_prev[1:0] == 2'b00) begin
                            // Black: first doping pulse if dc_bias not maxed
                            if (dc_bias_done != `DC_BIAS_MAX) begin
                                proc_output = `DRIVE_BLACK;
                                // Enter doping mode with count=1: {fg_counter=00, fg_frames=15}
                                proc_bo = {proc_bi[15:12], STAGE_DONE, 2'd0, 4'd15,
                                    dc_bias_done + 2'd1, pixel_prev[1:0]};
                            end
                            else begin
                                // dc_bias maxed, enter doping mode with count=5 (skip to decay)
                                // count=5: {fg_counter=10, fg_frames=15}
                                proc_output = `NO_DRIVE;
                                proc_bo = {proc_bi[15:12], STAGE_DONE, 2'd2, 4'd15, proc_bi[3:0]};
                            end
                        end
                        else if (pixel_prev[1:0] == 2'b11) begin
                            // White: first doping pulse if dc_bias not maxed
                            if (dc_bias_done != `DC_BIAS_MAX) begin
                                proc_output = `DRIVE_WHITE;
                                // Enter doping mode with count=1: {fg_counter=00, fg_frames=15}
                                proc_bo = {proc_bi[15:12], STAGE_DONE, 2'd0, 4'd15,
                                    dc_bias_done + 2'd1, pixel_prev[1:0]};
                            end
                            else begin
                                // dc_bias maxed, enter doping mode with count=5 (skip to decay)
                                // count=5: {fg_counter=10, fg_frames=15}
                                proc_output = `NO_DRIVE;
                                proc_bo = {proc_bi[15:12], STAGE_DONE, 2'd2, 4'd15, proc_bi[3:0]};
                            end
                        end
                        else begin
                            // Gray (01 or 10): NO doping - stay idle, don't enter doping mode
                            proc_output = `NO_DRIVE;
                            proc_bo = proc_bi;
                        end
                    end
                    else if (fg_truly_idle && doping_active) begin
                        // Truly idle but not first frame - wait for next doping cycle
                        proc_output = `NO_DRIVE;
                        proc_bo = proc_bi;
                    end
                    else if (fg_frames != 4'd0) begin
                        // Cooldown active (not doping mode since fg_frames != 15), decrement
                        proc_output = `NO_DRIVE;
                        proc_bo = {proc_bi[15:12], STAGE_DONE, fg_counter, fg_frames_dec, proc_bi[3:0]};
                    end
                    else if (fg_counter != 2'd0) begin
                        // Cooldown expired, decrement counter and reset cooldown
                        proc_output = `NO_DRIVE;
                        proc_bo = {proc_bi[15:12], STAGE_DONE, fg_counter_dec, `FASTG_VIDEO_COOLDOWN, proc_bi[3:0]};
                    end
                    else begin
                        // Truly idle, waiting for doping_active
                        proc_output = `NO_DRIVE;
                        proc_bo = proc_bi;
                    end
                end
            end
        end
        endcase

        // If set mode is active, override previous
        if (set_mode_apply) begin
            // Use the initial state preset
            proc_bo = `DEFAULT_MODE; // Default
            case (op_param)
            `SETMODE_MANUAL_LUT_NO_DITHER:
                proc_bo = {MODE_MANUAL_LUT_NO_DITHER, 4'd0, 6'd0, 4'd15};
            `SETMODE_MANUAL_LUT_BLUE_NOISE:
                proc_bo = {MODE_MANUAL_LUT_BLUE_NOISE, 4'd0, 6'd0, 4'd15};
            `SETMODE_FAST_MONO_NO_DITHER:
                proc_bo = `INIT_FAST_MONO_ND;
            `SETMODE_FAST_MONO_BAYER:
                proc_bo = `INIT_FAST_MONO_BD;
            `SETMODE_FAST_MONO_BLUE_NOISE:
                proc_bo = `INIT_FAST_MONO_BN;
            `SETMODE_FAST_GREY:
                proc_bo = `INIT_FAST_GREY;
            `SETMODE_AUTO_LUT_NO_DITHER:
                proc_bo = `INIT_AUTO_LUT_ND;
            `SETMODE_AUTO_LUT_BLUE_NOISE:
                proc_bo = `INIT_AUTO_LUT_OD;
            `SETMODE_FAST_MONO_R2:
                proc_bo = `INIT_FAST_MONO_R2;
            default: begin
                // Invalid input detected, default back to manual lut
                proc_bo = {MODE_MANUAL_LUT_NO_DITHER, 4'd0, 6'd0, 4'd15};
                $display("Invalid set mode");
            end
            endcase
        end

        // If in init mode, override previous
        if (op_state == `OP_INIT) begin
            // one round is 128 clock cycle [6:0], but down counting
            // 6543210
            // x111xxx - 0-7 / 64-71 noop
            // 1xxxxxx - 8-63 black
            // 0xxxxxx - 72-127 white
            if (op_framecnt[3:1] == 3'b111)
                proc_output = `NO_DRIVE;
            else if (op_framecnt[4] == 1'b1)
                proc_output = `DRIVE_BLACK;
            else
                proc_output = `DRIVE_WHITE;
            // Set initial mode
            proc_bo = `DEFAULT_MODE;
        end
    end

endmodule
`default_nettype wire

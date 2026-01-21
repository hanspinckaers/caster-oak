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
    input  wire        doping_pulse,   // Global doping pulse (1 frame every ~5 sec)
    input  wire        frame_skip_input, // Ignore new input this frame (halve input rate)
    input  wire [1:0]  cfa_color       // CFA color: 00=Blue, 01=White, 10=Green, 11=Red
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
    localparam FASTM_W2B_FRAMES = 6'd6;

    // FAST_MONO doping marker: [11:10] = 10 means in doping sequence
    localparam [1:0] FASTM_DOPING_MARKER = 2'b10;
    // FAST_MONO cooldown after transition before doping eligibility (same as FAST_GREY)
    localparam [3:0] FASTM_DOPING_COOLDOWN = 4'd8;

    // Video mode: full drive frames, but skip reverse/grey stage
    localparam FASTV_B2W_FRAMES = 4'd7;     // Video mode: same as normal B→W
    localparam FASTV_W2B_FRAMES = 4'd6;     // Video mode: same as normal W→B

    // FAST_GREY timing (synchronized: B/W=7+5=12, Grey=7+2+3=12)
    localparam FASTG_BW_REST_FRAMES = 6'd5;  // REST for B/W after MONO
    localparam FASTG_B2G_FRAMES = 6'd2;      // Reverse frames for grey (black side)
    localparam FASTG_W2G_FRAMES = 6'd2;      // Reverse frames for grey (white side)
    localparam FASTG_SETTLE_FRAMES = 6'd3;   // REST for grey after reverse
    localparam [3:0] FASTG_VIDEO_COOLDOWN = 4'd8; // Frames before counter decays (4-bit, max 15)

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

    // FAST_MONO doping state decode
    wire fm_doping_mode = (proc_bi[11:10] == FASTM_DOPING_MARKER);
    wire fm_cooldown_mode = (proc_bi[11:10] == 2'b01);
    wire [3:0] fm_cooldown = pixel_framecnt[3:0];
    wire [1:0] fm_dc_bias = pixel_mindrv;  // Reuse as dc_bias when idle
    wire fm_doping_done = pixel_prev[1];   // bit 1 = doping phase (0=needs, 1=done)

    // =========================================================================
    // FAST_GREY Physics-Based Position Tracking
    // =========================================================================
    //
    // PIXEL STATE WORD (proc_bo/proc_bi) bit layout:
    //   [15:12] - Mode (4 bits)
    //   [11:7]  - Position (5 bits, 0-16)
    //   [6]     - Reserved
    //   [5:4]   - Reserved
    //   [3:2]   - Reserved
    //   [1:0]   - Target (2 bits: B=00, DG=01, LG=10, W=11)
    //
    // Position scale: 0=black, 5=dark grey, 11=light grey, 16=white
    // Drive uses position-dependent LUTs for asymmetric e-ink physics
    //
    // =========================================================================

    // FAST_GREY physics-based state decode
    wire [4:0] phys_position = proc_bi[11:7];
    wire [1:0] phys_target = proc_vin[3:2];

    // Target positions (from defines.vh)
    wire [4:0] phys_target_pos;
    assign phys_target_pos =
        (phys_target == 2'b00) ? `POS_BLACK :
        (phys_target == 2'b01) ? `POS_DARK_GREY :
        (phys_target == 2'b10) ? `POS_LIGHT_GREY :
        `POS_WHITE;

    // Position-dependent step sizes via LUT (indexed by current position)
    // Toward white: fast at black (pos 0-1), slowing down near white
    reg [2:0] phys_pos_change_w;
    always @(*) begin
        case (phys_position)
        5'd0, 5'd1: phys_pos_change_w = 3'd5;
        5'd2, 5'd3, 5'd4: phys_pos_change_w = 3'd4;
        5'd5, 5'd6, 5'd7, 5'd8: phys_pos_change_w = 3'd3;
        5'd9, 5'd10, 5'd11, 5'd12: phys_pos_change_w = 3'd2;
        5'd13, 5'd14, 5'd15, 5'd16: phys_pos_change_w = 3'd1;
        default: phys_pos_change_w = 3'd2;
        endcase
    end

    // Toward black: slow near black, accelerating toward white
    reg [2:0] phys_pos_change_b;
    always @(*) begin
        case (phys_position)
        5'd0, 5'd1, 5'd2, 5'd3: phys_pos_change_b = 3'd1;
        5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10, 5'd11: phys_pos_change_b = 3'd2;
        5'd12, 5'd13: phys_pos_change_b = 3'd4;
        5'd14, 5'd15, 5'd16: phys_pos_change_b = 3'd5;
        default: phys_pos_change_b = 3'd3;
        endcase
    end

    // Drive decision
    wire phys_at_target = (phys_position == phys_target_pos);
    wire phys_need_drive = !phys_at_target;
    wire phys_drive_toward_white = phys_need_drive && (phys_target_pos > phys_position);
    wire phys_drive_toward_black = phys_need_drive && (phys_target_pos < phys_position);

    // Calculate new position (clamped to target to prevent overshoot)
    wire [4:0] phys_new_position_w_raw = phys_position + {2'b0, phys_pos_change_w};
    wire [4:0] phys_new_position_b_raw = phys_position - {2'b0, phys_pos_change_b};
    wire phys_underflow = (phys_position < {2'b0, phys_pos_change_b});

    wire [4:0] phys_new_position_w = (phys_new_position_w_raw > phys_target_pos) ?
                                      phys_target_pos : phys_new_position_w_raw;
    wire [4:0] phys_new_position_b = phys_underflow ? 5'd0 :
                                      ((phys_new_position_b_raw < phys_target_pos) ?
                                       phys_target_pos : phys_new_position_b_raw);

    wire [4:0] phys_new_position = phys_drive_toward_white ? phys_new_position_w :
                                    phys_drive_toward_black ? phys_new_position_b :
                                    phys_position;

    // Check if at extreme positions for doping
    wire phys_at_black = (phys_position == `POS_BLACK);
    wire phys_at_white = (phys_position == `POS_WHITE);
    wire phys_at_extreme = phys_at_black || phys_at_white;

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
            // FAST_MONO with per-pixel doping (same as FAST_GREY)
            // State encoding:
            //   [11:10] = 00: Normal (transitioning if framecnt>0, fully idle if framecnt==0)
            //   [11:10] = 01: Cooldown after transition (framecnt[3:0] = cooldown timer)
            //   [11:10] = 10: In doping sequence (framecnt[3:0] = doping countdown)
            //   [9:4] = frame counter or timer
            //   [3:2] = mindrv (transition) or doping phase: 00=needs, 01=in progress, 10=done
            //   [1:0] = {reserved, prev_pixel}

            if (pixel_framecnt != 0 && !fm_doping_mode && !fm_cooldown_mode) begin
                // Currently transitioning
                if ((proc_vin[3] != pixel_prev[0]) && (pixel_mindrv == 2'd0)) begin
                    // Pixel state changed mid-transition
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], 2'b00, pixel_framecnt_2w, csr_mindrv, 2'd1}
                    ) : {proc_bi[15:12], 2'b00, pixel_framecnt_2b, csr_mindrv, 2'd0};
                end
                else if (pixel_framecnt == 6'd1) begin
                    // Last frame of transition - enter cooldown, reset doping phase
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    proc_bo = {proc_bi[15:12], 2'b01, 2'b00, FASTM_DOPING_COOLDOWN, 2'b00, proc_bi[1:0]};
                end
                else begin
                    // Continue driving
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    proc_bo = {proc_bi[15:12], 2'b00, pixel_framecnt_dec, pixel_mindrv_dec, proc_bi[1:0]};
                end
            end
            else if (fm_cooldown_mode) begin
                // In cooldown after transition
                if (proc_vin[3] != pixel_prev[0]) begin
                    // Pixel state changed during cooldown - start new transition
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], 2'b00, FASTM_B2W_FRAMES, csr_mindrv, 2'b01}
                    ) : {proc_bi[15:12], 2'b00, FASTM_W2B_FRAMES, csr_mindrv, 2'b00};
                end
                else if (fm_cooldown > 4'd1) begin
                    // Cooldown countdown
                    proc_output = `NO_DRIVE;
                    proc_bo = {proc_bi[15:12], 2'b01, 2'b00, fm_cooldown - 4'd1, proc_bi[3:0]};
                end
                else begin
                    // Cooldown done - become fully idle
                    proc_output = `NO_DRIVE;
                    proc_bo = {proc_bi[15:12], 2'b00, 6'd0, proc_bi[3:0]};
                end
            end
            else if (fm_doping_mode) begin
                // In per-pixel doping sequence
                if (proc_vin[3] != pixel_prev[0]) begin
                    // Pixel state changed during doping - start new transition
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], 2'b00, FASTM_B2W_FRAMES, csr_mindrv, 2'b01}
                    ) : {proc_bi[15:12], 2'b00, FASTM_W2B_FRAMES, csr_mindrv, 2'b00};
                end
                else if (fm_cooldown > 4'd1) begin
                    // Doping countdown - drive pixel
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    proc_bo = {proc_bi[15:12], 2'b10, 2'b00, fm_cooldown - 4'd1, proc_bi[3:0]};
                end
                else if (fm_cooldown == 4'd1) begin
                    // Final frame of doping - drive and advance phase
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    if (pixel_mindrv == 2'b00)
                        // First phase done -> second phase (wait 8 frames then dope again)
                        proc_bo = {proc_bi[15:12], 2'b10, 2'b00, 4'd8, 2'b01, proc_bi[1:0]};
                    else
                        // Second phase done -> mark done, go idle
                        proc_bo = {proc_bi[15:12], 2'b00, 6'd0, 2'b10, proc_bi[1:0]};
                end
                else begin
                    // fm_cooldown == 0: between doping phases, start second phase
                    proc_output = `NO_DRIVE;
                    if (pixel_mindrv == 2'b01)
                        // Start second doping phase
                        proc_bo = pixel_prev[0] ?
                            {proc_bi[15:12], 2'b10, 2'b00, 4'd2, 2'b01, proc_bi[1:0]} :
                            {proc_bi[15:12], 2'b10, 2'b00, 4'd4, 2'b01, proc_bi[1:0]};
                    else
                        // Already done, go idle
                        proc_bo = {proc_bi[15:12], 2'b00, 6'd0, 2'b10, proc_bi[1:0]};
                end
            end
            else begin
                // Fully idle (framecnt == 0, not in cooldown or doping)
                if (proc_vin[3] != pixel_prev[0]) begin
                    // Pixel state changed - start transition, reset doping phase
                    proc_output = drive_towards_input;
                    proc_bo = proc_vin[3] ? (
                        {proc_bi[15:12], 2'b00, FASTM_B2W_FRAMES, csr_mindrv, 2'b01}
                    ) : {proc_bi[15:12], 2'b00, FASTM_W2B_FRAMES, csr_mindrv, 2'b00};
                end
                else if (doping_pulse) begin
                    // Global pulse: 1-frame drive for all idle pixels
                    proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;
                    proc_bo = proc_bi;
                end
                else if (pixel_mindrv == 2'b00) begin
                    // Needs doping (phase=00): start per-pixel sequence
                    // Black gets 4 frames, White gets 2 frames
                    proc_output = `NO_DRIVE;
                    proc_bo = pixel_prev[0] ?
                        {proc_bi[15:12], 2'b10, 2'b00, 4'd2, 2'b00, proc_bi[1:0]} :
                        {proc_bi[15:12], 2'b10, 2'b00, 4'd4, 2'b00, proc_bi[1:0]};
                end
                else begin
                    // Already doped (phase=10) or in progress - stay idle
                    proc_output = `NO_DRIVE;
                    proc_bo = proc_bi;
                end
            end
        end
        BASEMODE_FAST_GREY: begin
            // Physics-based position tracking with LUT-based asymmetric steps
            // State: [11:7]=position (0-16), [1:0]=target (B/DG/LG/W)
            // Simple: just drive toward target, no doping

            if (phys_need_drive) begin
                // Driving toward target - update position
                if (phys_drive_toward_white) begin
                    proc_output = `DRIVE_WHITE;
                    proc_bo = {proc_bi[15:12], phys_new_position, proc_bi[6:2], phys_target};
                end
                else begin
                    proc_output = `DRIVE_BLACK;
                    proc_bo = {proc_bi[15:12], phys_new_position, proc_bi[6:2], phys_target};
                end
            end
            else begin
                // At target - idle, no doping
                proc_output = `NO_DRIVE;
                proc_bo = {proc_bi[15:12], phys_position, proc_bi[6:2], phys_target};
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

        // DEBUG: Video detection disabled
        // if (neighbor_video)
        //     proc_output = `DRIVE_BLACK;
    end

endmodule
`default_nettype wire

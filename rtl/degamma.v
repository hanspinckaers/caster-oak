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
// degamma.v
// Shadow boost with highlight protection
// ~1.5x gain in shadows, soft-knee compression to protect highlights
//
`default_nettype none
`timescale 1ns / 1ps
module degamma(
    input wire [5:0] in,
    output reg [7:0] out
);

    // Shadow boost (~1.5x) with soft-knee highlight compression
    // Shadows lifted significantly, highlights compressed to avoid blowout
    always @(in) begin
        case (in)
        // True black stays black
        6'd0: out = 8'd0;
        // Shadows: strong lift (was 0-11, now 5-35)
        6'd1: out = 8'd5;
        6'd2: out = 8'd8;
        6'd3: out = 8'd11;
        6'd4: out = 8'd14;
        6'd5: out = 8'd17;
        6'd6: out = 8'd20;
        6'd7: out = 8'd23;
        6'd8: out = 8'd26;
        6'd9: out = 8'd29;
        6'd10: out = 8'd32;
        6'd11: out = 8'd35;
        // Low-mids: ~1.5x gain (was 7-20, now 38-60)
        6'd12: out = 8'd38;
        6'd13: out = 8'd42;
        6'd14: out = 8'd46;
        6'd15: out = 8'd50;
        6'd16: out = 8'd54;
        6'd17: out = 8'd58;
        6'd18: out = 8'd62;
        6'd19: out = 8'd66;
        6'd20: out = 8'd70;
        // Mids: ~1.4x gain, starting to taper (was 23-54, now 74-108)
        6'd21: out = 8'd74;
        6'd22: out = 8'd78;
        6'd23: out = 8'd82;
        6'd24: out = 8'd86;
        6'd25: out = 8'd90;
        6'd26: out = 8'd94;
        6'd27: out = 8'd98;
        6'd28: out = 8'd102;
        6'd29: out = 8'd106;
        6'd30: out = 8'd110;
        6'd31: out = 8'd114;
        // Upper-mids: ~1.3x tapering (was 57-99, now 118-148)
        6'd32: out = 8'd118;
        6'd33: out = 8'd122;
        6'd34: out = 8'd126;
        6'd35: out = 8'd130;
        6'd36: out = 8'd134;
        6'd37: out = 8'd138;
        6'd38: out = 8'd142;
        6'd39: out = 8'd146;
        6'd40: out = 8'd150;
        6'd41: out = 8'd154;
        // Highlights: soft compression (was 105-160, now 158-190)
        6'd42: out = 8'd158;
        6'd43: out = 8'd162;
        6'd44: out = 8'd166;
        6'd45: out = 8'd170;
        6'd46: out = 8'd174;
        6'd47: out = 8'd178;
        6'd48: out = 8'd182;
        6'd49: out = 8'd186;
        6'd50: out = 8'd190;
        6'd51: out = 8'd194;
        // Bright highlights: gentle rolloff to 255 (was 167-255, now 198-255)
        6'd52: out = 8'd198;
        6'd53: out = 8'd203;
        6'd54: out = 8'd208;
        6'd55: out = 8'd213;
        6'd56: out = 8'd218;
        6'd57: out = 8'd223;
        6'd58: out = 8'd228;
        6'd59: out = 8'd234;
        6'd60: out = 8'd240;
        6'd61: out = 8'd246;
        6'd62: out = 8'd251;
        6'd63: out = 8'd255;
        endcase
    end

endmodule
`default_nettype wire

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
// Hybrid gamma curve for e-ink display:
// - Shadows/mids: gamma ~1.5 for brightness
// - Highlights: steeper curve for better differentiation
//
`default_nettype none
`timescale 1ns / 1ps
module degamma(
    input wire [5:0] in,
    output reg [7:0] out
);

    // Hybrid curve: gamma 1.5 for in<48, then stretched highlights
    // Keeps bright midtones while expanding highlight dynamic range
    always @(in) begin
        case (in)
        // Shadows: gamma 1.5 (unchanged)
        6'd0: out = 8'd0;
        6'd1: out = 8'd1;
        6'd2: out = 8'd1;
        6'd3: out = 8'd3;
        6'd4: out = 8'd4;
        6'd5: out = 8'd6;
        6'd6: out = 8'd8;
        6'd7: out = 8'd9;
        6'd8: out = 8'd12;
        6'd9: out = 8'd14;
        6'd10: out = 8'd16;
        6'd11: out = 8'd19;
        6'd12: out = 8'd21;
        6'd13: out = 8'd24;
        6'd14: out = 8'd27;
        6'd15: out = 8'd30;
        // Mids: gamma 1.5 (unchanged)
        6'd16: out = 8'd33;
        6'd17: out = 8'd36;
        6'd18: out = 8'd39;
        6'd19: out = 8'd42;
        6'd20: out = 8'd46;
        6'd21: out = 8'd49;
        6'd22: out = 8'd53;
        6'd23: out = 8'd56;
        6'd24: out = 8'd60;
        6'd25: out = 8'd64;
        6'd26: out = 8'd68;
        6'd27: out = 8'd72;
        6'd28: out = 8'd76;
        6'd29: out = 8'd80;
        6'd30: out = 8'd84;
        6'd31: out = 8'd88;
        6'd32: out = 8'd92;
        6'd33: out = 8'd97;
        6'd34: out = 8'd101;
        6'd35: out = 8'd106;
        6'd36: out = 8'd110;
        6'd37: out = 8'd115;
        6'd38: out = 8'd119;
        6'd39: out = 8'd124;
        6'd40: out = 8'd129;
        6'd41: out = 8'd134;
        6'd42: out = 8'd139;
        6'd43: out = 8'd144;
        6'd44: out = 8'd149;
        6'd45: out = 8'd154;
        6'd46: out = 8'd159;
        6'd47: out = 8'd164;
        // Highlights: compressed to expand range (48-63 maps to 168-255)
        // More steps in output for better highlight differentiation
        6'd48: out = 8'd168;
        6'd49: out = 8'd173;
        6'd50: out = 8'd178;
        6'd51: out = 8'd183;
        6'd52: out = 8'd188;
        6'd53: out = 8'd194;
        6'd54: out = 8'd200;
        6'd55: out = 8'd206;
        6'd56: out = 8'd212;
        6'd57: out = 8'd220;
        6'd58: out = 8'd228;
        6'd59: out = 8'd236;
        6'd60: out = 8'd244;
        6'd61: out = 8'd250;
        6'd62: out = 8'd253;
        6'd63: out = 8'd255;
        endcase
    end

endmodule
`default_nettype wire

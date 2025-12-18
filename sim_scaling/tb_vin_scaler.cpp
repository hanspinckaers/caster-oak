// Testbench for vin_scaler_2x module
// Simulates the 2x integer scaling for video input
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vvin_scaler_2x.h"

#define INPUT_WIDTH 16    // Test with small width: 16 pixels = 8 pixel groups
#define INPUT_HEIGHT 8
#define TRACE

Vvin_scaler_2x *dut;
VerilatedVcdC *trace;
uint64_t tickcount = 0;

double sc_time_stamp() { return tickcount; }

void tick_in() {
    dut->clk_in = 1;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10);
#endif
    dut->clk_in = 0;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10 + 5);
#endif
    tickcount++;
}

void tick_both() {
    // Tick both clocks (clk_out runs at 2x clk_in)
    dut->clk_in = 1;
    dut->clk_out = 1;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10);
#endif
    
    dut->clk_out = 0;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10 + 2);
#endif
    
    dut->clk_out = 1;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10 + 4);
#endif
    
    dut->clk_in = 0;
    dut->clk_out = 0;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10 + 6);
#endif
    
    dut->clk_out = 1;
    dut->eval();
#ifdef TRACE
    trace->dump(tickcount * 10 + 8);
#endif
    
    tickcount++;
}

void reset() {
    dut->rst = 1;
    dut->scaling_en = 1;
    dut->vsync = 0;
    dut->width = INPUT_WIDTH / 2;  // Width in 2-pixel groups
    dut->pix_in = 0;
    dut->pix_in_valid = 0;
    dut->pix_out_ready = 1;
    
    for (int i = 0; i < 10; i++) tick_both();
    
    dut->rst = 0;
}

void send_vsync() {
    dut->vsync = 1;
    for (int i = 0; i < 5; i++) tick_both();
    dut->vsync = 0;
}

void send_line(int line_num) {
    printf("Sending line %d\n", line_num);
    
    for (int x = 0; x < INPUT_WIDTH / 2; x++) {
        // Send 2 pixels per clock
        uint8_t pix0 = (line_num * 16 + x * 2) & 0xFF;
        uint8_t pix1 = (line_num * 16 + x * 2 + 1) & 0xFF;
        dut->pix_in = (pix1 << 8) | pix0;
        dut->pix_in_valid = 1;
        
        tick_both();
        
        // Wait if not ready
        int timeout = 100;
        while (!dut->pix_in_ready && timeout-- > 0) {
            tick_both();
        }
        if (timeout <= 0) {
            printf("ERROR: pix_in_ready timeout at line %d, x=%d\n", line_num, x);
        }
    }
    dut->pix_in_valid = 0;
    
    // Some blanking time
    for (int i = 0; i < 20; i++) tick_both();
}

void receive_output() {
    int output_count = 0;
    int expected = INPUT_WIDTH * INPUT_HEIGHT * 4;  // 2x in each dimension = 4x pixels
    
    printf("\nReceiving output (expecting %d pixels in %d groups):\n", expected, expected/4);
    
    while (output_count < expected / 4 && tickcount < 100000) {
        tick_both();
        
        if (dut->pix_out_valid && dut->pix_out_ready) {
            uint32_t pixels = dut->pix_out;
            uint8_t p0 = (pixels >> 0) & 0xFF;
            uint8_t p1 = (pixels >> 8) & 0xFF;
            uint8_t p2 = (pixels >> 16) & 0xFF;
            uint8_t p3 = (pixels >> 24) & 0xFF;
            
            printf("Out[%4d]: %02x %02x %02x %02x\n", output_count, p0, p1, p2, p3);
            output_count++;
        }
    }
    
    printf("\nReceived %d output groups (expected %d)\n", output_count, expected/4);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    
    dut = new Vvin_scaler_2x;
    Verilated::traceEverOn(true);
    
#ifdef TRACE
    trace = new VerilatedVcdC;
    dut->trace(trace, 99);
    trace->open("scaling_trace.vcd");
#endif
    
    printf("=== VIN Scaler 2x Testbench ===\n");
    printf("Input: %d x %d\n", INPUT_WIDTH, INPUT_HEIGHT);
    printf("Output: %d x %d (2x scaled)\n", INPUT_WIDTH * 2, INPUT_HEIGHT * 2);
    printf("Width param: %d (pixel groups)\n\n", INPUT_WIDTH / 2);
    
    reset();
    
    // Send a frame
    send_vsync();
    
    for (int y = 0; y < INPUT_HEIGHT; y++) {
        send_line(y);
    }
    
    // Run some more cycles to let output drain
    printf("\nDraining output...\n");
    for (int i = 0; i < 500; i++) {
        tick_both();
        
        if (dut->pix_out_valid) {
            uint32_t pixels = dut->pix_out;
            uint8_t p0 = (pixels >> 0) & 0xFF;
            uint8_t p1 = (pixels >> 8) & 0xFF;
            uint8_t p2 = (pixels >> 16) & 0xFF;
            uint8_t p3 = (pixels >> 24) & 0xFF;
            printf("Out: %02x %02x %02x %02x (valid=%d vsync=%d)\n", 
                   p0, p1, p2, p3, dut->pix_out_valid, dut->vsync_out);
        }
    }
    
    printf("\n=== Simulation complete ===\n");
    printf("Total ticks: %lu\n", tickcount);
    
#ifdef TRACE
    trace->close();
    printf("Trace saved to scaling_trace.vcd\n");
#endif
    
    delete dut;
    return 0;
}

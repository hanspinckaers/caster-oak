# DC Bias Tracking and Dynamic Overdrive Plan

## Overview

Track per-pixel DC bias from global doping pulses in FAST_GREY mode. Apply dynamic overdrive (1–3 frames) when driving in the opposite direction to compensate for accumulated bias. Total transition time is 13 frames with overdrive trading off against settle time.

## Goals

1. Global doping schedule with 1 second minimum wait between cycles
2. Track `dc_bias` per pixel (2 bits, 0–3 levels) within existing 16-bit state
3. Apply dynamic overdrive when switching direction to compensate
4. Gray pixels use balanced doping (2-frame extreme + 2-frame reverse) — no bias accumulation
5. B/W pixels accumulate bias from doping, compensated by overdrive
6. Keep total transition time constant at 13 frames

## Storage: Existing 16-bit State

Reuse bits [3:2] in FAST_GREY pixel state for dc_bias tracking.

### FAST_GREY State Layout

```
[15:12] - Mode (1011 = FAST_GREY)
[11:10] - Stage (DONE=0, MONO=1, HOLD=2, GREY=3)
[9:4]   - Frame counter: [5:4]=fg_counter, [3:0]=fg_frames
[3:2]   - dc_bias (in HOLD/GREY/DONE) or mindrv (in MONO)
[1:0]   - Target level (00=B, 01=DG, 10=LG, 11=W)
```

### Bits [3:2] Usage by Stage

| Stage | Use |
|-------|-----|
| MONO | mindrv (dynamic rate cap, unchanged) |
| HOLD | dc_bias |
| GREY | dc_bias |
| DONE | dc_bias |

### No Memory/FIFO Changes

- Storage remains 16 bits/pixel
- 4 pixels/clock processing unchanged
- No timing parameter changes

## Transition Timing (13 frames total)

### B/W Path: MONO + REST

| dc_bias | Overdrive | MONO | REST | Total |
|---------|-----------|------|------|-------|
| 0 | 0 | 6 | 7 | 13 |
| 1 | 1 | 7 | 6 | 13 |
| 2 | 2 | 8 | 5 | 13 |
| 3 | 3 | 9 | 4 | 13 |

### Gray Path: MONO + REVERSE + SETTLE

| dc_bias | Overdrive | MONO | REVERSE | SETTLE | Total |
|---------|-----------|------|---------|--------|-------|
| 0 | 0 | 6 | 2 | 5 | 13 |
| 1 | 1 | 7 | 2 | 4 | 13 |
| 2 | 2 | 8 | 2 | 3 | 13 |
| 3 | 3 | 9 | 2 | 2 | 13 |

REVERSE stays fixed at 2 frames (determines gray level).
Even max overdrive keeps 2 frames settle for gray stability.

## Global Doping Schedule

Managed in `caster.v` with two signals to pixel_processing:

| Signal | Width | Description |
|--------|-------|-------------|
| `doping_active` | 1 bit | Doping sequence in progress |
| `doping_phase` | 1 bit | 0 = extreme drive, 1 = reverse drive |

### Doping Sequence (4 frames total)

```
Frame 0-1: doping_active=1, doping_phase=0 (extreme)
Frame 2-3: doping_active=1, doping_phase=1 (reverse)
Frame 4+:  doping_active=0, wait ~25 frames (1 sec) before next cycle
```

### Doping Eligibility

A pixel only participates in doping when **truly idle**: `fg_counter == 0 && fg_frames == 0`.

This ensures ~1 second minimum wait after any transition before doping:
- After transition, pixel enters DONE with `fg_counter=1+`, `fg_frames=13`
- Cooldown counts down, resets for each counter decrement
- Time to truly idle: 13 × 2 = 26 frames (~1.04 sec) minimum

This reuses the existing video mode cooldown mechanism for doping immunity.

### Per-Pixel Doping Response (when eligible)

| Pixel | Phase 0 (extreme) | Phase 1 (reverse) | dc_bias change |
|-------|-------------------|-------------------|----------------|
| B (00) | DRIVE_BLACK | DRIVE_BLACK | +1 (saturate at 3) |
| DG (01) | DRIVE_BLACK | DRIVE_WHITE | 0 (balanced) |
| LG (10) | DRIVE_WHITE | DRIVE_BLACK | 0 (balanced) |
| W (11) | DRIVE_WHITE | DRIVE_WHITE | +1 (saturate at 3) |

Gray pixels follow the phase (extreme then reverse), staying DC-balanced.
B/W pixels ignore the phase (same direction both phases), accumulating bias.
Pixels not truly idle (cooldown active) output NO_DRIVE during doping.

## DC Bias Encoding

2-bit unsigned in bits [3:2]:

| Value | Meaning | Overdrive when switching |
|-------|---------|--------------------------|
| 0 | No bias | 0 frames |
| 1 | Weak bias | 1 frame |
| 2 | Medium bias | 2 frames |
| 3 | Strong bias | 3 frames |

Bias direction is implicit: always toward the color that received doping (tracked in `pixel_prev[1]`).

## Update Rules

| Event | dc_bias Change |
|-------|----------------|
| B/W doping cycle | +1 (saturate at 3) |
| Gray doping cycle | 0 (balanced) |
| Overdrive applied | reset to 0 |
| Mode init / reset | 0 |

## Dynamic Overdrive

When starting MONO transition in opposite direction from `pixel_prev[1]`:

```verilog
// At DONE->MONO or HOLD->MONO transition
wire [1:0] dc_bias = pixel_prev[3:2];  // In DONE/HOLD, [3:2] is dc_bias
wire switching_direction = (proc_vin[3] != pixel_prev[1]);

if (switching_direction) begin
    // Apply overdrive: add dc_bias frames to MONO, subtract from REST/SETTLE
    mono_frames = 6 + dc_bias;
    if (fg_is_grey_target)
        settle_frames = 5 - dc_bias;  // REVERSE stays at 2
    else
        rest_frames = 7 - dc_bias;
    new_dc_bias = 0;  // Reset after applying
end else begin
    // Same direction - no overdrive
    mono_frames = 6;
    rest_frames = 7;  // or settle_frames = 5
    // dc_bias preserved
end
```

## Files to Modify

### 1. `rtl/defines.vh`

Update timing constants:

```verilog
// FAST_GREY timing (13 frames total)
`define FASTG_MONO_FRAMES       4'd6    // Base MONO duration
`define FASTG_BW_REST_FRAMES    4'd7    // REST for B/W after MONO
`define FASTG_REVERSE_FRAMES    4'd2    // REVERSE for gray (determines gray level)
`define FASTG_SETTLE_FRAMES     4'd5    // SETTLE for gray after reverse
`define FASTG_VIDEO_COOLDOWN    4'd13   // Cooldown in DONE (was 8, now 13 for ~1 sec doping immunity)

// Global doping
`define DOPING_EXTREME_FRAMES   2'd2    // Frames in extreme phase
`define DOPING_REVERSE_FRAMES   2'd2    // Frames in reverse phase
`define DOPING_WAIT_FRAMES      6'd25   // ~1 sec at 25fps between doping cycles

// DC bias
`define DC_BIAS_MAX             2'd3
`define OVERDRIVE_MAX           2'd3
```

### 2. `rtl/caster.v`

Add global doping timer and signals:

```verilog
// Global doping state
reg [5:0] doping_wait_counter;
reg [2:0] doping_frame_counter;
reg doping_active;
reg doping_phase;

// Doping state machine:
// - When all pixels idle (or periodic timer), start doping
// - Count 2 frames extreme (phase=0), 2 frames reverse (phase=1)
// - Wait 25+ frames before next cycle
```

Wire `doping_active` and `doping_phase` to all pixel_processing instances.

### 3. `rtl/pixel_processing.v`

Add ports:

```verilog
input wire doping_active,
input wire doping_phase,
```

#### Changes to FAST_GREY logic:

1. **Remove per-pixel doping logic** — delete fg_counter=2 mechanism (lines ~534-608)

2. **Update STAGE_DONE** — respond to global doping:
```verilog
if (doping_active) begin
    // Output drive based on pixel color and phase
    if (pixel_prev[1:0] == 2'b00) // Black
        proc_output = `DRIVE_BLACK;
    else if (pixel_prev[1:0] == 2'b11) // White
        proc_output = `DRIVE_WHITE;
    else if (doping_phase == 0) // Gray extreme
        proc_output = pixel_prev[0] ? `DRIVE_BLACK : `DRIVE_WHITE;
    else // Gray reverse
        proc_output = pixel_prev[0] ? `DRIVE_WHITE : `DRIVE_BLACK;

    // Update dc_bias at end of doping cycle (B/W only)
    if (!doping_phase && prev_doping_phase) begin  // falling edge of reverse
        if (pixel_prev[1:0] == 2'b00 || pixel_prev[1:0] == 2'b11)
            dc_bias_new = (dc_bias < 3) ? dc_bias + 1 : 3;
    end
end
```

3. **Update DONE->MONO transition** — apply overdrive:
```verilog
wire [1:0] dc_bias = pixel_prev[3:2];
wire [3:0] mono_frames = switching_direction ? (6 + dc_bias) : 6;
wire [3:0] rest_frames = switching_direction ? (7 - dc_bias) : 7;
wire [3:0] settle_frames = switching_direction ? (5 - dc_bias) : 5;
wire [1:0] new_dc_bias = switching_direction ? 2'd0 : dc_bias;
```

4. **Update HOLD->MONO transition** — same overdrive logic

5. **Preserve dc_bias** through MONO->HOLD and HOLD->DONE transitions:
   - When entering HOLD from MONO: copy dc_bias to [3:2]
   - When entering DONE from HOLD: preserve [3:2]

6. **Update timing constants** to use new values (7 REST, 5 SETTLE)

### 4. Other files

No changes needed to:
- `rtl/csr.v`
- Dithering modules
- Memory/FIFO handling

## Constants Summary

| Name | Value | Description |
|------|-------|-------------|
| `FASTG_MONO_FRAMES` | 6 | Base MONO frames |
| `FASTG_BW_REST_FRAMES` | 7 | B/W rest frames (no overdrive) |
| `FASTG_REVERSE_FRAMES` | 2 | Gray reverse frames (fixed) |
| `FASTG_SETTLE_FRAMES` | 5 | Gray settle frames (no overdrive) |
| `FASTG_VIDEO_COOLDOWN` | 13 | Cooldown frames in DONE (~1 sec doping immunity) |
| `DOPING_EXTREME_FRAMES` | 2 | Doping extreme phase |
| `DOPING_REVERSE_FRAMES` | 2 | Doping reverse phase |
| `DOPING_WAIT_FRAMES` | 25 | Frames between doping (~1 sec) |
| `DC_BIAS_MAX` | 3 | Maximum dc_bias |
| `OVERDRIVE_MAX` | 3 | Maximum overdrive frames |

## What Changes

| Component | Change |
|-----------|--------|
| `defines.vh` | Update timing constants, add doping constants |
| `caster.v` | Add global doping timer + signals |
| `pixel_processing.v` | Remove per-pixel doping, add global response + overdrive |

## What Stays the Same

- 16-bit pixel state (no memory changes)
- 4 pixels/clock processing
- FAST_GREY stage machine structure (DONE/MONO/HOLD/GREY)
- Video mode detection (fg_counter for rapid changes)
- Other modes (FAST_MONO, AUTO_LUT, MANUAL_LUT)
- All dithering modules
- FIFO widths and timing parameters

## Implementation Order

1. `defines.vh` — update timing constants, add doping constants
2. `caster.v` — add global doping timer and signals
3. `pixel_processing.v` — remove per-pixel doping, add global doping response
4. `pixel_processing.v` — add overdrive logic at MONO entry points
5. Test on hardware

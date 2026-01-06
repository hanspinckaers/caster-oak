#!/usr/bin/env python3
"""
Compare dithering approaches:
1. OLD: Single 8x8 Bayer + per-CFA bias (Friday's RTL)
2. NEW: CFA-balanced per-color 4x4 Bayer (current RTL)
3. W-AWARE: W compensates for dithered B/G/R values
"""

import numpy as np
from PIL import Image
import sys

# CFA simulation colors - tuned to match real display
CFA_COLORS = {
    "B": np.array([30, 50, 240]),   # Blue
    "W": np.array([255, 255, 255]),
    "G": np.array([80, 150, 65]),   # Green - balanced (120 was too purple, 160 too yellow)
    "R": np.array([240, 55, 50]),   # Slightly less red
}

# degamma_fg LUT from RTL
DEGAMMA_FG_LUT = np.array([
    0, 5, 8, 11, 14, 17, 20, 23, 26, 29, 32, 35,
    38, 42, 46, 50, 54, 58, 62, 66, 70,
    74, 78, 82, 86, 90, 94, 98, 102, 106, 110, 114,
    118, 122, 126, 130, 134, 138, 142, 146, 150, 154,
    158, 162, 166, 170, 174, 178, 182, 186, 190, 194,
    198, 202, 206, 210, 214, 218,
    222, 228, 235, 242, 250, 255
], dtype=np.uint8)

# Standard 8x8 Bayer matrix
BAYER_8X8 = np.array([
    [-8,  0, -6,  2, -7,  1, -5,  3],
    [ 4, -4,  6, -2,  5, -3,  7, -1],
    [-5,  3, -7,  1, -4,  4, -6,  2],
    [ 7, -1,  5, -3,  6, -2,  4, -4],
    [-7,  1, -5,  3, -8,  0, -6,  2],
    [ 5, -3,  7, -1,  4, -4,  6, -2],
    [-4,  4, -6,  2, -5,  3, -7,  1],
    [ 6, -2,  4, -4,  7, -1,  5, -3]
], dtype=np.float32)

# Per-CFA bias from OLD RTL (relative to BIAS_2B=15)
OLD_BIAS = {'B': 6, 'W': -2, 'G': -6, 'R': -2}


def apply_degamma_fg(values):
    """Apply degamma_fg shadow-boost curve."""
    idx = (values.astype(np.uint16) >> 2).clip(0, 63).astype(np.uint8)
    return DEGAMMA_FG_LUT[idx].astype(np.float32)


def quantize_4level(linear, bayer_offset):
    """Quantize to 4 levels with Bayer dithering."""
    # Scale to 5-bit (0-31), add bayer offset, take top 2 bits
    scaled = (linear / 255.0 * 31.0).astype(np.float32)
    dithered = np.clip(scaled + bayer_offset, 0, 31)
    quantized = (dithered / 8).astype(np.uint8)  # 0-3
    return (quantized * 85).astype(np.uint8)  # 0, 85, 170, 255


def get_bayer_8x8_tiled(h, w):
    """Tile standard 8x8 Bayer."""
    return np.tile(BAYER_8X8, (h // 8 + 1, w // 8 + 1))[:h, :w]


def get_cfa_balanced_8x8(phases=None):
    """Per-CFA balanced 8x8: each CFA sees independent 4x4 Bayer."""
    bayer4 = np.array([
        [ 0,  8,  2, 10],
        [12,  4, 14,  6],
        [ 3, 11,  1,  9],
        [15,  7, 13,  5]
    ], dtype=np.float32)

    matrix = np.zeros((8, 8), dtype=np.float32)
    if phases is None:
        phases = {'B': 0, 'W': 8, 'G': 4, 'R': 12}  # Original

    for i in range(4):
        for j in range(4):
            # B at (2i, 2j)
            matrix[2*i, 2*j] = (bayer4[i, j] + phases['B']) % 16 - 8
            # W at (2i, 2j+1)
            matrix[2*i, 2*j+1] = (bayer4[i, j] + phases['W']) % 16 - 8
            # G at (2i+1, 2j)
            matrix[2*i+1, 2*j] = (bayer4[i, j] + phases['G']) % 16 - 8
            # R at (2i+1, 2j+1)
            matrix[2*i+1, 2*j+1] = (bayer4[i, j] + phases['R']) % 16 - 8

    return matrix


def simulate_cfa(bw_image):
    """Simulate CFA color output from grayscale subpixels."""
    h, w = bw_image.shape
    output = np.zeros((h, w, 3), dtype=np.uint8)

    for (dy, dx), color in [((0,0), 'B'), ((0,1), 'W'), ((1,0), 'G'), ((1,1), 'R')]:
        mask = bw_image[dy::2, dx::2].astype(np.float32) / 255.0
        for c in range(3):
            output[dy::2, dx::2, c] = (mask * CFA_COLORS[color][c]).astype(np.uint8)

    return output


def dither_old(rgb):
    """OLD: Single 8x8 Bayer + per-CFA bias (Friday's RTL)."""
    h, w = rgb.shape[:2]
    lum = (0.299 * rgb[:,:,0] + 0.587 * rgb[:,:,1] + 0.114 * rgb[:,:,2]).astype(np.float32)

    bayer = get_bayer_8x8_tiled(h, w)
    bayer_half = np.floor(bayer / 2)

    output = np.zeros((h, w), dtype=np.uint8)

    for cfa, (dy, dx) in [('B', (0,0)), ('W', (0,1)), ('G', (1,0)), ('R', (1,1))]:
        if cfa == 'W':
            channel = lum
        elif cfa == 'B':
            channel = rgb[:,:,2].astype(np.float32)
        elif cfa == 'G':
            channel = rgb[:,:,1].astype(np.float32)
        else:
            channel = rgb[:,:,0].astype(np.float32)

        biased = np.clip(channel + OLD_BIAS[cfa], 0, 255)
        linear = apply_degamma_fg(biased)
        dithered = quantize_4level(linear, bayer_half)
        output[dy::2, dx::2] = dithered[dy::2, dx::2]

    return output


def dither_new(rgb):
    """NEW: CFA-balanced per-color 4x4 Bayer (current RTL)."""
    h, w = rgb.shape[:2]
    lum = (0.299 * rgb[:,:,0] + 0.587 * rgb[:,:,1] + 0.114 * rgb[:,:,2]).astype(np.float32)

    bayer = get_cfa_balanced_8x8()
    bayer = np.tile(bayer, (h // 8 + 1, w // 8 + 1))[:h, :w]
    bayer_half = np.floor(bayer / 2)

    b_in = rgb[:,:,2].astype(np.float32)
    g_in = rgb[:,:,1].astype(np.float32)
    r_in = rgb[:,:,0].astype(np.float32)

    bw_b = quantize_4level(apply_degamma_fg(b_in), bayer_half)
    bw_w = quantize_4level(apply_degamma_fg(lum), bayer_half)
    bw_g = quantize_4level(apply_degamma_fg(g_in), bayer_half)
    bw_r = quantize_4level(apply_degamma_fg(r_in), bayer_half)

    output = np.zeros((h, w), dtype=np.uint8)
    output[0::2, 0::2] = bw_b[0::2, 0::2]
    output[0::2, 1::2] = bw_w[0::2, 1::2]
    output[1::2, 0::2] = bw_g[1::2, 0::2]
    output[1::2, 1::2] = bw_r[1::2, 1::2]

    return output


def dither_w_first(rgb):
    """W-FIRST: W at phase 0 (activates first for gray)."""
    h, w = rgb.shape[:2]
    lum = (0.299 * rgb[:,:,0] + 0.587 * rgb[:,:,1] + 0.114 * rgb[:,:,2]).astype(np.float32)

    # W at phase 0, others shifted accordingly
    phases = {'B': 8, 'W': 0, 'G': 12, 'R': 4}
    bayer = get_cfa_balanced_8x8(phases)
    bayer = np.tile(bayer, (h // 8 + 1, w // 8 + 1))[:h, :w]
    bayer_half = np.floor(bayer / 2)

    b_in = rgb[:,:,2].astype(np.float32)
    g_in = rgb[:,:,1].astype(np.float32)
    r_in = rgb[:,:,0].astype(np.float32)

    bw_b = quantize_4level(apply_degamma_fg(b_in), bayer_half)
    bw_w = quantize_4level(apply_degamma_fg(lum), bayer_half)
    bw_g = quantize_4level(apply_degamma_fg(g_in), bayer_half)
    bw_r = quantize_4level(apply_degamma_fg(r_in), bayer_half)

    output = np.zeros((h, w), dtype=np.uint8)
    output[0::2, 0::2] = bw_b[0::2, 0::2]
    output[0::2, 1::2] = bw_w[0::2, 1::2]
    output[1::2, 0::2] = bw_g[1::2, 0::2]
    output[1::2, 1::2] = bw_r[1::2, 1::2]

    return output


def dither_grbw(rgb, bias_r=0, bias_g=0, bias_b=0):
    """G-R-B-W: G first, then R, then B, then W. Optional per-channel bias."""
    h, w = rgb.shape[:2]

    r_in = np.clip(rgb[:,:,0].astype(np.float32) + bias_r, 0, 255)
    g_in = np.clip(rgb[:,:,1].astype(np.float32) + bias_g, 0, 255)
    b_in = np.clip(rgb[:,:,2].astype(np.float32) + bias_b, 0, 255)
    lum = (0.299 * r_in + 0.587 * g_in + 0.114 * b_in).astype(np.float32)

    # G=0, R=4, B=8, W=12
    phases = {'G': 0, 'R': 4, 'B': 8, 'W': 12}
    bayer = get_cfa_balanced_8x8(phases)
    bayer = np.tile(bayer, (h // 8 + 1, w // 8 + 1))[:h, :w]
    bayer_half = np.floor(bayer / 2)

    bw_b = quantize_4level(apply_degamma_fg(b_in), bayer_half)
    bw_w = quantize_4level(apply_degamma_fg(lum), bayer_half)
    bw_g = quantize_4level(apply_degamma_fg(g_in), bayer_half)
    bw_r = quantize_4level(apply_degamma_fg(r_in), bayer_half)

    output = np.zeros((h, w), dtype=np.uint8)
    output[0::2, 0::2] = bw_b[0::2, 0::2]
    output[0::2, 1::2] = bw_w[0::2, 1::2]
    output[1::2, 0::2] = bw_g[1::2, 0::2]
    output[1::2, 1::2] = bw_r[1::2, 1::2]

    return output


def dither_w_aware(rgb):
    """W-AWARE: NEW (CFA-balanced) + W compensates based on INPUT B/G/R."""
    h, w = rgb.shape[:2]
    lum = (0.299 * rgb[:,:,0] + 0.587 * rgb[:,:,1] + 0.114 * rgb[:,:,2]).astype(np.float32)

    # Use CFA-balanced Bayer (like NEW)
    bayer = get_cfa_balanced_8x8()
    bayer = np.tile(bayer, (h // 8 + 1, w // 8 + 1))[:h, :w]
    bayer_half = np.floor(bayer / 2)

    b_in = rgb[:,:,2].astype(np.float32)
    g_in = rgb[:,:,1].astype(np.float32)
    r_in = rgb[:,:,0].astype(np.float32)

    # Dither B, G, R same as NEW (no bias)
    bw_b = quantize_4level(apply_degamma_fg(b_in), bayer_half)
    bw_g = quantize_4level(apply_degamma_fg(g_in), bayer_half)
    bw_r = quantize_4level(apply_degamma_fg(r_in), bayer_half)

    output = np.zeros((h, w), dtype=np.uint8)
    output[0::2, 0::2] = bw_b[0::2, 0::2]
    output[1::2, 0::2] = bw_g[1::2, 0::2]
    output[1::2, 1::2] = bw_r[1::2, 1::2]

    # For W: compensate based on INPUT B/G/R in its 2x2 block
    b_input = b_in[0::2, 0::2]  # B position inputs
    g_input = g_in[1::2, 0::2]  # G position inputs
    r_input = r_in[1::2, 1::2]  # R position inputs
    w_lum = lum[0::2, 1::2]

    min_h = min(b_input.shape[0], g_input.shape[0], r_input.shape[0], w_lum.shape[0])
    min_w = min(b_input.shape[1], g_input.shape[1], r_input.shape[1], w_lum.shape[1])

    # How much brighter/darker are B/G/R inputs vs luminance?
    neighbor_avg = (b_input[:min_h, :min_w] + g_input[:min_h, :min_w] + r_input[:min_h, :min_w]) / 3.0
    deviation = neighbor_avg - w_lum[:min_h, :min_w]

    # W target = luminance minus deviation (compensate)
    w_target = w_lum[:min_h, :min_w] - deviation * 1.0  # 100% compensation
    w_target = np.clip(w_target, 0, 255)

    bw_w = quantize_4level(apply_degamma_fg(w_target), bayer_half[0::2, 1::2][:min_h, :min_w])

    w_out = output[0::2, 1::2]
    w_out[:min_h, :min_w] = bw_w
    output[0::2, 1::2] = w_out

    return output


def run_comparison(input_path, output_prefix="dither"):
    """Run comparison of all approaches."""
    print(f"Loading {input_path}...")
    img = Image.open(input_path).convert('RGB')
    rgb = np.array(img)
    h, w = rgb.shape[:2]
    print(f"  Size: {w}x{h}")

    methods = [
        ("1x", lambda rgb: dither_grbw(rgb, bias_g=8, bias_r=4, bias_b=-4), "G+8 R+4 B-4 (1x)"),
        ("1.5x", lambda rgb: dither_grbw(rgb, bias_g=12, bias_r=6, bias_b=-6), "G+12 R+6 B-6 (1.5x)"),
        ("2x", lambda rgb: dither_grbw(rgb, bias_g=16, bias_r=8, bias_b=-8), "G+16 R+8 B-8 (2x)"),
        ("3x", lambda rgb: dither_grbw(rgb, bias_g=24, bias_r=12, bias_b=-12), "G+24 R+12 B-12 (3x)"),
    ]

    results = []
    for name, func, desc in methods:
        print(f"  {desc}...")
        bw = func(rgb)
        cfa = simulate_cfa(bw)
        results.append((name, bw, cfa, desc))
        Image.fromarray(cfa).save(f"{output_prefix}_{name}.png")

    # Side-by-side comparison
    compare = np.concatenate([r[2] for r in results], axis=1)
    Image.fromarray(compare).save(f"{output_prefix}_compare.png")
    print(f"\nSaved {output_prefix}_compare.png (OLD | NEW | W-AWARE)")

    # Zoomed center crop
    crop_h, crop_w = min(200, h//2), min(300, w//2)
    cy, cx = h//2, w//2
    zooms = []
    for name, bw, cfa, desc in results:
        crop = cfa[cy-crop_h//2:cy+crop_h//2, cx-crop_w//2:cx+crop_w//2]
        zoomed = np.repeat(np.repeat(crop, 3, axis=0), 3, axis=1)
        zooms.append(zoomed)

    zoom_compare = np.concatenate(zooms, axis=1)
    Image.fromarray(zoom_compare).save(f"{output_prefix}_zoom.png")
    print(f"Saved {output_prefix}_zoom.png (3x zoom)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python dither_compare.py <input_image> [output_prefix]")
        print("\nCompares:")
        print("  OLD: Single 8x8 Bayer + per-CFA bias")
        print("  NEW: CFA-balanced per-color 4x4 Bayer")
        print("  W-AWARE: W compensates for B/G/R dithered values")
        sys.exit(1)

    input_path = sys.argv[1]
    output_prefix = sys.argv[2] if len(sys.argv) > 2 else "dither"
    run_comparison(input_path, output_prefix)

#!/usr/bin/env python3
"""
RGBW Color Picker with Dithering Simulation

Creates HSV color space visualizations and dithers them to the RGBW palette
to show what colors are achievable on the reflective display.
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import colorsys

# Filter coefficients
K_B = 0.10
K_G = 0.60
K_R = 0.30
K_W = 1.00

# Gray levels and filters
GRAY_LEVELS = [0, 85, 170, 255]
FILTERS = ['B', 'W', 'G', 'R']

def linear_to_srgb(linear):
    """Convert linear RGB (0-1) to sRGB (0-1) with gamma correction."""
    if linear <= 0.0031308:
        return linear * 12.92
    else:
        return 1.055 * (linear ** (1/2.4)) - 0.055

def srgb_to_linear(srgb):
    """Convert sRGB (0-1) to linear RGB (0-1)."""
    if srgb <= 0.04045:
        return srgb / 12.92
    else:
        return ((srgb + 0.055) / 1.055) ** 2.4

def gray_to_rgb(gray_level, filter_type):
    """Calculate RGB for gray level behind CFA filter with gamma correction."""
    reflectance = gray_level / 255.0

    if filter_type == 'B':
        r_lin, g_lin, b_lin = 0.0, 0.0, reflectance * K_B
    elif filter_type == 'G':
        r_lin, g_lin, b_lin = 0.0, reflectance * K_G, 0.0
    elif filter_type == 'R':
        r_lin, g_lin, b_lin = reflectance * K_R, 0.0, 0.0
    elif filter_type == 'W':
        lum = reflectance * K_W
        r_lin, g_lin, b_lin = lum, lum, lum

    r_srgb = linear_to_srgb(r_lin)
    g_srgb = linear_to_srgb(g_lin)
    b_srgb = linear_to_srgb(b_lin)

    return (r_srgb, g_srgb, b_srgb)

def quad_to_color(gray_levels):
    """Calculate additive mixed color for a quad. Returns RGB in 0-1 range."""
    r_total, g_total, b_total = 0.0, 0.0, 0.0

    for gray, filt in zip(gray_levels, FILTERS):
        r, g, b = gray_to_rgb(gray, filt)
        r_total += r
        g_total += g
        b_total += b

    # Average over 4 subpixels and clamp
    r_avg = min(1.0, r_total / 4.0)
    g_avg = min(1.0, g_total / 4.0)
    b_avg = min(1.0, b_total / 4.0)

    return (r_avg, g_avg, b_avg)

# Pre-generate all 256 quad combinations and their colors
print("Generating RGBW palette...")
PALETTE = []
for g_b in GRAY_LEVELS:
    for g_w in GRAY_LEVELS:
        for g_g in GRAY_LEVELS:
            for g_r in GRAY_LEVELS:
                quad = [g_b, g_w, g_g, g_r]
                color = quad_to_color(quad)
                PALETTE.append((quad, color))
print(f"Generated {len(PALETTE)} palette entries")

def find_closest_palette_color(target_rgb):
    """
    Find closest palette color to target RGB (0-1 range).
    Returns (quad, color, distance).
    """
    best_quad = None
    best_color = None
    best_dist = float('inf')

    tr, tg, tb = target_rgb

    for quad, (pr, pg, pb) in PALETTE:
        # Euclidean distance in RGB space
        dist = ((tr - pr)**2 + (tg - pg)**2 + (tb - tb)**2)**0.5
        if dist < best_dist:
            best_dist = dist
            best_quad = quad
            best_color = (pr, pg, pb)

    return best_quad, best_color, best_dist

def ordered_dither_2x2(target_rgb, x, y):
    """
    Apply 2×2 ordered dithering to find best quad for position (x,y).
    Returns the palette color (RGB tuple).
    """
    # Simple 2×2 Bayer matrix
    bayer_2x2 = np.array([
        [0, 2],
        [3, 1]
    ]) / 4.0

    threshold = bayer_2x2[y % 2, x % 2]

    # Find two closest palette colors
    distances = []
    for quad, color in PALETTE:
        tr, tg, tb = target_rgb
        pr, pg, pb = color
        dist = ((tr - pr)**2 + (tg - pg)**2 + (tb - pb)**2)**0.5
        distances.append((dist, quad, color))

    distances.sort()

    # Dither between two closest colors based on threshold
    if len(distances) >= 2:
        _, quad1, color1 = distances[0]
        _, quad2, color2 = distances[1]

        # Use threshold to pick between them
        if threshold < 0.5:
            return color1
        else:
            return color2
    else:
        return distances[0][2]

def create_hue_saturation_wheel(size=400, dithered=False):
    """
    Create a hue-saturation color wheel at fixed value (brightness).
    Optionally dither to RGBW palette.
    """
    img = np.zeros((size, size, 3))
    center = size / 2

    for y in range(size):
        for x in range(size):
            # Convert to polar coordinates
            dx = x - center
            dy = y - center
            dist = np.sqrt(dx**2 + dy**2)
            angle = np.arctan2(dy, dx)

            # Map to HSV
            saturation = min(1.0, dist / (size/2))
            hue = (angle + np.pi) / (2 * np.pi)  # 0-1
            value = 1.0  # Fixed brightness

            if dist <= size/2:  # Inside circle
                r, g, b = colorsys.hsv_to_rgb(hue, saturation, value)

                if dithered:
                    # Dither to palette
                    dithered_color = ordered_dither_2x2((r, g, b), x, y)
                    img[y, x] = dithered_color
                else:
                    img[y, x] = (r, g, b)
            else:
                img[y, x] = (0.5, 0.5, 0.5)  # Gray outside

    return img

def create_hue_gradient(width=800, height=100, dithered=False):
    """Create a horizontal hue gradient (rainbow) at full saturation and value."""
    img = np.zeros((height, width, 3))

    for x in range(width):
        hue = x / width
        r, g, b = colorsys.hsv_to_rgb(hue, 1.0, 1.0)

        if dithered:
            for y in range(height):
                dithered_color = ordered_dither_2x2((r, g, b), x, y)
                img[y, x] = dithered_color
        else:
            img[:, x] = (r, g, b)

    return img

def create_brightness_saturation_grid(hue=0.0, width=400, height=400, dithered=False):
    """
    Create a 2D grid: X=saturation (0-1), Y=value/brightness (0-1).
    Fixed hue.
    """
    img = np.zeros((height, width, 3))

    for y in range(height):
        for x in range(width):
            saturation = x / width
            value = 1.0 - (y / height)  # Top = bright, bottom = dark

            r, g, b = colorsys.hsv_to_rgb(hue, saturation, value)

            if dithered:
                dithered_color = ordered_dither_2x2((r, g, b), x, y)
                img[y, x] = dithered_color
            else:
                img[y, x] = (r, g, b)

    return img

def create_comparison_figure():
    """Create comprehensive color picker comparison: original vs dithered."""
    fig = plt.figure(figsize=(18, 12))

    # Hue gradient (rainbow)
    print("Generating hue gradient...")
    ax1 = plt.subplot(3, 2, 1)
    hue_orig = create_hue_gradient(width=800, height=100, dithered=False)
    ax1.imshow(hue_orig)
    ax1.set_title('Hue Gradient (Original)', fontsize=12, fontweight='bold')
    ax1.axis('off')

    ax2 = plt.subplot(3, 2, 2)
    hue_dith = create_hue_gradient(width=800, height=100, dithered=True)
    ax2.imshow(hue_dith)
    ax2.set_title('Hue Gradient (RGBW Dithered)', fontsize=12, fontweight='bold')
    ax2.axis('off')

    # Saturation-Value grid (Red hue)
    print("Generating saturation-value grid (Red)...")
    ax3 = plt.subplot(3, 2, 3)
    sv_red_orig = create_brightness_saturation_grid(hue=0.0, dithered=False)
    ax3.imshow(sv_red_orig)
    ax3.set_title('Sat-Brightness (Red, Original)', fontsize=12, fontweight='bold')
    ax3.set_xlabel('Saturation →', fontsize=10)
    ax3.set_ylabel('← Brightness', fontsize=10)
    ax3.set_xticks([])
    ax3.set_yticks([])

    ax4 = plt.subplot(3, 2, 4)
    sv_red_dith = create_brightness_saturation_grid(hue=0.0, dithered=True)
    ax4.imshow(sv_red_dith)
    ax4.set_title('Sat-Brightness (Red, RGBW Dithered)', fontsize=12, fontweight='bold')
    ax4.set_xlabel('Saturation →', fontsize=10)
    ax4.set_ylabel('← Brightness', fontsize=10)
    ax4.set_xticks([])
    ax4.set_yticks([])

    # Saturation-Value grid (Green hue)
    print("Generating saturation-value grid (Green)...")
    ax5 = plt.subplot(3, 2, 5)
    sv_green_orig = create_brightness_saturation_grid(hue=0.33, dithered=False)
    ax5.imshow(sv_green_orig)
    ax5.set_title('Sat-Brightness (Green, Original)', fontsize=12, fontweight='bold')
    ax5.set_xlabel('Saturation →', fontsize=10)
    ax5.set_ylabel('← Brightness', fontsize=10)
    ax5.set_xticks([])
    ax5.set_yticks([])

    ax6 = plt.subplot(3, 2, 6)
    sv_green_dith = create_brightness_saturation_grid(hue=0.33, dithered=True)
    ax6.imshow(sv_green_dith)
    ax6.set_title('Sat-Brightness (Green, RGBW Dithered)', fontsize=12, fontweight='bold')
    ax6.set_xlabel('Saturation →', fontsize=10)
    ax6.set_ylabel('← Brightness', fontsize=10)
    ax6.set_xticks([])
    ax6.set_yticks([])

    plt.suptitle('RGBW Color Picker: Original vs 2-bit Dithered\n'
                'Shows color gamut achievable with 256 quad combinations + ordered dithering',
                fontsize=14, fontweight='bold')

    plt.tight_layout()
    return fig

def create_hue_wheel_comparison():
    """Create hue-saturation wheel comparison."""
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(16, 8))

    print("Generating hue-saturation wheel (original)...")
    wheel_orig = create_hue_saturation_wheel(size=600, dithered=False)
    ax1.imshow(wheel_orig)
    ax1.set_title('Hue-Saturation Wheel (Original)\nCenter=desaturated, Edge=saturated',
                 fontsize=12, fontweight='bold')
    ax1.axis('off')

    print("Generating hue-saturation wheel (dithered)...")
    wheel_dith = create_hue_saturation_wheel(size=600, dithered=True)
    ax2.imshow(wheel_dith)
    ax2.set_title('Hue-Saturation Wheel (RGBW Dithered)\n2×2 Ordered Dithering to 256 Quad Palette',
                 fontsize=12, fontweight='bold')
    ax2.axis('off')

    plt.suptitle('Color Wheel at Maximum Brightness (V=1.0)',
                fontsize=14, fontweight='bold')
    plt.tight_layout()
    return fig

if __name__ == '__main__':
    print("Creating RGBW color picker visualizations...")

    fig1 = create_comparison_figure()
    fig1.savefig('rgbw_color_picker.png', dpi=150, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_color_picker.png")

    fig2 = create_hue_wheel_comparison()
    fig2.savefig('rgbw_color_wheel.png', dpi=150, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_color_wheel.png")

    print("\nDone! Generated color picker visualizations.")
    plt.show()

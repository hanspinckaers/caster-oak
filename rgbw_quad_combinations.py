#!/usr/bin/env python3
"""
RGBW Quad Combination Examples

Shows how different combinations of gray levels across a 2×2 CFA quad
create different colors through additive mixing.
"""

import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import numpy as np

# Filter coefficients
K_B = 0.10
K_G = 0.60
K_R = 0.30
K_W = 1.00

# Gray levels
GRAY_LEVELS = {'B': 0, 'DG': 85, 'LG': 170, 'W': 255}
FILTERS = ['B', 'W', 'G', 'R']  # CFA quad positions

def linear_to_srgb(linear):
    """Convert linear RGB (0-1) to sRGB (0-1) with gamma correction."""
    if linear <= 0.0031308:
        return linear * 12.92
    else:
        return 1.055 * (linear ** (1/2.4)) - 0.055

def gray_to_rgb(gray_level, filter_type):
    """
    Calculate RGB for gray level behind CFA filter (reflective display).
    Applies gamma correction for proper screen display.
    """
    # Reflectance is linear (0-1)
    reflectance = gray_level / 255.0

    # Calculate linear RGB based on filter transmission
    if filter_type == 'B':
        r_lin, g_lin, b_lin = 0.0, 0.0, reflectance * K_B
    elif filter_type == 'G':
        r_lin, g_lin, b_lin = 0.0, reflectance * K_G, 0.0
    elif filter_type == 'R':
        r_lin, g_lin, b_lin = reflectance * K_R, 0.0, 0.0
    elif filter_type == 'W':
        lum = reflectance * K_W
        r_lin, g_lin, b_lin = lum, lum, lum

    # Apply gamma correction for proper screen display
    r_srgb = linear_to_srgb(r_lin)
    g_srgb = linear_to_srgb(g_lin)
    b_srgb = linear_to_srgb(b_lin)

    return (int(r_srgb * 255), int(g_srgb * 255), int(b_srgb * 255))

def quad_to_color(gray_levels):
    """
    Calculate additive mixed color for a 2×2 CFA quad.
    gray_levels: [g_B, g_W, g_G, g_R]
    """
    r_total, g_total, b_total = 0, 0, 0

    for gray, filt in zip(gray_levels, FILTERS):
        r, g, b = gray_to_rgb(gray, filt)
        r_total += r
        g_total += g
        b_total += b

    # Average over 4 subpixels
    r_avg = min(255, r_total // 4)
    g_avg = min(255, g_total // 4)
    b_avg = min(255, b_total // 4)

    return (r_avg, g_avg, b_avg)

def draw_quad_breakdown(ax, x, y, gray_levels, title):
    """Draw a quad showing individual subpixels and final mixed color."""
    size = 0.4
    gap = 0.05

    # Draw 2×2 subpixel grid
    positions = [(0,1), (1,1), (0,0), (1,0)]  # [B, W, G, R]
    gray_names = ['B', 'DG', 'LG', 'W']

    for i, (pos, gray_val, filt) in enumerate(zip(positions, gray_levels, FILTERS)):
        px = x + pos[0] * (size + gap)
        py = y + pos[1] * (size + gap)

        rgb = gray_to_rgb(gray_val, filt)
        color = tuple(c / 255.0 for c in rgb)

        rect = Rectangle((px, py), size, size,
                        facecolor=color, edgecolor='white', linewidth=1)
        ax.add_patch(rect)

        # Label with gray level
        gray_name = [k for k, v in GRAY_LEVELS.items() if v == gray_val][0]
        ax.text(px + size/2, py + size/2, gray_name,
               ha='center', va='center', fontsize=6,
               color='white' if sum(rgb) < 384 else 'black',
               fontweight='bold')

    # Draw arrow
    ax.annotate('', xy=(x + 1.2, y + 0.4), xytext=(x + 0.9, y + 0.4),
               arrowprops=dict(arrowstyle='->', lw=2, color='black'))

    # Draw final mixed color
    final_rgb = quad_to_color(gray_levels)
    final_color = tuple(c / 255.0 for c in final_rgb)

    final_x = x + 1.3
    final_size = 0.9
    rect = Rectangle((final_x, y), final_size, final_size,
                    facecolor=final_color, edgecolor='black', linewidth=2)
    ax.add_patch(rect)

    # Label
    ax.text(final_x + final_size/2, y + final_size + 0.1,
           f'R:{final_rgb[0]}\nG:{final_rgb[1]}\nB:{final_rgb[2]}',
           ha='center', va='bottom', fontsize=7,
           family='monospace', fontweight='bold')

    # Title
    ax.text(x - 0.3, y + 0.4, title,
           ha='right', va='center', fontsize=8, fontweight='bold')

def create_combination_examples():
    """Create examples of quad combinations and resulting colors."""
    fig, ax = plt.subplots(figsize=(14, 12))

    # Define interesting combinations
    examples = [
        # (gray_levels [B,W,G,R], title)
        ([0, 0, 0, 0], "All Black"),
        ([255, 255, 255, 255], "All White"),
        ([255, 0, 0, 0], "Blue Only"),
        ([0, 255, 0, 0], "White Only"),
        ([0, 0, 255, 0], "Green Only"),
        ([0, 0, 0, 255], "Red Only"),
        ([170, 170, 170, 170], "All Light Gray"),
        ([85, 85, 85, 85], "All Dark Gray"),
        ([255, 255, 0, 0], "Blue + White"),
        ([0, 0, 255, 255], "Green + Red = Yellow"),
        ([255, 0, 255, 0], "Blue + Green = Cyan"),
        ([255, 0, 0, 255], "Blue + Red = Magenta"),
        ([255, 170, 85, 0], "Gradient (Bright→Dark)"),
        ([0, 85, 170, 255], "Gradient (Dark→Bright)"),
        ([255, 0, 255, 0], "Alternating High/Low"),
        ([170, 85, 170, 85], "Checkerboard Gray"),
        ([255, 85, 170, 170], "Mixed Cool Tones"),
        ([170, 170, 255, 85], "Green Emphasis"),
        ([85, 170, 85, 255], "Red Emphasis"),
        ([255, 255, 255, 0], "RGB Bright, R Dark"),
    ]

    y_start = 10.0
    y_step = 0.5

    for i, (gray_levels, title) in enumerate(examples):
        y = y_start - i * y_step
        draw_quad_breakdown(ax, 0.5, y, gray_levels, title)

    # Title
    ax.text(1.8, 11.0,
           'RGBW Quad Combinations → Additive Mixing\n'
           '2×2 CFA Quad [Blue, White, Green, Red] → Final Color',
           ha='center', va='top', fontsize=14, fontweight='bold')

    # Explanation
    ax.text(1.8, -1.0,
           'Each 2×2 quad has 4 positions × 4 gray levels = 256 possible combinations\n'
           'Additive color mixing creates thousands of distinct colors',
           ha='center', va='top', fontsize=10,
           bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.8))

    ax.set_xlim(0, 3.6)
    ax.set_ylim(-1.5, 11.5)
    ax.set_aspect('equal')
    ax.axis('off')

    plt.tight_layout()
    return fig

def create_all_256_grid():
    """Create complete 16×16 grid of all 256 combinations."""
    fig, ax = plt.subplots(figsize=(18, 18))

    gray_vals = [0, 85, 170, 255]
    combinations = []

    # Generate all combinations systematically
    for g_b in gray_vals:
        for g_w in gray_vals:
            for g_g in gray_vals:
                for g_r in gray_vals:
                    combinations.append([g_b, g_w, g_g, g_r])

    # Sort by brightness
    combinations = sorted(combinations,
                         key=lambda x: sum(quad_to_color(x)) / 3)

    swatch_size = 1.0
    for i, gray_levels in enumerate(combinations):
        row = i // 16
        col = i % 16

        rgb = quad_to_color(gray_levels)
        color = tuple(c / 255.0 for c in rgb)

        x = col * swatch_size
        y = (15 - row) * swatch_size

        rect = Rectangle((x, y), swatch_size, swatch_size,
                        facecolor=color, edgecolor='gray', linewidth=0.5)
        ax.add_patch(rect)

        # Add quad notation for corner samples
        if (i < 16) or (i % 16 == 0):
            quad_str = f"{gray_levels[0]:>3},{gray_levels[1]:>3}\n{gray_levels[2]:>3},{gray_levels[3]:>3}"
            ax.text(x + swatch_size/2, y + swatch_size/2,
                   quad_str, ha='center', va='center', fontsize=4,
                   color='white' if sum(rgb) < 384 else 'black',
                   family='monospace')

    ax.set_xlim(0, 16 * swatch_size)
    ax.set_ylim(0, 16 * swatch_size)
    ax.set_aspect('equal')
    ax.axis('off')

    ax.set_title('All 256 Quad Combinations (Sorted by Brightness)\n'
                '4 positions × 4 gray levels = 256 unique additive mixtures',
                fontsize=16, fontweight='bold', pad=20)

    plt.tight_layout()
    return fig

if __name__ == '__main__':
    print("Creating quad combination visualizations...")

    fig1 = create_combination_examples()
    fig1.savefig('rgbw_quad_examples.png', dpi=200, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_quad_examples.png")

    fig2 = create_all_256_grid()
    fig2.savefig('rgbw_all_256_combinations.png', dpi=200, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_all_256_combinations.png")

    print("\nDone!")
    plt.show()

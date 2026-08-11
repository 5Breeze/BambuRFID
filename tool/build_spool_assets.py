#!/usr/bin/env python3
"""Rebuild BambuRFID's transparent, dynamically recolorable spool assets.

Input:
  tool/reference/spool_reference.png

Outputs:
  assets/spool_base.png
  assets/spool_color_luma.png

The base layer keeps the clear spool, hub and neutral details. The luma layer
contains only the filament / printed sample shading. Flutter tints that layer
with the RGB value read from the RFID tag.

Requires: Pillow, NumPy, OpenCV (cv2).
"""

from pathlib import Path

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tool" / "reference" / "spool_reference.png"
ASSETS = ROOT / "assets"


def ellipse_mask(xx, yy, cx, cy, rx, ry):
    return (((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2) <= 1


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)

    image = Image.open(SOURCE).convert("RGB")
    arr = np.asarray(image).astype(np.float32)
    rgb = arr.astype(np.uint8)
    height, width = rgb.shape[:2]
    yy, xx = np.mgrid[0:height, 0:width]

    # Estimate the neutral studio background independently for every row.
    edge = 10
    background_row = np.median(
        np.concatenate([arr[:, :edge, :], arr[:, -edge:, :]], axis=1), axis=1
    )
    background = np.repeat(background_row[:, None, :], width, axis=1)
    difference = np.sqrt(np.mean((arr - background) ** 2, axis=2))

    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    grad_x = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    gradient = cv2.magnitude(grad_x, grad_y)

    # Tight geometry prevents the original white background from surviving the matte.
    rear_spool = ellipse_mask(xx, yy, 150, 260, 145, 245)
    front_spool = ellipse_mask(xx, yy, 265, 260, 130, 245)
    sample = ellipse_mask(xx, yy, 412, 416, 110, 106)
    subject_shape = rear_spool | front_spool | sample

    soft_alpha = np.clip((difference - 2.0) / 26.0, 0.0, 1.0) ** 0.74
    edge_alpha = np.clip((gradient - 5.0) / 55.0, 0.0, 1.0) * 0.58
    alpha = np.maximum(soft_alpha, edge_alpha) * subject_shape.astype(np.float32)

    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    hue, saturation, value = hsv[..., 0], hsv[..., 1], hsv[..., 2]

    # Restrict blue detection spatially so reflections in the transparent front
    # flange are not accidentally recolored.
    filament_spatial = (
        (xx >= 34) & (xx <= 228) & (yy >= 48) & (yy <= 468)
    )
    sample_spatial = (
        (xx >= 300) & (xx <= 530) & (yy >= 305) & (yy <= 535)
    )
    source_blue = (
        (hue >= 96)
        & (hue <= 145)
        & (saturation >= 95)
        & (value >= 35)
    )
    color_core = source_blue & (filament_spatial | sample_spatial)
    color_mask = cv2.GaussianBlur(color_core.astype(np.float32), (0, 0), 0.7)
    color_mask = np.clip(color_mask, 0.0, 1.0)

    alpha = np.maximum(alpha, color_mask * 0.99)
    alpha = np.maximum(alpha, ((gray < 150) & subject_shape).astype(np.float32) * 0.9)
    alpha = cv2.GaussianBlur(alpha, (0, 0), 0.45)
    alpha[alpha < 0.035] = 0
    alpha = np.clip(alpha, 0.0, 1.0)

    # Neutralize the original blue cast in clear plastic so orange/green/etc.
    # filaments do not retain a blue transparent flange.
    base_hsv = hsv.astype(np.float32).copy()
    blue_cast = (
        (hue >= 88)
        & (hue <= 145)
        & (saturation >= 8)
        & (rear_spool | front_spool | sample)
        & (~color_core)
    )
    base_hsv[..., 1][blue_cast] *= 0.06
    base_hsv[..., 0][blue_cast] = 0
    base_rgb = cv2.cvtColor(
        np.clip(base_hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2RGB
    )

    base_alpha = alpha * (1.0 - color_mask)
    base_rgba = np.dstack(
        [base_rgb, np.clip(base_alpha * 255.0, 0, 255).astype(np.uint8)]
    )

    # Convert the source filament into a neutral bright luma texture. Flutter
    # applies the RFID color with BlendMode.modulate while preserving texture.
    luminance = 0.2126 * arr[..., 0] + 0.7152 * arr[..., 1] + 0.0722 * arr[..., 2]
    values = luminance[color_core]
    low = np.percentile(values, 1)
    high = np.percentile(values, 99)
    normalized = np.clip((luminance - low) / max(1.0, high - low), 0.0, 1.0)
    luma = (115.0 + normalized * 140.0).astype(np.uint8)
    luma_rgba = np.dstack(
        [
            luma,
            luma,
            luma,
            np.clip(color_mask * alpha * 255.0, 0, 255).astype(np.uint8),
        ]
    )

    # Stable crop/placement for the supplied reference image.
    crop_box = (6, 14, 532, 536)

    def square_asset(rgba, size=1024):
        crop = Image.fromarray(rgba, "RGBA").crop(crop_box)
        crop_width, crop_height = crop.size
        max_content = int(size * 0.92)
        scale = min(max_content / crop_width, max_content / crop_height)
        new_width = round(crop_width * scale)
        new_height = round(crop_height * scale)
        crop = crop.resize((new_width, new_height), Image.Resampling.LANCZOS)

        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        x = (size - new_width) // 2
        y = (size - new_height) // 2 - 8
        canvas.alpha_composite(crop, (x, y))
        return canvas

    square_asset(base_rgba).save(ASSETS / "spool_base.png")
    square_asset(luma_rgba).save(ASSETS / "spool_color_luma.png")

    print("Generated:")
    print(ASSETS / "spool_base.png")
    print(ASSETS / "spool_color_luma.png")


if __name__ == "__main__":
    main()

# Changelog

## 1.1.0 - 2026-07-23

- Added real network scanning over the printer's WSD Scan service.
- Added a reproducible SANE runtime based on Debian and `sane-airscan`.
- Added a macOS scanner command with automatic address discovery.
- Added 150/300/600 dpi, color/grayscale, A4/Letter/full-bed, and
  JPEG/PNG/TIFF options.
- Added scanner files to the macOS package.
- Documented the independent printing and scanning data paths in English and
  Simplified Chinese.
- Verified a 300 dpi color scan on a physical Canon G3010 series device.

## 1.0.0 - 2026-07-23

- Initial public release.
- Automatic DNS-SD discovery for the Canon G3010.
- G3000 CUPS renderer and G3010 LPD compatibility queue.
- Install, uninstall, and diagnostic scripts.
- macOS package builder.
- English and Simplified Chinese documentation.

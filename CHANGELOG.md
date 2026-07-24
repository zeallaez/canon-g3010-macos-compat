# Changelog

## 1.2.0 - 2026-07-24

- Added a WSD/SANE-to-eSCL bridge for Apple Image Capture and compatible
  macOS scan panels.
- Added a per-user launch agent that restores the scanner service after login.
- Bound the eSCL endpoint to `127.0.0.1` and published a dedicated loopback
  Bonjour proxy host so other LAN devices cannot connect.
- Added one-command bridge install, start, stop, status, and uninstall actions.
- Added the bridge to the macOS package, diagnostics, checks, and bilingual
  documentation.
- Verified capability discovery, overview scans, and a physical JPEG scan from
  Apple Image Capture on a Canon G3810/G3010-series device.

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

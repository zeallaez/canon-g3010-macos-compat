# Changelog

## 1.4.0 - 2026-07-24

- Added an original lightweight eSCL server that invokes the native
  `sane-airscan`/`scanimage` WSD path directly; AirSane is no longer included
  in new builds.
- Reused the printer's real Bonjour UUID and product name for the `_uscan`
  service so printing and scanning share one multifunction identity.
- Changed the print queue to a UUID-bearing DNS-SD URI while preserving the
  tested Canon G3000 BJRaster3 renderer.
- Added a persistent Bonjour hostname and last-known address configuration.
- Added background address monitoring and automatic bridge restart when DHCP
  changes the printer's IP address.
- Corrected the advertised 216 x 297 mm platen boundary so Apple Image Capture
  exposes the full A4 preset instead of defaulting to JIS B5.
- Prevented the address monitor from treating a scanner that is busy moving
  the carriage as offline and restarting the bridge during a scan.
- Kept the ability to run an installed 1.3.x AirSane runtime as a migration
  fallback, while 1.4.0 packages use the direct bridge.
- Verified an Image Capture overview and a physical 150 dpi color JPEG scan
  through the direct bridge on a Canon G3810/G3010-series device.

## 1.3.0 - 2026-07-24

- Replaced the Docker scanning runtime with native arm64/x86_64 macOS
  executables and a self-contained dynamic-library bundle.
- Ported the static WSD configuration path of `sane-airscan` to macOS and used
  Apple's native DNS-SD utility to publish the AirSane eSCL bridge.
- Added reproducible pinned-source builds and audited portability patches.
- Changed Bonjour publication so Image Capture only sees the scanner after
  the native eSCL engine is ready.
- Migrates and removes the superseded private Docker bridge automatically.
- Verified native WSD capability discovery and a physical 150 dpi color JPEG
  scan without Docker, USB, a password, or a cloud service.

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

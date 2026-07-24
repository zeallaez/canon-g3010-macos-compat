# Legal and trademark notice

This repository contains only the open-source compatibility installer,
scanner wrapper, native build recipe and portability patches, diagnostic
scripts, packaging code, and documentation written for this project.

It does **not** contain or redistribute Canon printer drivers, binaries,
firmware, PPD files, icons, ICC profiles, or other Canon-owned software.
Users must obtain the required Canon G3000 series CUPS driver directly from
Canon and accept Canon's terms themselves.

Canon, PIXMA, G3000, and G3010 are trademarks or registered trademarks of
Canon Inc. This project is independent, unofficial, and not endorsed by,
affiliated with, or supported by Canon Inc.

The MIT License applies only to the original files in this repository. It does
not grant any rights to third-party software, names, or trademarks.

The scanner runtime builds `sane-airscan` from a pinned upstream source
revision and applies the macOS portability patch included here. `sane-airscan`
is an independent project licensed under GPL-2.0. Release packages contain its
compiled backend and license; its source revision remains available from the
upstream project and through this project's reproducible build recipe.

Project: https://github.com/alexpevzner/sane-airscan

The macOS Image Capture bridge builds AirSane from a pinned upstream source
revision. AirSane is an independent project licensed under GPL-3.0. Release
packages contain its compiled executable and license. The build also bundles
the required open-source SANE and codec dynamic libraries; their respective
upstream license terms continue to apply. No Canon binary is included in the
scanner runtime.

Project: https://github.com/SimulPiscator/AirSane

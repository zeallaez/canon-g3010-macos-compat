# Legal and trademark notice

This repository contains only the open-source compatibility installer,
scanner wrapper, reproducible container recipe, diagnostic scripts, packaging
code, and documentation written for this project.

It does **not** contain or redistribute Canon printer drivers, binaries,
firmware, PPD files, icons, ICC profiles, or other Canon-owned software.
Users must obtain the required Canon G3000 series CUPS driver directly from
Canon and accept Canon's terms themselves.

Canon, PIXMA, G3000, and G3010 are trademarks or registered trademarks of
Canon Inc. This project is independent, unofficial, and not endorsed by,
affiliated with, or supported by Canon Inc.

The MIT License applies only to the original files in this repository. It does
not grant any rights to third-party software, names, or trademarks.

The scanner runtime installs the Debian packages `sane-airscan`, `sane-utils`,
and their dependencies into a local container image. `sane-airscan` is an
independent project licensed under GPL-2.0. Those packages are downloaded from
Debian when the user builds the image; their respective licenses continue to
apply inside that image. They are not copied into this Git repository.

Project: https://github.com/alexpevzner/sane-airscan

The optional macOS Image Capture bridge builds AirSane from source inside the
local container image. AirSane is an independent project licensed under
GPL-3.0. Its source and license are obtained from its upstream repository
during the image build and remain subject to that license. AirSane source or
binaries are not copied into this Git repository.

Project: https://github.com/SimulPiscator/AirSane

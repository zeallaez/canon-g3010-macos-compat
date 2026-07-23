# Canon G3010 macOS Compatibility Layer

[简体中文](README.zh-CN.md) · [How it works](docs/HOW_IT_WORKS.md) · [License](LICENSE)

An unofficial, open-source compatibility layer that enables network printing
and scanning from modern macOS to the Canon PIXMA G3010.

Printing pairs:

- Canon's official G3000 macOS CUPS renderer;
- the G3010's native BJRaster3-compatible print language; and
- the printer's raw LPD `auto` queue.

Scanning uses the printer's standards-based WSD Scan service through
`sane-airscan` in a small, reproducible local container.

Tested on an Apple silicon Mac running macOS 26.5.2 with Canon's G3000 CUPS
driver 16.91.0.0. A physical 300 dpi color network scan was also verified.

> [!IMPORTANT]
> This project does not include Canon software. Install the official G3000
> CUPS driver for printing; scanning does not need it. This project is
> independent and is not endorsed or supported by Canon.

## Features

- Creates a system printer named `Canon_G3010`.
- Automatically discovers the default `Canon G3010 series` service.
- Supports an explicit hostname when automatic discovery is unavailable.
- Configures A4, color, plain paper, normal quality, and one-sided printing.
- Can send a macOS test page.
- Includes a reversible uninstaller and a read-only diagnostic tool.
- Scans over Wi-Fi/LAN without USB or a cloud service.
- Supports 150/300/600 dpi, color/grayscale, A4/Letter/full-bed, and
  JPEG/PNG/TIFF output.
- Uses a reproducible SANE runtime and never requires the printer's web
  administrator password.
- Builds an installable macOS `.pkg` containing both print and scan wrappers.

## Requirements

- macOS 11 or later;
- a Canon PIXMA G3010 on the same local network;
- Canon G3000 series CUPS Printer Driver 16.91.0.0 or a compatible newer
  release (printing only);
- Docker Desktop, installed and running (scanning only);
- administrator access when macOS requests it.

Download the Canon dependency from the
[official Canon support page](https://asia.canon/en/support/0101155813?model=PIXMA%20G3000).

The installer verifies that this file exists before changing the print queue:

```text
/Library/Printers/PPDs/Contents/Resources/CanonIJG3000series.ppd.gz
```

## Quick start

### Install from a release package

1. Install Canon's official G3000 CUPS driver.
2. Download `Canon-G3010-macOS-Compat-1.1.0.pkg` from GitHub Releases.
3. Open the package and follow the macOS installer.
4. Print to `Canon G3010 series (Mac compatibility)`.

The package is currently unsigned. If Finder blocks it, use the documented
Terminal method instead of disabling Gatekeeper:

```sh
sudo installer \
  -pkg Canon-G3010-macOS-Compat-1.1.0.pkg \
  -target /
```

### Install from source

```sh
git clone https://github.com/zeallaez/canon-g3010-macos-compat.git
cd canon-g3010-macos-compat
./src/install.sh --test
```

If the printer uses a custom hostname:

```sh
./src/install.sh --host my-printer.local. --test
```

Run `./src/install.sh --help` for every option.

## Scan

Start Docker Desktop, place a document on the flatbed, and run:

```sh
./scanner/scan.sh --ip 192.168.1.50 --output scan.jpg
```

After installing the `.pkg`, the equivalent command is:

```sh
canon-g3010-scan --ip 192.168.1.50 --output scan.jpg
```

The `--ip` option can be omitted when the address is available from the
`Canon_G3010` print queue or DNS-SD. The first run builds the local scanner
runtime from Debian's signed packages. More examples:

```sh
# Detect the WSD scanner without moving the scan head
./scanner/scan.sh --ip 192.168.1.50 --list

# 600 dpi grayscale PNG
./scanner/scan.sh --ip 192.168.1.50 \
  --resolution 600 --mode gray --format png --output document.png

# See every option
./scanner/scan.sh --help
```

This is a real SANE-compatible network scan path. It produces ordinary image
files usable by Preview, Photos, OCR tools, and document applications. It
does not install an ICA plug-in, so the scanner may not appear inside Apple's
Image Capture application.

## Uninstall

```sh
./src/uninstall.sh
```

The uninstaller removes only the `Canon_G3010` queue. It does not remove the
official Canon dependency.

## Diagnose

```sh
./scripts/diagnose.sh
```

The diagnostic script is read-only. It reports macOS, CPU architecture,
installed dependencies, CUPS queue settings, and visible G3010 services.

## How it works

The data path is:

```text
macOS application
      ↓
macOS CUPS raster pipeline
      ↓
Canon Raster2CanonIJS renderer from the official G3000 package
      ↓
BJRaster3-compatible printer data
      ↓
LPD port 515, queue "auto"
      ↓
Canon G3010
```

The scan path is independent:

```text
canon-g3010-scan
      ↓
sane-airscan / SANE inside the local container
      ↓
WSD Scan SOAP + HTTP, local network only
      ↓
Canon G3010 scanner
      ↓
JPEG/PNG/TIFF on the Mac
```

The G3010 advertises IPP 2.0 and PWG Raster, but a 600 dpi macOS driverless
test produced `spool-area-full-report` and remained at 0%. The same printer
accepted the G3000 renderer's compact native data through LPD and completed
the test job. See [How it works](docs/HOW_IT_WORKS.md) for protocol details,
design choices, and limitations.

## Build

On macOS:

```sh
make check
make package
```

Artifacts are written to `dist/`:

- the compatibility `.pkg`;
- a source archive;
- `SHA256SUMS`.

## Known limitations

- Scanning is command-line SANE, not an ICA plug-in for Image Capture.
- Docker Desktop is required for the portable scanner runtime.
- USB printing has not been implemented; the current transport is network LPD.
- The compatibility depends on Canon's G3000 renderer and is not guaranteed by
  Canon.
- Apple has deprecated classic PPD/CUPS vendor drivers. A future macOS release
  may remove this path.
- The release package is not Developer ID signed or notarized.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

Original project code and documentation are licensed under the
[MIT License](LICENSE). Canon software is governed by Canon's own terms and is
not part of this repository. See [NOTICE.md](NOTICE.md).

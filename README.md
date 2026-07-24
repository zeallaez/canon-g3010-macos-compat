# Canon G3010 macOS Compatibility Layer

[简体中文](README.zh-CN.md) · [How it works](docs/HOW_IT_WORKS.md) · [License](LICENSE)

An unofficial, open-source compatibility layer that enables network printing
and scanning from modern macOS to the Canon PIXMA G3010.

Printing pairs:

- Canon's official G3000 macOS CUPS renderer;
- the G3010's native BJRaster3-compatible print language; and
- the printer's raw LPD `auto` queue.

Scanning uses the printer's standards-based WSD Scan service through a native
macOS build of `sane-airscan`. A native AirSane bridge re-publishes it as
eSCL/AirScan for Apple's Image Capture interface.

Tested on an Apple silicon Mac running macOS 26.5.2 with Canon's G3000 CUPS
driver 16.91.0.0. A physical scan initiated from Apple Image Capture was
verified on a Canon G3810 sold as part of the G3010 series.

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
- Appears as `Canon G3010 Scanner` in Apple Image Capture and compatible
  macOS scan panels.
- Supports 150/300/600 dpi, color/grayscale, A4/Letter/full-bed, and
  JPEG/PNG/TIFF/PDF output through the GUI or CLI.
- Uses a reproducible SANE runtime and never requires the printer's web
  administrator password.
- Installs a per-user launch agent that restores the scanner bridge after
  login.
- Builds an installable macOS `.pkg` containing both print and scan wrappers.

## Requirements

- macOS 11 or later;
- a Canon PIXMA G3010 on the same local network;
- Canon G3000 series CUPS Printer Driver 16.91.0.0 or a compatible newer
  release (printing only);
- administrator access when macOS requests it.

Docker Desktop, USB, and the printer's administrator password are not
required for scanning.

Download the Canon dependency from the
[official Canon support page](https://asia.canon/en/support/0101155813?model=PIXMA%20G3000).

The installer verifies that this file exists before changing the print queue:

```text
/Library/Printers/PPDs/Contents/Resources/CanonIJG3000series.ppd.gz
```

## Quick start

### Install from a release package

1. Install Canon's official G3000 CUPS driver.
2. Download `Canon-G3010-macOS-Compat-1.3.0.pkg` from GitHub Releases.
3. Open the package and follow the macOS installer.
4. Print to `Canon G3010 series (Mac compatibility)`.

The package is currently unsigned. If Finder blocks it, use the documented
Terminal method instead of disabling Gatekeeper:

```sh
sudo installer \
  -pkg Canon-G3010-macOS-Compat-1.3.0.pkg \
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

## Scan from the macOS interface

The release package installs the background bridge automatically for the
signed-in user when it can discover the printer. From source, run this once:

```sh
./scanner/bridge/bridge.sh install --ip 192.168.1.50
```

The IP address can be omitted when the installed print queue or DNS-SD service
is available. When running from source, build the native runtime once with
`make native`; release packages already contain it.

Then:

1. Put the original face-down on the scanner glass.
2. Open **Image Capture** (`图像捕捉`).
3. Select **Canon G3010 Scanner** under **Shared**.
4. Choose the size or **Show Details**, then click **Scan**.

Check the bridge without moving the scanner head:

```sh
./scanner/bridge/bridge.sh status
```

After package installation, use
`canon-g3010-scanner-bridge status` instead.

## Scan from the command line

Place a document on the flatbed and run:

```sh
./scanner/scan.sh --ip 192.168.1.50 --output scan.jpg
```

After installing the `.pkg`, the equivalent command is:

```sh
canon-g3010-scan --ip 192.168.1.50 --output scan.jpg
```

The `--ip` option can be omitted when the address is available from the
`Canon_G3010` print queue or DNS-SD. More examples:

```sh
# Detect the WSD scanner without moving the scan head
./scanner/scan.sh --ip 192.168.1.50 --list

# 600 dpi grayscale PNG
./scanner/scan.sh --ip 192.168.1.50 \
  --resolution 600 --mode gray --format png --output document.png

# See every option
./scanner/scan.sh --help
```

The GUI bridge and CLI use the same real SANE-compatible network scan path.
No unsigned ICA plug-in is installed: macOS uses its built-in eSCL/AirScan
client.

## Uninstall

```sh
./src/uninstall.sh
```

The uninstaller removes the `Canon_G3010` queue and this project's per-user
scanner bridge. It does not remove the official Canon printing dependency.

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
native sane-airscan / SANE
      ↓
WSD Scan SOAP + HTTP, local network only
      ↓
Canon G3010 scanner
      ↓
JPEG/PNG/TIFF on the Mac
```

For Image Capture, AirSane adds a standards adapter in front:

```text
Apple Image Capture / macOS scan panel
      ↓  eSCL/AirScan over localhost
native AirSane bridge
      ↓  SANE
sane-airscan
      ↓  WSD Scan SOAP/HTTP
Canon G3010 scanner
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
make native
make package
```

Maintainer builds require Homebrew packages `cmake`, `sane-backends`,
`gnutls`, `jpeg-turbo`, `libpng`, and `libtiff`. The resulting `.pkg` bundles
the native runtime, so end users do not need Homebrew.

Artifacts are written to `dist/`:

- the compatibility `.pkg`;
- a source archive;
- `SHA256SUMS`.

## Known limitations

- The scanner is available while the Mac, printer, and local network are
  running.
- The Bonjour record can be discovered on the local network, but its scanner
  endpoint is bound to this Mac's loopback address and is not remotely
  reachable.
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

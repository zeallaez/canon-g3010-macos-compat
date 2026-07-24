# How the printing and scanning compatibility layer works

[简体中文](HOW_IT_WORKS.zh-CN.md)

## 1. What the printer exposes

The tested G3010 firmware (`3.001`) advertises:

- IPP 1.1 and 2.0 on `/ipp/print`;
- PWG Raster at 600 dpi in sRGB and grayscale;
- LPD on TCP port 515 with remote queue `auto`;
- IEEE-1284 commands including `BJRaster3`, `NCCe`, and `IVEC`;
- color, single-sided A4/Legal media, photo media, envelopes, and borderless
  sizes.

The printer does not advertise PostScript or PCL. Generic PostScript and PCL
PPDs therefore cannot drive it.

## 2. Why the driverless IPP path was not selected

A driverless `IPP Everywhere` queue was created successfully and macOS
discovered the expected media and color capabilities. During the print test,
however, the printer reported:

```text
printer-state-reasons = spool-area-full-report
printer-alert-description = Non-critical alert - spool area full
job-media-progress = 0
```

The job remained in `processing` at 0%. This indicates that the advertised PWG
Raster path exists but is not robust with the 600 dpi raster stream generated
by the tested macOS version.

## 3. Why the G3000 renderer is usable

Canon's G3000 macOS package contains:

- `CanonIJG3000series.ppd.gz`;
- `Raster2CanonIJS`, a universal arm64/x86_64 CUPS raster filter;
- the G3000 model database and color profile;
- native network and printer utility components.

The G3010 reports `BJRaster3` support. The G3000 filter emits Canon's compact
native raster stream for a closely related print engine. Sending this stream
to the G3010's raw LPD queue completed the test job and returned the device to
idle with no alert.

This is a tested compatibility relationship, not a compatibility guarantee
from Canon.

## 4. Printing data flow

```text
Document or image
    │
    ▼
macOS print framework / CUPS
    │  application/vnd.cups-raster
    ▼
Canon Raster2CanonIJS
    │  BJRaster3-compatible native stream
    ▼
macOS LPD backend
    │  TCP 515, remote queue "auto"
    ▼
Canon G3010 firmware and print engine
```

The open-source code in this repository configures and validates this path.
It does not copy, patch, reverse engineer, or redistribute Canon binaries.

## 5. Scanner protocol

The G3010 exposes a WSD device whose metadata includes
`wscn:ScanDeviceType`. Its scanner endpoint is the local HTTP service:

```text
http://PRINTER_IP:80/wsd/scanservice.cgi
```

WSD Scan uses SOAP messages over HTTP. The backend first asks the device for
its scanner elements and configuration, creates a scan job using the selected
resolution, color mode, and rectangle, then retrieves the image stream.

The project uses the open-source `sane-airscan` backend to translate between
this WSD Scan protocol and the standard SANE API. `scanimage` exposes the
result to the CLI. For macOS applications, AirSane translates the same SANE
device into the standard eSCL/AirScan protocol that Apple's built-in scanner
client understands. No Canon scanner binary, private password, USB connection,
or cloud service participates in this path.

## 6. Scanning data flow

```text
Apple Image Capture / macOS scan panel
    │  eSCL/AirScan
    ▼
native macOS AirSane process
    │  SANE API
    ▼
sane-airscan WSD backend
    │  SOAP/HTTP over the local network
    ▼
G3010 /wsd/scanservice.cgi
    │
    ▼
JPEG/PNG/PDF returned to the macOS application
```

The optional CLI path uses the bundled native `scanimage` and writes JPEG,
PNG, or TIFF directly to a selected Mac path.

Pinned upstream revisions and the included portability patches provide a
reproducible native runtime without modifying macOS system frameworks or
installing an unsigned ICA bundle. The bridge listens only on the loopback
interface and reads only its generated configuration.

The physical device reported and successfully used these capabilities:

- flatbed source;
- 150, 300, and 600 dpi;
- color and grayscale;
- maximum scan area 215.9 × 296.672 mm.

## 7. Discovery

When no hostname is supplied, the installer resolves:

```text
Canon G3010 series._printer._tcp.local.
```

using DNS-SD and extracts the target hostname from the service record. A
hostname can also be passed explicitly with `--host`.

For scanning, the wrapper first tries the installed CUPS queue, then the same
DNS-SD service. `--ip` bypasses discovery. A generated `sane-airscan`
configuration points directly to the device's WSD scanner endpoint, avoiding
multicast discovery and keeping the runtime deterministic.

The GUI bridge publishes `Canon G3010 Scanner._uscan._tcp.local.` from the Mac
with `rs=eSCL`, using the dedicated proxy host
`canon-g3010-bridge.local.` at `127.0.0.1:8090`. Image Capture discovers that
Bonjour record and sends eSCL requests through the Mac's loopback interface.
The per-user launch agent keeps both the service record and bridge alive after
login.

## 8. Defaults

The installer selects conservative settings shared by G3000 and G3010:

- A4;
- plain paper;
- color enabled;
- normal quality;
- rear/main feed;
- one-sided printing.

Photo, grayscale, borderless, and quality settings remain available in the
macOS print dialog.

The scanner defaults to A4, 300 dpi, color, and JPEG.

## 9. Security and privacy

- Discovery stays on the local network.
- No document data is sent to this project or to a cloud service.
- Print jobs and scans are transmitted directly between the Mac and printer.
- The printer's web administrator password is not used or stored.
- The CLI writes only to the output path selected by the user.
- The GUI eSCL port is bound to `127.0.0.1`; other LAN devices cannot connect
  to it even though they may see the Bonjour record.
- The scripts do not collect telemetry.
- The project does not disable Gatekeeper or System Integrity Protection.

## 10. Compatibility boundary

- Native open-source BJRaster3 renderer independent of Canon's G3000 package;
- native ICA plug-in implementation (the current GUI path uses Apple's built-in
  eSCL/AirScan client);
- Developer ID signing and notarization;
- automated testing on more macOS releases and firmware versions.

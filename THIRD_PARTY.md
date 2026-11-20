# Third-party software

Copyright 2026 Canon MP250 Printer Application contributors. The original
project code is available under [Apache-2.0](LICENSE).

The `canon-mp250-app` executable combines the upstream libraries below. The
combined executable is distributed under [GPL-3.0](licenses/GPL-3.0.txt).
The original licenses and notices for each component continue to apply.

| Component | Version | Upstream license and notices |
| --- | --- | --- |
| [Gutenprint](https://gimp-print.sourceforge.io/) and its model XML | 5.3.4 | [GPL-2.0-or-later](licenses/Gutenprint-COPYING.txt). The build uses the GPLv3 option for the combined executable. |
| [PAPPL](https://github.com/michaelrsweet/pappl) | 1.4.10 | [Apache-2.0](licenses/PAPPL-LICENSE.txt) with its [optional exceptions and notices](licenses/PAPPL-NOTICE.txt) |
| [libusb](https://github.com/libusb/libusb) | 1.0.30 | [LGPL-2.1-or-later](licenses/libusb-COPYING.txt) |
| [OpenSSL](https://github.com/openssl/openssl) | 3.5.8 | [Apache-2.0](licenses/OpenSSL-LICENSE.txt) |

`mp250-diag` links with libusb. Its source, the libusb source, and the
build instructions in the corresponding-source archive allow recompiling and
relinking the tool with a modified libusb. System libraries come from macOS.

Use the corresponding-source archive of the same version as the install ZIP.
It includes the project source, build scripts and exact upstream archives.
The upstream archive checksums are in `scripts/bootstrap-deps.sh`. Build on
Apple Silicon with macOS 27 and Xcode Command Line Tools:

```sh
./scripts/bootstrap-deps.sh
make
```

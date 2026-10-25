# Qargo Autofill - licence and third-party notices

## Licence of this package

`pdf_layout.py` is a Python port of part of **poppler** (the "physical layout" text output of
`TextOutputDev.cc`). poppler is licensed under the GNU General Public License, version 2 or (at your
option) any later version: Copyright 1996-2011, 2022 Glyph & Cog, LLC; 2005-2026 The Poppler Developers.
`pdf_layout.py` is a derived work and carries the same licence.

Because that file is part of the program, the package as it is distributed (the release zip and the
installers that fetch it) is offered under **GPL-2.0-or-later**. The full text is in
[`LICENSES/GPL-2.0-or-later.txt`](LICENSES/GPL-2.0-or-later.txt). The release zip contains the complete
source code of the program; nothing in it is compiled or obfuscated. The names of the company that runs it,
of its customers and of its people are not in it: the code writes each as a placeholder ("Sx", four digits, "x"),
and the launcher puts the names back on the user's computer from a site profile that is not public
(`qargo_launcher.py`, `fill_in_site`). Anyone else uses the program with a site profile of their own.

The program comes with no warranty, as set out in sections 11 and 12 of that licence.

## Third-party components

None of these are inside the release zip. They are downloaded onto the user's computer when the program
is installed, each under its own licence.

Python packages installed from PyPI (exact versions and hashes are in `uv.lock`):

| Component | Licence |
|---|---|
| pdfminer.six | MIT |
| charset-normalizer (used by pdfminer.six) | MIT |
| cryptography (used by pdfminer.six) | Apache-2.0 OR BSD-3-Clause |
| cffi (used by cryptography) | MIT-0 |
| pycparser (used by cffi) | BSD-3-Clause |
| playwright | Apache-2.0 |
| the driver bundled inside the playwright package: Playwright (Apache-2.0) and the Node.js runtime (MIT, with the notices in its `LICENSE` file) | Apache-2.0, MIT and others |
| greenlet (used by playwright) | MIT AND PSF-2.0 |
| pyee (used by playwright) | MIT |
| typing-extensions (used by pyee) | PSF-2.0 |

Programs the installer or the launcher downloads:

| Component | From | Licence |
|---|---|---|
| uv | Astral (github.com/astral-sh/uv) | Apache-2.0 OR MIT |
| CPython (the standalone builds uv installs) | Python Software Foundation; built by Astral (python-build-standalone) | PSF-2.0, plus the licences of the libraries bundled in the build (OpenSSL, SQLite, Tcl/Tk and others) |
| Chromium ("Chrome for Testing"), downloaded by Playwright | The Chromium Authors / Google | BSD-3-Clause and others |

The licence texts of the PyPI packages are installed next to them (the `*.dist-info/licenses` folders of
the virtualenv); those of uv, CPython and Chromium come with their downloads.

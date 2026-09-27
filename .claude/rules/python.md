---
description: Python tool scripts — never shipped; usage docstring, importable names, declared deps.
paths:
  - "tools/**/*.py"
---

These run on a developer's machine only (system Python 3.12); nothing here reaches the app.

- **The module docstring is the usage message** (PEP 257): what it does, the exact command line,
  the files it reads and writes.
- **There is no requirements file**, so a third-party import (fontTools, Pillow, numpy) puts its
  `pip install` line in that docstring, as `build-fonts.py` does. Imports group stdlib, third-party,
  local, with a blank line between (PEP 8).
- **Name a new script `snake_case.py`** (PEP 8): a hyphenated file cannot be imported, and
  `device_sweep.py` already imports `scan_overflow_banner`.

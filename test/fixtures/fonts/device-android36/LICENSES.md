# Font fixtures — provenance and licences

Test-only. **Never referenced from `pubspec.yaml`** — nothing here ships in the
AAB. They exist so `flutter test` can measure real text instead of the
FlutterTest box face; see `test/l10n/support/load_real_fonts.dart`.

## Where they came from

Pulled with `adb pull /system/fonts/...` from the stock Android 16 emulator
system image used by the AVD `Medium_Phone_API_36.0`:

```
ro.build.fingerprint = google/sdk_gphone64_x86_64/emu64xa:16/BP22.250325.006
```

Using the device's own faces is the point: Arul bundles no Latin or Indic UI
font (`lib/app/theme/typography.dart` leaves `fontFamily` null on purpose), so
the widths a user actually sees are the widths of *these* files.

## Licences

| Files | Licence |
| --- | --- |
| `Roboto-Regular.ttf`, `RobotoFlex-Regular.ttf`, `RobotoStatic-Regular.ttf` | Apache License 2.0 |
| `NotoSans*`, `NotoSerif*` (Tamil, Telugu, Kannada, Malayalam, Devanagari, incl. the `…UI` cuts) | SIL Open Font License 1.1 |

Both licences permit redistribution and modification. The `instanced/`
subdirectory holds derived works — static instances cut from the variable
originals by `tools/l10n/instance_fonts.py` — which is a modification the OFL
and Apache-2.0 both allow. No instance is renamed to a reserved font name.

## Regenerating

```bash
python tools/l10n/instance_fonts.py     # rebuilds instanced/ from the VFs here
```

Re-pulling the originals: boot the AVD, then pull every `/system/fonts` file
matching `roboto|tamil|telugu|kannada|malayalam|devanagari` and update the
fingerprint above.

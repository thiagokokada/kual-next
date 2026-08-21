# AGENTS.md

## Project intent

KUAL Next is a native launcher for existing KUAL JSON extensions on recent
jailbroken Kindles. Target hard-float firmware 5.16.3 and newer. Java,
Kindlets, Booklets, pre-hard-float devices, non-JSON menus, and KUAL's legacy
mailbox/cache protocol are intentionally out of scope.

Keep compatibility with the original KUAL JSON behavior where it is relevant
to modern extensions. Use small C libraries and avoid adding a large UI or JSON
framework.

## Repository layout and dependencies

- `src/` contains menu parsing, condition evaluation, command execution, and
  the FBInk/evdev UI.
- `include/kual.h` contains shared project types and interfaces.
- `tests/fixtures/` contains representative KUAL extensions.
- `assets/` contains the SH Integration scriptlet and bundled Noto fonts.
- `third_party/FBInk` is a pinned recursive Git submodule. Do not replace it
  with a path outside this repository or modify its upstream sources as part
  of normal project work.
- `third_party/jsmn.h` is the vendored JSON parser.
- `third_party/yxml.c` and `third_party/yxml.h` are the vendored XML parser.

Initialize dependencies after cloning:

```sh
git submodule update --init --recursive
```

## Build and verification

This is a NixOS development environment. Enter the pinned shell before
building:

```sh
nix develop
make test
```

The one-time Kindle toolchain setup is:

```sh
nix develop
make toolchain
```

Do not patch koxtoolchain or its upstream sources. The project uses a
`buildFHSEnv`-based wrapper to satisfy its FHS assumptions.

Before handing off a Kindle-facing change, run:

```sh
nix develop
make package
```

This runs parser tests, bundled-font coverage tests, the ARM hard-float ABI
check, and the static-link check. The resulting archive is written under
`dist/`. Build products, toolchains, caches, and packages are generated files
and must not be committed.

## Implementation constraints

- Write portable C11 and keep the existing warning-clean build flags.
- Continue using FBInk for drawing and Linux evdev for input.
- Keep the device binary statically linked unless a separate design decision
  explicitly changes that constraint.
- Use the bundled Noto fonts. Never load fonts or resources from the Kindle's
  Java installation.
- Preserve KUAL semantics for `exitmenu`, `checked`, `refresh`, `status`,
  `date`, conditions, nested items, and working directories.
- Keep runtime checked state separate from the configured entry name.
- Render KUAL UI indicators with the bundled Noto Symbols fonts; update
  `tests/check-fonts.sh` when introducing another built-in symbol.
- Keep screen geometry and touch hitboxes derived from the same dimensions.

## Kindle framework policy

The Amazon Home/framework may repaint over direct framebuffer content. KUAL
Next may stop only the separate Upstart `statusbar` service while its UI is
visible, provided it records whether the service was originally running and
restores it before launching an `exitmenu` action and on every exit path. Keep
the scriptlet supervisor fallback so a launcher crash also restores the
service. `/sbin/start statusbar` is the on-device recovery command.

Do not stop or suspend `awesome`, Pillow, `KPPMainApp`, or `lab126_gui`, and do
not restore saved framebuffer dumps. Those broader approaches interfered with
applications launched from the menu and could leave a blank screen after
KOReader exited. Continue listening for Kindle screen-saver events, releasing
input grabs while locked, and issuing a deferred full redraw after unlock.

An Awesome-managed X11 ownership window has been considered but is explicitly
deferred. Do not introduce X11 ownership or framework lifecycle management
without a new user decision and an on-device recovery plan.

## Packaging and commits

The package must continue to install these public paths:

- `/mnt/us/documents/KUAL Next.sh`
- `/mnt/us/kual-next/bin/kual-next`
- `/mnt/us/kual-next/fonts/`
- `/mnt/us/kual-next/LICENSES/`

Keep unrelated changes out of commits. When a request contains independent
structural, behavior, and visual fixes, create separate verified commits for
each concern. Preserve existing user changes and never rewrite or reset history
unless explicitly requested.

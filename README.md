# KUAL Next

KUAL Next is a native launcher for existing KUAL JSON extensions on jailbroken
Kindles running hard-float firmware 5.16.3 or newer. It uses FBInk and Linux
evdev directly; Java, Kindlets, and Booklets are not required.

The interface uses bundled OFL-licensed Noto Sans and Noto Sans Symbols fonts.
It does not load fonts or other resources from the Kindle's Java installation.

## Supported extension contract

The launcher scans `/mnt/us/extensions` for `config.xml` files and their JSON
menus. It supports nested `items`, actions and parameters, priorities, KUAL's
RPN `if` expressions, `exitmenu`, `checked`, `refresh`, `status`, `date`,
`hidden`, internal breadcrumb/status messages, collation, and relevant
`KUAL.cfg` discovery and sorting options.

Non-JSON menus, KUAL's Java mailbox/cache protocol, the old self-management
menu, TouchRunner output, and pre-hard-float firmware are intentionally out of
scope.

## Native development and validation

Enter the pinned Nix environment and run the host tests:

```sh
nix develop
make test
```

Validate an extension tree without opening a framebuffer:

```sh
build/host/kual-next --validate --extensions /path/to/extensions --model KindlePaperWhite5
```

## Kindle cross-build

The one-time toolchain bootstrap downloads and builds koxtoolchain's
`kindlehf` target into `.toolchains/`. The Make target enters a lightweight
FHS environment so upstream assumptions such as `/bin/pwd` work on NixOS:

```sh
nix develop
make toolchain
make check
make package
```

The FHS environment also pins Autoconf 2.69, which is required when
koxtoolchain regenerates glibc 2.20's configure script. The bootstrap uses the
pinned upstream sources unchanged; it only sets the generated crosstool-ng
installation prefix so the result stays inside this project.

FBInk is pinned as a recursive Git submodule. Clone with
`git clone --recurse-submodules`, or initialize an existing checkout with
`git submodule update --init --recursive`, before building.

The package is written to `dist/kual-next-0.1.0-kindlehf.zip`. Extract it at
the Kindle USB storage root so that `documents/KUAL Next.sh` and
`kual-next/bin/kual-next` land under `/mnt/us`. SH Integration indexes the
scriptlet as a library item and restores the stock interface when it exits.

Runtime diagnostics are appended to `/var/tmp/kual-next.log`.

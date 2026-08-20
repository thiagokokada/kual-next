# KUAL Next

KUAL Next is a native launcher for existing KUAL JSON extensions on jailbroken
Kindles running hard-float firmware 5.16.3 or newer. It uses FBInk and Linux
evdev directly; Java, Kindlets, and Booklets are not required.

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

The one-time toolchain bootstrap downloads and builds
[koxtoolchain's](https://github.com/koreader/koxtoolchain) `kindlehf` target
into `.toolchains/`.

```sh
nix develop
make toolchain
make check
make package
```

The package is written to `dist/kual-next-<version>-kindlehf.zip`. Extract it
at the Kindle USB storage root so that `documents/KUAL Next.sh` and
`kual-next/bin/kual-next` land under `/mnt/us`.

Runtime diagnostics are appended to `/var/tmp/kual-next.log`.

# KUAL Next

KUAL Next is a native launcher for existing KUAL JSON extensions on jailbroken
Kindles running hard-float firmware 5.16.3 or newer. It uses FBInk and Linux
evdev directly; Java, Kindlets, and Booklets are not required.

![Screenshot](./assets/screenshot.png)

## Install on your Kindle

### Before you start

KUAL Next is for jailbroken Kindles running firmware 5.16.3 or newer. It does
not jailbreak your Kindle. Your jailbreak must also include **SH Integration**,
which is what makes `.sh` launchers appear as books in the Kindle library. You
do not need to install the old Java-based KUAL launcher.

If you can already open other `.sh` launchers from your Kindle library, your
device is ready.

### Installation

1. Open the [latest KUAL Next
   release](https://github.com/thiagokokada/kual-next/releases/latest).
2. Under **Assets**, download the file named
   `kual-next-<version>-kindlehf.zip`. Do not download either of the files
   named **Source code**.
3. Connect your Kindle to your computer with a USB cable and open the Kindle
   drive.
4. Unzip the downloaded file on your computer. Copy both the `documents` and
   `kual-next` folders to the top level of the Kindle drive—the same place
   where the existing `documents` folder is located. If your computer asks,
   choose to merge the `documents` folders and replace existing KUAL Next
   files. Do not delete your other documents.
5. Check that the files are not inside an extra folder. The Kindle drive should
   contain these paths:

   ```text
   documents/KUAL Next.sh
   kual-next/bin/kual-next
   ```

6. Safely eject the Kindle, unplug the USB cable, and wait for its library to
   refresh.
7. Find **KUAL Next** in the Kindle library and tap it to open the launcher.
   Existing compatible extensions in the Kindle's `extensions` folder should
   appear automatically.

### Updating

Close KUAL Next, download the new `kual-next-<version>-kindlehf.zip`, and repeat
the copy steps above. Allow your computer to replace the existing KUAL Next
files. Your installed extensions are stored separately and will not be removed.

## Supported extension contract

The launcher scans `/mnt/us/extensions` for `config.xml` files and their JSON
menus. It supports nested `items`, actions and parameters, priorities, KUAL's
RPN `if` expressions, `exitmenu`, `checked`, `refresh`, `status`, `date`,
`hidden`, internal breadcrumb/status messages, collation, and relevant
`KUAL.cfg` discovery and sorting options.

Non-JSON menus, KUAL's Java mailbox/cache protocol, the old self-management
menu, TouchRunner output, and pre-hard-float firmware are intentionally out of
scope.

## Limitations compared with KUAL

| Area | Limitation |
| --- | --- |
| Display ownership | KUAL Next draws directly through FBInk and is not registered as a Kindle framework window. It suppresses the KPP status bar while visible and redraws after screen unlock, but unrelated framework windows may still repaint over it. |
| Legacy extensions | Only `config.xml` files referencing JSON menus are supported. Non-JSON menus and extensions requiring Java, Kindlet, or Booklet APIs do not work. |
| Dynamic menus | Menus are loaded at startup and after an item with `"refresh": true`; KUAL's cache and mailbox protocol for live menu updates is not implemented. |
| Command output | Action stderr is appended to `/var/tmp/kual-next.log`, but output is not presented in the launcher. TouchRunner-style output, progress displays, cancellation, and interactive terminal handling are unavailable. |
| Input | Touch, Home/Menu, back, next, and a small set of page-key aliases are supported. KUAL's numeric/QWERTY item shortcuts and Java focus navigation are not. |
| Configuration | Discovery depth, path exclusion, symlink following, collation, and `ABC`, `ABC!`, and `123` sorting are supported. UI settings such as `KUAL_no_show_status` and the self-management menu are not. |
| Parsing | `config.xml` is handled by the small, non-validating yxml parser. XML syntax, nesting, entities, CDATA, and processing instructions are supported; DTD validation and custom entity declarations are not. |
| Fonts | Bundled Noto fonts cover KUAL's standard indicators and many scripts and symbols, but there is no font fallback; unsupported characters may be rendered as squares. |
| Devices | Only recent ARM hard-float Kindles running firmware 5.16.3 or newer are targeted. Older ARMEL and keyboard-era devices are unsupported. |
| Menu size | Menus are limited to ten nesting levels and ten visible rows per page. |

## Tested extensions

- https://github.com/Satsuoni/DeDRM_tools/
- https://github.com/bfabiszewski/kterm
- https://github.com/koreader/koreader
- https://github.com/mitanshu7/tailscale_kual

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

Build and deploy the package over SSH:

```sh
nix develop
make deploy KINDLE_HOST=root@your-kindle
```

`KINDLE_HOST` is required and is never given a repository default. The target
honors the `SSH` and `SCP` environment variables, verifies the uploaded archive,
and refuses to overwrite KUAL Next while it is running. Quit the launcher before
deploying, then open it again through the Kindle scriptlet UI.

### Interactive device UI test

To inspect pagination and exercise safe dummy actions without changing the
installed launcher or `/mnt/us/extensions`, quit KUAL Next and run:

```sh
nix develop
make device-ui-test KINDLE_HOST=root@your-kindle
```

The target stages the current device binary and test extensions under
`/tmp/kual-next-ui-test`, then opens KUAL Next with that isolated extension
tree. Keep the SSH command attached while testing and quit the launcher when
finished. The status bar is restored and the staged files are removed on exit.

The fixture contains a multi-page test menu and a nested multi-page submenu,
plus collation, breadcrumb and status messages, checked/date/refresh behaviors,
and harmless actions that append to `/var/tmp/kual-next-ui-test.log`. Action
stderr also exercises the normal `/var/tmp/kual-next.log` path. Neither log is
deleted automatically so it can be inspected after the test.

## Kindle cross-build

The toolchain setup downloads a prebuilt
[koxtoolchain](https://github.com/koreader/koxtoolchain), `kindlehf` target
into `.toolchains/`.

```sh
nix develop
make toolchain
make check
make package
```

The package is written to `dist/kual-next-<version>-kindlehf.zip`. Extract it
at the Kindle USB storage root for testing. The scriptlet metadata uses the
bundled `kual-next/icon.png` as its Kindle library cover.

Runtime diagnostics are appended to `/var/tmp/kual-next.log`.

## Releases

`VERSION` is the single release version source. After the version change has
landed on `main` and CI has passed, create and push the matching stable SemVer
tag, then run the `Release` workflow with that tag:

```sh
git tag "v$(cat VERSION)"
git push origin "v$(cat VERSION)"
```

The workflow verifies that the existing tag matches `VERSION` and belongs to
`main`, rebuilds the package from the tagged source, and publishes the package
and its SHA-256 checksum with generated release notes. It does not create tags
or publish prereleases.

{
  description = "KUAL Next Kindle hard-float development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    koxtoolchain = {
      url = "github:koreader/koxtoolchain";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      koxtoolchain,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      toolchainPackages = with pkgs; [
        autoconf269
        automake
        bash
        binutils
        bison
        bzip2
        coreutils
        curl
        file
        flex
        gawk
        gcc
        gettext
        git
        glibc.static
        gnumake
        gperf
        gzip
        help2man
        libtool
        ncurses
        patch
        perl
        pkg-config
        python3
        rsync
        texinfo
        unzip
        wget
        which
        xz
        zip
      ];
      devPackages = with pkgs; [
        bash
        clang-tools
        file
        fontconfig
        gcc
        git
        gnumake
        gnutar
        openssh
        patch
        perl
        pkg-config
        unzip
        zip
      ];
      toolchainFhs = pkgs.buildFHSEnv {
        name = "kual-toolchain-fhs";
        targetPkgs = _: toolchainPackages;
        profile = ''
          unset NIX_CFLAGS_COMPILE NIX_CFLAGS_LINK NIX_LDFLAGS
          unset NIX_HARDENING_ENABLE NIX_ENFORCE_NO_NATIVE
        '';
        runScript = "bash";
      };
    in
    {
      packages.${system}.toolchain-fhs = toolchainFhs;

      devShells.${system}.default = pkgs.mkShell {
        packages = devPackages ++ [ toolchainFhs ];
        KOXTOOLCHAIN_SRC = "${koxtoolchain}";
      };
    };
}

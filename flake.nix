{
  description = "KUAL Next Kindle hard-float development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      devPackages = with pkgs; [
        actionlint
        bash
        clang-tools
        curl
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
        zstd
      ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = devPackages;
      };
    };
}

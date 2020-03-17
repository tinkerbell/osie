let
  _pkgs = import <nixpkgs> {};
in
{ pkgs ? import (_pkgs.fetchFromGitHub { owner = "NixOS";
                                         repo = "nixpkgs-channels";
                                         # nixos-unstable @2019-05-28
                                         rev = "eccb90a2d997d65dc514253b441e515d8e0241c3";
                                         sha256 = "0ffa84mp1fgmnqx2vn43q9pypm3ip9y67dkhigsj598d8k1chzzw";
                                       }) {}
}:

with pkgs;

mkShell {
  buildInputs = [
    bash
    curl
    docker
    git
    git-lfs
    gnumake
    gnused
    libarchive
    minio
    pigz
    python3
    python3Packages.black
    python3Packages.bpython
    python3Packages.colorama
    python3Packages.dpath
    python3Packages.faker
    python3Packages.flake8
    python3Packages.grpcio
    python3Packages.grpcio-tools
    python3Packages.pip
    python3Packages.pip-tools
    python3Packages.pylama
    python3Packages.pytest
    python3Packages.pytestcov
    python3Packages.structlog
    rsync
    shellcheck
    shfmt
    unzip
    wget
    zip
  ];
}

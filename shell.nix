let _pkgs = import <nixpkgs> { };
in { pkgs ? import (_pkgs.fetchFromGitHub {
  owner = "NixOS";
  repo = "nixpkgs";
  #branch@date: nixpkgs-unstable@2020-11-04
  rev = "dfea4e4951a3cee4d1807d8d4590189cf16f366b";
  sha256 = "02j7f5l2p08144b2fb7pg6sbni5km5y72k3nk3i7irddx8j2s04i";
}) { } }:

with pkgs;

mkShell {
  buildInputs = [
    bash
    cpio
    curl
    docker
    git
    git-lfs
    gnumake
    gnused
    libarchive
    minio-client
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
    python3Packages.j2cli
    python3Packages.pip
    python3Packages.pip-tools
    python3Packages.pylama
    python3Packages.pytest
    python3Packages.pytestcov
    python3Packages.structlog
    shellcheck
    shfmt
    unzip
    wget
    zip
  ];
}

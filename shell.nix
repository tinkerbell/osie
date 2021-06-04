let _pkgs = import <nixpkgs> { };
in { pkgs ? import (_pkgs.fetchFromGitHub {
  owner = "NixOS";
  repo = "nixpkgs";
  #branch@date: nixpkgs-unstable@2021-01-25
  rev = "ce7b327a52d1b82f82ae061754545b1c54b06c66";
  sha256 = "1rc4if8nmy9lrig0ddihdwpzg2s8y36vf20hfywb8hph5hpsg4vj";
}) { } }:

with pkgs;

mkShell {
  buildInputs = [
    (docker.override { buildxSupport = true; })
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

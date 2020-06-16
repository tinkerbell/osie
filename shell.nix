let _pkgs = import <nixpkgs> { };
in { pkgs ? import (_pkgs.fetchFromGitHub {
  owner = "NixOS";
  repo = "nixpkgs-channels";
  #branch@date: nixpkgs-unstable@2020-04-23
  rev = "b95699970fb7d825fd4a710f5cfa3785a98435db";
  sha256 = "0s9pjym3wi3ssp33cd2sj8fs9dlny5yhc7lhnj2lzadx8ianbf72";
}) { } }:

with pkgs;

let
  shfmt = buildGoPackage rec {
    pname = "shfmt";
    version = "2.6.4";

    src = fetchFromGitHub {
      owner = "mvdan";
      repo = "sh";
      rev = "v${version}";
      sha256 = "1jifac0fi0sz6wzdgvk6s9xwpkdng2hj63ldbaral8n2j9km17hh";
    };

    goPackagePath = "mvdan.cc/sh";
    subPackages = [ "cmd/shfmt" ];
    buildFlagsArray = [ "-ldflags=-s -w -X main.version=${version}" ];

  };

in mkShell {
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
    python3Packages.j2cli
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

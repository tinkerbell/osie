# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/) though uses different version number scheme (YY.MM.DD.NN) where NN is build number.

## Unreleased

### Added
- Update packet-networking submodule (for some retry logic)
- Add Ubuntu 20.10 GRUB templates
- Add missing x.small GRUB templates
- Bypass kexec for t1.small and Ubuntu 20
- Bypass kexec for c3.medium and Ubuntu 16
- Remove Supermicro UEFI workarounds
- Add Ubuntu 20.04 repos
- Enable kexec bypass for centos 8 on t1.small.x86
- Add Ubuntu 20.04 GRUB templates
- Remove c3.medium from kexec bypass
- Strip biosdevname and net.ifname GRUB flags for Debian 10
- workflow mode to allow users to execute workflows

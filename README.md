# kvm-nocloud

kvm-nocloud is a set of shell scripts for building KVM virtual machines using upstream cloud images, NoCloud cloud-init metadata, and optional Vagrant box packaging. Everything is implemented using standard tools like cloud-init, qemu-img, virt-install, and libvirt.

The project keeps configuration simple by using a single inventory.toml file that defines VM settings, networking, cloud-init userdata, and optional XML modifications for libvirt.

The system is designed for fast rebuilds, deterministic VM definitions, and clean Vagrant integration without using full Packer builds.

## Features

- Build VMs from upstream cloud images
- Optional creation of Vagrant libvirt boxes
- Direct install into ~/.vagrant.d without producing a .box file
- XML patching for advanced libvirt configuration
- Per-VM cloud-init userdata overrides

## Requirements

- `kvm`
- `libvirt`
- `virt-install`
- `qemu-img`
- `cloud-localds`

## Quick Start

- Clone the repo

```bash
git clone git@github.com:badukoos/kvm-nocloud

```
- Adjust inventory.toml

`ssh_user`, `ssh_key` and `ssh_authorized_keys` in `userdata_yaml` at a minimum should be updated

- Build VM

```
VM=debian12 ./vm.sh
```

- Rebuild VM

```
VM=debian12 REBUILD=1 ./vm.sh
```

- Destroy VM

```
VM=debian12 DESTROY=1 ./vm.sh
```

- Purge disks

```
VM=debian12 DESTROY=1 PURGE_DISKS=1 ./vm.sh
```
**Note:** Currently `inventory.toml` is populated with the official `debian12`, `fedora42`, `ubuntu24` and `centos-stream9` qcow2 files

## Networking

- Static mode

```
mode = "static"
ip   = "192.168.122.150"
gw   = "192.168.122.1"
```

- DHCP mode

```
mode = "dhcp"
```

Templates for networking live under `templates/`.

## Advanced options

`inventory.toml` supports XML patch entries, for example if you want to enable shared memorybacking for virtio shares

```
xml = [
  "xpath.create=./memoryBacking",
  "xpath.create=./memoryBacking/source",
  "./memoryBacking/source/@type=memfd",
  "xpath.create=./memoryBacking/access",
  "./memoryBacking/access/@mode=shared"
]
```

## Vagrant Packaging

To package a Vagrant box

```
VM=debian12 VAGRANT_BOX=1 ./vm.sh
```

Direct installation into `~/.vagrant.d`

```
VM=debian12 VAGRANT_BOX=1 DIRECT_INSTALL=1 ./vm.sh
```
**Note**: The default is `DIRECT_INSTALL=0` which means your vagrant box will reside in the `build/` folder and
you have ti use `vagrant box add` manually

## SELinux Notes

`templates/vagrant-selinux-fix.service` applies adjustments for Vagrant workflow on SELinux enabled hosts

## Gotchas

- Many cloud images disable root login and password authentication. Ensure `ssh_authorized_keys` is set in userdata.
- Some cloud images like Debian may not ship `qemu-guest-agent`
- SELinux may block Vagrant unless vagrant-selinux-fix.service is applied
- Set `KEEP_INSTANCE_ID=1`if rebuilds cause cloud-init to skip configuration.

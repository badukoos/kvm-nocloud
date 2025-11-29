# kvm-nocloud

kvm-nocloud is a set of shell scripts for building KVM virtual machines using upstream cloud images, NoCloud cloud-init metadata, and optional Vagrant box packaging. Everything is implemented using standard tools like cloud-init, qemu-img, virt-install, libvirt and yq.

The project keeps configuration simple by using a single **inventory.yml** file that defines VM settings, networking, cloud-init userdata, and optional XML modifications for libvirt.

The system is designed for fast rebuilds, deterministic VM definitions, and Vagrant integration without using full Packer builds.

## Features

* Build VMs from upstream cloud images
* Optional creation of Vagrant libvirt boxes
* Direct install into ~/.vagrant.d without producing a .box file
* XML patching for advanced libvirt configuration
* Per-VM cloud-init userdata overrides

## Requirements

* `libvirt`
* `virt-install`
* `qemu-img`
* `cloud-localds`
* `yq`

## Quick Start

* Clone the repo

```bash
git clone git@github.com:badukoos/kvm-nocloud
```

* Adjust `inventory.yml`

At minimum, update `ssh_authorized_keys` inside the default `userdata_yaml` block along with `ssh_user` and `ssh_key`

* Build VM

```bash
VM=debian12 ./vm.sh
```

* Rebuild VM

```bash
VM=debian12 REBUILD=1 ./vm.sh
```

* Destroy VM

```bash
VM=debian12 DESTROY=1 ./vm.sh
```

* Purge disks

```bash
VM=debian12 DESTROY=1 PURGE_DISKS=1 ./vm.sh
```

**Note:** The provided inventory contains upstream URLs for Debian 12, Fedora 42, Ubuntu 24, and CentOS Stream 9 cloud images.

## Networking

* Static mode

```yaml
mode: "static"
ip: "192.168.122.150"
gw: "192.168.122.1"
```

* DHCP mode

```yaml
mode: "dhcp"
```

## Advanced options

`inventory.yml` supports XML patch entries using simple YAML lists. Example enabling shared memory backing

```yaml
xml:
  - "xpath.create=./memoryBacking"
  - "xpath.create=./memoryBacking/source"
  - "./memoryBacking/source/@type=memfd"
  - "xpath.create=./memoryBacking/access"
  - "./memoryBacking/access/@mode=shared"
```

## Vagrant Packaging

To package a Vagrant box

```bash
VM=debian12 VAGRANT_BOX=1 ./vm.sh
```

Direct installation into `~/.vagrant.d`

```bash
VM=debian12 VAGRANT_BOX=1 DIRECT_INSTALL=1 ./vm.sh
```

**Note:** The default is `DIRECT_INSTALL=0`, meaning the box is created under `build/` and must be added manually via `vagrant box add`.

## SELinux Notes

`templates/vagrant-selinux-fix.service` applies SELinux adjustments required by the Vagrant libvirt workflow.

## Gotchas

* Many cloud images disable root login and password authentication. Ensure `ssh_authorized_keys` is set.
* Some cloud images may not ship `qemu-guest-agent`.
* SELinux may block Vagrant unless the fix service is enabled.
* If rebuilds cause cloud-init to skip applying userdata, set `KEEP_INSTANCE_ID=1`
This ensures cloud-init treats rebuilds as the same instance and processes configuration accordingly.

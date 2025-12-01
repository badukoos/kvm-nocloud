# kvm-nocloud

kvm-nocloud is a set of shell scripts for building KVM virtual machines using upstream cloud images, NoCloud cloud-init metadata, and optional Vagrant box packaging. Everything is implemented using standard tools like qemu-img, virt-install, libvirt and yq.

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

## Advanced Options

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

**Notes:**
* The default is `DIRECT_INSTALL=0`, meaning the box is created under `build/` and must be added manually via `vagrant box add`
* `templates/vagrant-selinux-fix.service` applies SELinux adjustments required by the Vagrant libvirt workflow.
* Vagrant packaging option is completely separate from cloud-init workflow and does not have anything to do with it.

## Troubleshooting

| Command | Description |
|--------|-------------|
| `sudo cloud-init status` | Check `cloud-init` status. Tack `--long` for extended info, tack `--wait` to wait until initialization is complete |
| `sudo cloud-init query ds` | Check `cloud-init` datasource |
| `sudo tail -n 100 /var/log/cloud-init.log` <br> `sudo tail -n 100 /var/log/cloud-init.log` | View `cloud-init` logs |
| `sudo cloud-init query userdata` | See parsed `cloud-init` merged user-data |
| `sudo cloud-init analyze show` <br> `sudo cloud-init analyze blame` | Analyze `cloud-init` stage execution times and performance bottlenecks |

To inspect VM logs directly from the host using the virt-* tools

```bash
export LIBGUESTFS_BACKEND=direct

virt-cat -d <vm> /var/log/cloud-init.log | tail -n100

virt-cat -d <vm> /var/log/cloud-init-output.log | tail -n100
```
To run commands under sudo, preserve the backend selection like
```bash
sudo --preserve-env=LIBGUESTFS_BACKEND virt-cat -d <vm> /var/log/cloud-init.log
```
Alternatively, VM filesystem can be mounted using `guestmount`

```bash
export LIBGUESTFS_BACKEND=direct

sudo mkdir -p /mnt/<vm>
sudo rm -rf /mnt/<vm>/*

sudo --preserve-env=LIBGUESTFS_BACKEND \
  guestmount -d <vm> -i --ro /mnt/<vm>

sudo tail -n50 /mnt/<vm>/var/log/cloud-init.log
sudo tail -n50 /mnt/<vm>/var/log/cloud-init-output.log

sudo guestunmount /mnt/<vm>
```

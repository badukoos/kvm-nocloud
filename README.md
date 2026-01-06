# kvm-nocloud

This repo has wrapper scripts for building KVM virtual machines using upstream cloud images and provides optional Vagrant box packaging, all managed through a single inventory.

## Requires

* `cloud-localds`
* `libvirt`
* `qemu-img`
* `virt-install`
* `virt-customize`
* `yq`

## Quickstart

Clone the repo, then adjust `inventory.yml`

At minimum, update `ssh_authorized_keys` inside the default `userdata_yaml` block along with `ssh_user` and `ssh_key`

Build VM

```bash
./vm.sh debian12
```

Rebuild VM

```bash
./vm.sh debian12 --rebuild
```

Destroy VM

```bash
./vm.sh debian12 --destroy
```

Purge disks and seed

```bash
./vm.sh debian12 --destroy --purge-disks
```

>[!NOTE]
>The provided inventory contains upstream URLs for Debian 12, Fedora 42, Ubuntu 24, and CentOS Stream 9 cloud images.

## Basic Networking

In the inventory, set

Static mode

```yaml
mode: "static"
ip: "192.168.122.150"
gw: "192.168.122.1"
```

DHCP mode

```yaml
mode: "dhcp"
```

## Advanced Options

`inventory.yml` also supports XML patch entries using simple YAML lists.

Example, enabling shared memory backing

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
./vm.sh debian12 --vagrant-box
```

Direct installation into `~/.vagrant.d`

```bash
./vm.sh debian12 --vagrant-box --direct-install
```

>[!NOTE]
>* The default is `DIRECT_INSTALL=0`, meaning the box is created under `build/` and must be added manually via `vagrant box add`.
>* Vagrant packaging option is completely separate from cloud-init workflow.

## Troubleshooting

Basic cloud-init commands

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
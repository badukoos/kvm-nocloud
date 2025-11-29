Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.box_check_update = false

  config.vm.provider :libvirt do |lv|
    lv.memory = 3072
    lv.cpus   = 2
    lv.nic_model_type = "virtio"
    lv.qemu_use_agent = true
  end

  config.vm.boot_timeout = 300
  config.ssh.insert_key = false

  boxes = {
    "debian12" => "localhost/debian12",
    "fedora42" => "localhost/fedora42",
    "stream9"  => "localhost/stream9",
    "ubuntu24" => "localhost/ubuntu24"
  }

  private_ips = {
    "debian12" => "192.168.122.110",
    "fedora42" => "192.168.122.111",
    "stream9"  => "192.168.122.112",
    "ubuntu24" => "192.168.122.113"
  }

  boxes.each do |name, box|
    config.vm.define name do |node|
      node.vm.box = box
      node.vm.hostname = name
      node.vm.network "private_network",
        ip: private_ips[name],
        libvirt__network_name: "default"
    end
  end
end

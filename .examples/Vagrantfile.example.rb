Vagrant.configure("2") do |config|
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.box_check_update = false
  config.vm.network "private_network",
    type: "dhcp",
    libvirt__network_name: "default"

  config.vm.provider :libvirt do |lv|
    lv.memory = 3072
    lv.cpus   = 2
    lv.nic_model_type = "virtio"
    lv.qemu_use_agent = true
    lv.graphics_type = "none"
    lv.serial :type => "pty"
  end

  config.vm.boot_timeout = 300
  config.ssh.insert_key = false

  {
    "debian12" => "localhost/debian12",
    "fedora42" => "localhost/fedora42",
    "stream10" => "localhost/stream10",
    "ubuntu24" => "localhost/ubuntu24"
  }.each do |name, box|
    config.vm.define name do |node|
      node.vm.box = box
      node.vm.hostname = name
    end
  end
end

#!/bin/sh
# Script to automate the setup of Alpine Linux (mostly used as a cheat sheet for the moment)

source alpine_setup_helper.conf

# ----------------------------
# Step #1 - Environment setup
# ----------------------------
function setup_env(){
    echo -e "${language}\n${language}-${keyboard_layout}\n" \
	| setup-keymap 
    echo -e "${hostname}.${domain}\n" \
	| setup-hostname
    echo -e "${interface}\n${ip_address}\n${netmask}\n${gateway}\nn\n" \
	| setup-interfaces
    rc-service networking start
    echo -e "${root_passwd}\n${root_passwd}\n" \
	| passwd
    echo -e "${timezone}\n${sub_timezone}\n" \
	| setup-timezone
    rc-update add networking boot
    rc-update add urandom boot
    rc-update add acpid default
    rc-service acpid start
    sed -i "s/localhost localhost.localdomain/${hostname} ${hostname}.${domain} localhost localhost.localdomain/g" \
	/etc/hosts
    echo -e "${ntp_client}\n" \
	| setup-ntp
    echo -e "${apk_repo_index}\n" \
	| setup-apkrepos
    apk-update
    echo -e "${ssh_server}\n" \
	| setup-sshd
    sed -i "s/#Port 22/Port ${ssh_port}/g" \
	/etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' \
	/etc/ssh/sshd_config
    rc-service sshd restart
    apk add lvm2 cryptsetup e2fsprogs parted btrfs-progs
}

# ----------------------------
# Step #2 - Partitionning
# ----------------------------
function setup_partitions(){
    parted -s ${hdd_alpine} mklabel ${partition_table_type}
    parted -a opt -s ${hdd_alpine} mkpart primary ext4 0% ${boot_partition_size} # Boot partition
    parted -s ${hdd_alpine} set 1 boot on
    parted -a opt -s ${hdd_alpine} mkpart primary ${boot_partition_size} '100%' # LUKS container
}

# ----------------------------
# Step #3 - LVM on LUKS
# ----------------------------
function setup_lvm_on_luks(){
    echo -e "${luks_passphrase}\n" \
	| cryptsetup \
	      -v \
	      -c serpent-xts-plain64 \
	      -s 512 \
	      --hash whirlpool \
	      --iter-time 5000 \
	      --use-random \
	      luksFormat $luks_partition
    echo -e "${luks_passphrase}\n" \
	 | cryptsetup luksOpen $luks_partition lvmcrypt
    pvcreate /dev/mapper/lvmcrypt
    vgcreate vg0 /dev/mapper/lvmcrypt
    lvcreate -L $swap_partition_size vg0 -n swap
    lvcreate -l '100%FREE' vg0 -n root
}

# ----------------------------
# Step #4 - Create filesystems
# ----------------------------
function setup_filesystems(){
    mkfs.ext4 $boot_partition
    mkswap /dev/vg0/swap
    mkfs.btrfs /dev/vg0/root -L root
    mount -t btrfs /dev/vg0/root /mnt
    for subvol in @root @home @var_log @snapshots;
    do
	btrfs subvolume create /mnt/${subvol}
    done
    umount /mnt
    mount -t btrfs -o compress=zstd,subvol=@root /dev/vg0/root /mnt
    for subfolder in home var/log .snapshots;
    do
	mkdir -p /mnt/${subfolder}
    done
    mkdir /mnt/boot
    mount -t btrfs -o compress=zstd,subvol=@home /dev/vg0/root /mnt/home
    mount -t btrfs -o compress=zstd,subvol=@var_log /dev/vg0/root /mnt/var/log
    mount -t btrfs -o compress=zstd,subvol=@snapshots /dev/vg0/root /mnt/.snapshots
    mount $boot_partition /mnt/boot
    swapon /dev/vg0/swap
}

"$@"

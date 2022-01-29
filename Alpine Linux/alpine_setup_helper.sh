#!/bin/sh
# Script to automate the setup of Alpine Linux (mostly used as a cheat sheet for the moment)

source alpine_setup_helper.conf

# Internal utilities
function __get_uuid(){
    blkid $1 | sed -n -e 's/^.* UUID=\"//p' | awk -F\" '{ print $1 }'
}

function __get_subvolname(){
    btrfs subvolume show $1 | grep "Name:" | awk '{ print $2 }'
}

function __get_subvolid(){
    btrfs subvolume show $1 | grep "Subvolume ID" | awk '{ print $3 }'
}

# ----------------------------
# Step #1 - Environment setup
# ----------------------------
function setup_env(){
    echo -e "${LANGUAGE}\n${KEYBOARD_LAYOUT}\n" \
	| setup-keymap 
    echo -e "${HOSTNAME}.${DOMAIN}\n" \
	| setup-hostname
    echo -e "${INTERFACE}\n${IP_ADDRESS}\n${NETMASK}\n${GATEWAY}\nn\n" \
	| setup-interfaces
    rc-service networking start
    echo -e "${ROOT_PASSWD}\n${ROOT_PASSWD}\n" \
	| passwd
    echo -e "${TIMEZONE}\n${SUB_TIMEZONE}\n" \
	| setup-timezone
    rc-update add networking boot
    rc-update add urandom boot
    rc-update add acpid default
    rc-service acpid start
    echo "127.0.0.1 ${HOSTNAME} ${HOSTNAME}.${DOMAIN} localhost localhost.localdomain" > /etc/hosts
    echo "::1       ${HOSTNAME} ${HOSTNAME}.${DOMAIN} localhost localhost.localdomain" >> /etc/hosts
    echo -e "${NTP_CLIENT}\n" \
	| setup-ntp
    echo -e "${APK_REPO_INDEX}\n" \
	| setup-apkrepos
    sed -i '/^.*community.*$/s/^#.*http/http/g' /etc/apk/repositories
    apk update
    echo -e "${SSH_SERVER}\n" \
	| setup-sshd
    sed -i "s/#Port 22/Port ${SSH_PORT}/g" \
	/etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' \
	/etc/ssh/sshd_config
    rc-service sshd restart
    apk add lvm2 cryptsetup e2fsprogs parted btrfs-progs haveged pv
}

function random_wipe_drive(){
    # Warning: takes a very long time. Typical throughput is ~80 MiB/s on a hdd. Therefore, to wipe 1TiB this will take about 3.6 hours.
    haveged -n 0 | pv -ptab | dd of=${HDD_ALPINE} bs=16M
}

# ----------------------------
# Step #2 - Partitionning
# ----------------------------
function setup_partitions(){
    parted -s ${HDD_ALPINE} mklabel ${PARTITION_TABLE_TYPE}
    parted -a opt -s ${HDD_ALPINE} mkpart primary ext4 0% ${BOOT_PARTITION_SIZE} # Boot partition
    parted -s ${HDD_ALPINE} set 1 boot on
    parted -a opt -s ${HDD_ALPINE} mkpart primary ${BOOT_PARTITION_SIZE} '100%' # LUKS container
}

# ----------------------------
# Step #3 - LVM on LUKS
# ----------------------------
function setup_lvm_on_luks(){
    echo -e "${LUKS_PASSPHRASE}\n" \
	| cryptsetup \
	      -v \
	      -c serpent-xts-plain64 \
	      -s 512 \
	      --hash whirlpool \
	      --iter-time 5000 \
	      --use-random \
	      luksFormat $LUKS_PARTITION
    echo -e "${LUKS_PASSPHRASE}\n" \
	 | cryptsetup luksOpen $LUKS_PARTITION lvmcrypt
    pvcreate /dev/mapper/lvmcrypt
    vgcreate vg0 /dev/mapper/lvmcrypt
    lvcreate -L $SWAP_PARTITION_SIZE vg0 -n swap
    lvcreate -l '100%FREE' vg0 -n root
}

# ----------------------------
# Step #4 - Create filesystems
# ----------------------------
function setup_filesystems(){
    mkfs.ext4 $BOOT_PARTITION
    mkswap /dev/vg0/swap
    mkfs.btrfs /dev/vg0/root -L root
    mount -t btrfs /dev/vg0/root /mnt
    for SUBVOL in @root @home @var_log @snapshots @home_snapshots;
    do
	btrfs subvolume create /mnt/${SUBVOL}
    done
    umount /mnt
}

# ---------------------------
# Step #5 - Mount filesystems
# ---------------------------
function mount_filesystems(){
    mount -t btrfs -o compress=zstd,subvol=@root /dev/vg0/root /mnt
    for SUBFOLDER in boot home var/log .snapshots;
    do
	[ ! -d /mnt/${SUBFOLDER} ] && mkdir -p /mnt/${SUBFOLDER}
    done
    mount -t ext4 $BOOT_PARTITION /mnt/boot
    mount -t btrfs -o compress=zstd,subvol=@home /dev/vg0/root /mnt/home
    [ ! -d /mnt/home/.snapshots ] && mkdir -p /mnt/home/.snapshots
    mount -t btrfs -o compress=zstd,subvol=@home_snapshots /dev/vg0/root /mnt/home/.snapshots
    mount -t btrfs -o compress=zstd,subvol=@var_log /dev/vg0/root /mnt/var/log
    mount -t btrfs -o compress=zstd,subvol=@snapshots /dev/vg0/root /mnt/.snapshots
    swapon /dev/vg0/swap
}

function install_alpine(){
    setup-disk -m sys /mnt
}

function store_uuids(){
    [ ! -d "/tmp/uuids" ] && mkdir /tmp/uuids
    echo $(__get_uuid ${BOOT_PARTITION}) > /tmp/uuids/boot
    echo $(__get_uuid ${LUKS_PARTITION}) > /tmp/uuids/luks
    echo $(__get_uuid /dev/vg0/root)     > /tmp/uuids/root
    echo $(__get_uuid /dev/vg0/swap)     > /tmp/uuids/swap
}

function prepare_fstab(){
    store_uuids
    FSTAB=/mnt/etc/fstab
    echo "UUID=$(cat /tmp/uuids/root)    /                    btrfs    ${BTRFS_OPTS},subvolid=$(__get_subvolid /mnt),subvol=$(__get_subvolname /mnt)                                      0 1" >  ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/root)    /home                btrfs    ${BTRFS_OPTS},subvolid=$(__get_subvolid /mnt/home),subvol=$(__get_subvolname /mnt/home)                            0 2" >> ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/root)    /var/log             btrfs    ${BTRFS_OPTS},subvolid=$(__get_subvolid /mnt/var/log),subvol=$(__get_subvolname /mnt/var/log)                      0 2" >> ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/root)    /.snapshots          btrfs    ${BTRFS_OPTS},subvolid=$(__get_subvolid /mnt/.snapshots),subvol=$(__get_subvolname /mnt/.snapshots)                0 2" >> ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/root)    /home/.snapshots     btrfs    ${BTRFS_OPTS},subvolid=$(__get_subvolid /mnt/home/.snapshots),subvol=$(__get_subvolname /mnt/home/.snapshots)      0 2" >> ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/boot)    /boot                ext4     ${ext4_opts}                                                                                                       0 2" >> ${FSTAB}
    echo "UUID=$(cat /tmp/uuids/swap)    swap                 swap     defaults                                                                                                           0 0" >> ${FSTAB}
}

function build_initramfs(){
    echo "features=\"${MKINITFS_FEATURES}\"" > /mnt/etc/mkinitfs/mkinitfs.conf
    mkinitfs -c /mnt/etc/mkinitfs/mkinitfs.conf -b /mnt/ $(ls /mnt/lib/modules/)
}

function setup_keyfile(){
    touch /mnt/crypto_keyfile.bin
    chmod 600 /mnt/crypto_keyfile.bin
    dd bs=512 count=4 if=/dev/urandom of=/mnt/crypto_keyfile.bin
    echo -e ${LUKS_PASSPHRASE} | cryptsetup luksAddKey ${LUKS_PARTITION} /mnt/crypto_keyfile.bin
}

function prepare_chroot(){
    mount -t proc /proc /mnt/proc
    mount --rbind /dev /mnt/dev
    mount --make-rslave /mnt/dev
    mount --rbind /sys /mnt/sys
}

function setup_grub(){
    cat <<EOF | chroot /mnt
source /etc/profile
apk add grub grub-bios && apk del syslinux
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptroot=UUID=${LUKS_UUID} cryptdm=lvmcrypt cryptkey rootflags=subvol=@root\"" >> /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
echo "GRUB_PRELOAD_MODULES=\"${GRUB_MODULES}\"" >> /etc/default/grub
grub-install --target=i386-pc ${HDD_ALPINE}
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

function unmount_all(){
    swapoff /dev/vg0/swap
    for MOUNTPOINT in dev proc sys;
    do
	umount -l /mnt/${MOUNTPOINT}
    done

    for mountpoint in boot var/log .snapshots home/.snapshots home;
    do
	umount /mnt/${MOUNTPOINT}
    done

    umount /mnt
    vgchange -a n
    cryptsetup luksClose lvmcrypt
}

# Run selected command
"$@"

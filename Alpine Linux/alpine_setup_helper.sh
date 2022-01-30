#!/bin/sh
# Script to automate the setup process of Alpine Linux in an LVM on LUKS approach.

source ./alpine_setup_helper.conf

# Internal utilities
function __get_uuid(){
    blkid $1 | sed -n -e 's/^.* UUID=\"//p' | awk -F\" '{ print $1 }'
}

function __store_uuids(){
    [ ! -d "/tmp/uuids" ] && mkdir /tmp/uuids
    [ ! -f "/tmp/uuids/boot"] && \
				echo $(__get_uuid ${BOOT_PARTITION}) > /tmp/uuids/boot
    [ ! -f "/tmp/uuids/luks"] && \
				echo $(__get_uuid ${LUKS_PARTITION}) > /tmp/uuids/luks
    [ ! -f "/tmp/uuids/root"] && \
				echo $(__get_uuid /dev/${VG_NAME}/${ROOT_LV_NAME}) > /tmp/uuids/root
    [ ! -f "/tmp/uuids/swap"] && \
				echo $(__get_uuid /dev/${VG_NAME}/${SWAP_LV_NAME}) > /tmp/uuids/swap
}

function __get_subvolname(){
    btrfs subvolume show $1 | grep "Name:" | awk '{ print $2 }'
}

function __get_subvolid(){
    btrfs subvolume show $1 | grep "Subvolume ID" | awk '{ print $3 }'
}

function help(){
    cat <<EOF
This script provides various utilities to install Alpine Linux on a computer.
Implemented utilities are :

* setup_env 
  ---------
Setup the Alpine environment on the live cd. 
  * sets the language and the keyboard layout
  * defines the hostname, the domain and update the hosts file accordingly
  * sets up the network interface
  * adds and start useful services to OpenRC
  * sets the NTP client
  * sets up the repositories for apk and calls apk update
  * sets up an SSH server and temporarily enables root login
  * installs several programs to prepare encryption, logical volumes, partitions, etc.

* random_wipe_drive 
  -----------------
Fill the device HDD_ALPINE defined in the configuration file 
with random data using hageged. 
/!\ Warning /!\ 
This can take several hours depending on the size of the drive. 
The function will use pv to give feedback to the user regarding the 
current status of the process.

* setup_partitions 
  -----------------
On HDD_ALPINE, sets up a partition table, create a boot partition and 
another one for a LUKS container

* setup_lvm_on_luks 
  ------------------
Create a LUKS container on HDD_ALPINE with the provided passphrase. 
Then, creates a physical volume, a volume group and logical volumes 
for the swap and root filesystems. 

* setup_filesystems 
  -----------------
On the previously generated logical volumes, create a swap 
filesystem, a BTRFS filesystem on the root logical volume and several relevant 
subvolumes useful to define a snapshotting strategy later.

* mount_filesystems 
  -----------------
After the creation of the filesystems using setup_filesystems, mount everything 
using /mnt as a target root directory for the final Alpine Linux system.

* install_alpine 
  --------------
Installs a base Alpine Linux distribution on the previously generated and 
mounted filesystems. 

* store_uuids 
  -----------
Gets the uuids of different devices and stores them as temporary files in 
/tmp/uuids

* prepare_fstab 
  -------------
Based on the mounted filesystems, writes the fstab file of the target Alpine 
Linux system.

* build_initramfs 
  ---------------
Using the settings of the configuration file, prepares an initramfs for the 
target system using mkinitfs

* setup_keyfile 
  -------------
In order to have to type the passphrase twice (once in grub, and another time 
at the initramfs stage), prepares a random binary file and adds it as a 
secondary key to unlock the LUKS container.

* prepare_chroot 
  --------------
Mount the /proc, /dev, /sys filesystems in the target system folder structure.

* setup_grub 
  ----------
Install grub in the target system, and sets up the /etc/default/grub 
configuration file.

* unmount_all 
  -----------
Cleanly unmount all of the target system folders, close all LVMs, close the LUKS
container, turn off swap.
EOF
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
	 | cryptsetup luksOpen $LUKS_PARTITION ${LUKS_DEVICE}
    pvcreate /dev/mapper/${LUKS_DEVICE}
    vgcreate ${VG_NAME} /dev/mapper/${LUKS_DEVICE}
    lvcreate -L $SWAP_PARTITION_SIZE ${VG_NAME} -n $SWAP_LV_NAME
    lvcreate -l '100%FREE' ${VG_NAME} -n $ROOT_LV_NAME
}

# ----------------------------
# Step #4 - Create filesystems
# ----------------------------
function setup_filesystems(){
    mkfs.ext4 $BOOT_PARTITION
    mkswap /dev/${VG_NAME}/${SWAP_LV_NAME}
    mkfs.btrfs /dev/${VG_NAME}/${ROOT_LV_NAME} -L root
    mount -t btrfs /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt
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
    mount -t btrfs -o compress=zstd,subvol=@root /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt
    for SUBFOLDER in boot home var/log .snapshots;
    do
	[ ! -d /mnt/${SUBFOLDER} ] && mkdir -p /mnt/${SUBFOLDER}
    done
    mount -t ext4 $BOOT_PARTITION /mnt/boot
    mount -t btrfs -o compress=zstd,subvol=@home /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt/home
    [ ! -d /mnt/home/.snapshots ] && mkdir -p /mnt/home/.snapshots
    mount -t btrfs -o compress=zstd,subvol=@home_snapshots /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt/home/.snapshots
    mount -t btrfs -o compress=zstd,subvol=@var_log /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt/var/log
    mount -t btrfs -o compress=zstd,subvol=@snapshots /dev/${VG_NAME}/${ROOT_LV_NAME} /mnt/.snapshots
    swapon /dev/${VG_NAME}/${SWAP_LV_NAME}
}

function install_alpine(){
    setup-disk -m sys /mnt
}

function prepare_fstab(){
    __store_uuids
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
    LUKS_UUID=$(cat /tmp/uuids/luks)
    cat <<EOF | chroot /mnt
source /etc/profile
apk add grub grub-bios && apk del syslinux
echo "GRUB_DISTRIBUTOR=\"Alpine\" > /etc/default/grub
echo "GRUB_TIMEOUT=2" >> /etc/default/grub
echo "GRUB_DISABLE_SUBMENU=y" >> /etc/default/grub
echo "GRUB_DISABLE_RECOVERY=true" >> /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"cryptroot=UUID=${LUKS_UUID} cryptdm=${LUKS_DEVICE} cryptkey rootflags=subvol=@root\"" >> /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
echo "GRUB_PRELOAD_MODULES=\"${GRUB_MODULES}\"" >> /etc/default/grub
grub-install --target=i386-pc ${HDD_ALPINE}
grub-mkconfig -o /boot/grub/grub.cfg
EOF
}

function unmount_all(){
    swapoff /dev/${VG_NAME}/${SWAP_LV_NAME}
    for MOUNTPOINT in dev proc sys;
    do
	umount /mnt/${MOUNTPOINT} || umount -l /mnt/${MOUNTPOINT}
    done

    for mountpoint in boot var/log .snapshots home/.snapshots home;
    do
	umount /mnt/${MOUNTPOINT} || umount -l /mnt/${MOUNTPOINT}
    done

    umount /mnt
    vgchange -a n
    cryptsetup luksClose ${LUKS_DEVICE}
}

# Run selected command
"$@"

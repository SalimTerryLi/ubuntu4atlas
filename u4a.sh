#!/bin/bash

# runtime variables
IS_CHROOT_MODE=0
EXEC_NAME=$0
DEPENDENCIES=(
	"mount"
	"unsquashfs"
	"sudo"
	"echo"
	"grep"
	"cat"
	"cut"
	"blockdev"
	"dd"
	"parted"
	"modinfo"
	"modprobe"
	"losetup"
	"partprobe"
  "delpart"
	"chroot"
	"qemu-aarch64-static"
	"resize2fs"
	"resizepart"
	"rm"
	"umount"
)
TMP_FOLDER="/tmp/"`tr -dc A-Za-z0-9 </dev/urandom | head -c 13 ; echo ''`"/"
while [ -d "$TMP_FOLDER" ]
do
	# generate Another
	TMP_FOLDER="/tmp/"`tr -dc A-Za-z0-9 </dev/urandom | head -c 13 ; echo ''`"/"
done
ISO_MOUNT_POINT=${TMP_FOLDER}iso
IMG_INITIAL_SIZE=$((4*1000*1000*1000))	# 4G
IS_BLOCKDEV=0
BLOCKDEV_BS=4096
LO_DEV=""
PARTITION_DEV=""
EXTFS_MOUNT_POINT=${TMP_FOLDER}rootfs

# configuration variables
INPUT_FILENAME=""
OUTPUT_FILENAME=""
FW_DIR="fw"
CONF_DIR="conf"
FORCE_OVERWRITE=0
ONLINE_UPGRADE=0
MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/"
HOST_NAME="atlas-ubuntu"
USER_NAME="ubuntu"
USER_PWD="ubuntu"
KEEP_SHELL=0

# cleanup flags
CLEANUP_TMPFOLDER=0
CLEANUP_ISOMOUNT=0
CLEANUP_RMOUTPUT=0
CLEANUP_LODEV=0
CLEANUP_UMOUNTEXTFS=0
CLEANUP_HOST_RM_TMP_SCRIPT=0
CLEANUP_UMOUNTBIND=0

# functions

check_deps() {
	ret=0
	for prog in ${DEPENDENCIES[*]}; do
		if ! command -v $prog &> /dev/null
		then
			echo "$prog could not be found" 1>&2
			ret=1
		fi

	done
	return $ret
}

usage() {
	cat << EOF
A bash script that converts ARM Ubuntu server ISO to bootable img files for Atlas200DK.

usage:	$0 [-C] -o output.img -i input.iso [-f] [-m http://xxxx] [-H hostname] [-u ubuntu] [-p ubuntu]
flags:	Flag	Description			Requirement		Default
	-C	Reserved. Please *DO NOT* manually specify it.
	-i	Input ISO file.			HOST REQUIRED
	-o	Output IMG file			HOST REQUIRED
	-f	Force overwrite dest img	HOST OPTIONAL
	-n	do network upgrade		BOTH OPTIONAL
	-m	custom apt mirror URL		BOTH OPTIONAL		http://ports.ubuntu.com/ubuntu-ports/
	-H	custom hostname			BOTH OPTIONAL		atlas-ubuntu
	-u	custom non-root username	BOTH OPTIONAL		ubuntu
	-p	custom non-root password	BOTH OPTIONAL		ubuntu
	-k	keep a shell inside chroot	BOTH OPTIONAL

Report bugs to: lhf2613@gmail.com

EOF
	exit $1;
}

cleanup() {
	if [[ $IS_CHROOT_MODE -ne 0 ]];then
		return
	fi
	echo "cleanup..."
	if [[ $CLEANUP_UMOUNTBIND -ne 0 ]];then
		sudo umount $EXTFS_MOUNT_POINT/cdimage
		sudo rm -r $EXTFS_MOUNT_POINT/cdimage
	fi
	if [[ $CLEANUP_HOST_RM_TMP_SCRIPT -ne 0 ]];then
		sudo rm -rf "$EXTFS_MOUNT_POINT/*"
	fi
	if [[ $CLEANUP_UMOUNTEXTFS -ne 0 ]];then
		sudo umount $EXTFS_MOUNT_POINT
	fi
	if [[ $CLEANUP_LODEV -ne 0 ]];then
		sudo losetup -d $LO_DEV
		sudo delpart $LO_DEV 1
	fi
	if [[ $CLEANUP_RMOUTPUT -ne 0 ]];then
		rm $OUTPUT_FILENAME
	fi
	if [[ $CLEANUP_ISOMOUNT -ne 0 ]];then
		sudo umount $ISO_MOUNT_POINT
	fi
	if [[ $CLEANUP_TMPFOLDER -ne 0 ]];then
		rm -rf $TMP_FOLDER
	fi
}
trap cleanup EXIT

# main

host_main() {
	echo "Configurations:"
	echo "	input_filename = ${INPUT_FILENAME}"
	echo "	output_filename = ${OUTPUT_FILENAME}"
	echo "	tmp folder = ${TMP_FOLDER}"
	echo "	apt mirror = ${MIRROR_URL}"
	echo "	hostname = ${HOST_NAME}"
	echo "	username = ${USER_NAME}"
	echo "	password = ${USER_PWD}"
	echo

	# setup env

	echo "Checking dependencies..."
	check_deps
	if [[ $? -ne 0 ]];then
	    echo "dependencies checking failed." 1>&2
	    exit 1
	fi
	echo "Passed"
	echo

	mkdir $TMP_FOLDER

	# mount iso

	mkdir $ISO_MOUNT_POINT	# will be cleanup together with CLEANUP_TMPFOLDER
	CLEANUP_TMPFOLDER=1	# raise flag
	sudo mount -o loop,ro ${INPUT_FILENAME} ${ISO_MOUNT_POINT}
	if [[ $? -ne 0 ]];then
		echo "ISO failed to mount" 1>&2
		exit 1
	fi
	CLEANUP_ISOMOUNT=1	# raise flag
	echo "ISO mounted"
	echo

	# check ISO contents

	if [ ! -f "${ISO_MOUNT_POINT}/dists/stable/Release" ]; then
		echo "Unsupported ISO" 1>&2
		exit 1
	fi
	UBUNTU_VERSION=`cat ${ISO_MOUNT_POINT}/dists/stable/Release | grep "Version:" | cut -b 9-`
	echo "Detected Ubuntu version: ${UBUNTU_VERSION}"
	echo

	# create target img file

	echo "Check target IMG"
	if [ -f "${OUTPUT_FILENAME}" ]; then
		if [[ $FORCE_OVERWRITE -eq 0 ]];then
			echo "Target IMG already exists!" 1>&2
			exit 1
		else
			echo "Overwrite existing file"
		fi
	elif [ -b "${OUTPUT_FILENAME}" ]; then
		echo "Block device detected"
		IS_BLOCKDEV=1
		BLOCK_DEV_SIZE=`sudo blockdev --getsize64 ${OUTPUT_FILENAME}`
		if [[ $BLOCK_DEV_SIZE -lt $IMG_INITIAL_SIZE ]];then
			echo "No enough space on device!" 1>&2
			exit 1
		fi
		BLOCKDEV_BS=`sudo blockdev --getbsz ${OUTPUT_FILENAME}`
	elif [ ! -f "${OUTPUT_FILENAME}" ]; then
		echo "Create new IMG file"
		CLEANUP_RMOUTPUT=1
	else
		echo "Target file already exists but not supported!" 1>&2
	fi

	if [ $IS_BLOCKDEV -eq 0 ];then
		dd if=/dev/zero of="${OUTPUT_FILENAME}" bs=${BLOCKDEV_BS} count=$((IMG_INITIAL_SIZE/BLOCKDEV_BS)) status=none
		if [[ $? -ne 0 ]];then
			echo "Failed to create target file!" 1>&2
			exit 1
		fi
	fi

	sudo parted -s -a optimal "${OUTPUT_FILENAME}" mklabel msdos mkpart primary 0% 100%
	if [[ $? -ne 0 ]];then
		echo "Failed to create partition table" 1>&2
		exit 1
	fi
	echo "msdos partition table created with one partition"

	sudo modprobe loop
	modinfo loop >/dev/null 2>&1
	if [[ $? -ne 0 ]];then
		echo "Failed to load loop kernel module" 1>&2
		exit 1
	fi
	LO_DEV=`sudo losetup -f`
	if [[ $? -ne 0 ]];then
		echo "Cannot alloc loop device" 1>&2
		exit 1
	fi
	sudo losetup ${LO_DEV} "${OUTPUT_FILENAME}"
	CLEANUP_LODEV=1
	sudo partprobe ${LO_DEV}
	PARTITION_DEV=`ls -1 /dev/loop* | grep "${LO_DEV}" | grep -v "^$LO_DEV$"`
	sudo mkfs.ext3 -L ubuntu -F "$PARTITION_DEV" > /dev/null 2>&1
	if [[ $? -ne 0 ]];then
		echo "Failed to create ext3 fs" 1>&2
		exit 1
	fi
	echo "ext3 fs is created on 1st partition"
	echo

	# mount img

	mkdir $EXTFS_MOUNT_POINT
	sudo mount $PARTITION_DEV $EXTFS_MOUNT_POINT
	CLEANUP_UMOUNTEXTFS=1

	# extract rootfs

	if [ -f "$ISO_MOUNT_POINT/install/filesystem.squashfs" ]; then
		sudo unsquashfs -f -d $EXTFS_MOUNT_POINT/ "$ISO_MOUNT_POINT/install/filesystem.squashfs" > /dev/null 2>&1
	elif [ -f "$ISO_MOUNT_POINT/casper/filesystem.squashfs" ]; then
		sudo unsquashfs -f -d $EXTFS_MOUNT_POINT/ "$ISO_MOUNT_POINT/casper/filesystem.squashfs" > /dev/null 2>&1
	else
		echo "Unable to locate filesystem.squashfs" 1>&2
	fi
	echo "rootfs extracted"

	# patch firmware and kernel

	if [ ! -d "$FW_DIR" ];then
		echo "fw dir not exists!" 1>&2
		exit 1
	fi
	if [ ! -f "$FW_DIR/Image" ];then
		echo "Kernel not exists!" 1>&2
		exit 1
	fi
	sudo cp -rf "$FW_DIR" "$EXTFS_MOUNT_POINT/"

	# patch kernel modules

	sudo chmod 440 "$EXTFS_MOUNT_POINT/fw/ko/"*
	sudo chown root:root "$EXTFS_MOUNT_POINT/fw/ko/"*
	if [ ! -d "$CONF_DIR" ];then
		echo "conf dir not exists!" 1>&2
		exit 1
	fi
	sudo cp "$CONF_DIR/modprobe.d/atlas200dk.conf" "$EXTFS_MOUNT_POINT/etc/modprobe.d/atlas200dk.conf"
	sudo chmod 644 "$EXTFS_MOUNT_POINT/etc/modprobe.d/atlas200dk.conf"
	sudo chown root:root "$EXTFS_MOUNT_POINT/etc/modprobe.d/atlas200dk.conf"
	sudo cp "$CONF_DIR/modules-load.d/atlas200dk.conf" "$EXTFS_MOUNT_POINT/etc/modules-load.d/atlas200dk.conf"
	sudo chmod 644 "$EXTFS_MOUNT_POINT/etc/modules-load.d/atlas200dk.conf"
	sudo chown root:root "$EXTFS_MOUNT_POINT/etc/modules-load.d/atlas200dk.conf"

	# chroot config

	sudo cp "$EXEC_NAME" "$EXTFS_MOUNT_POINT/tmp/"
	CLEANUP_HOST_RM_TMP_SCRIPT=1
	sudo chmod +x "$EXTFS_MOUNT_POINT/tmp/$EXEC_NAME"
	CHROOT_FLAGS=""
	if [[ $ONLINE_UPGRADE -ne 0 ]];then
		CHROOT_FLAGS=$CHROOT_FLAGS" -n"
	fi
	if [[ $KEEP_SHELL -ne 0 ]];then
		CHROOT_FLAGS=$CHROOT_FLAGS" -k"
	fi
	sudo mkdir $EXTFS_MOUNT_POINT/cdimage
	sudo mount -o bind $ISO_MOUNT_POINT $EXTFS_MOUNT_POINT/cdimage
	CLEANUP_UMOUNTBIND=1
	sudo chroot $EXTFS_MOUNT_POINT /bin/bash -c \
		"/tmp/$EXEC_NAME \
				-C \
				-m $MIRROR_URL \
				-H $HOST_NAME \
				-u $USER_NAME \
				-p $USER_PWD \
				$CHROOT_FLAGS"

	# shrink img if file target
	if [[ $IS_BLOCKDEV -eq 0 ]];then
		sudo umount $EXTFS_MOUNT_POINT/cdimage
		sudo rm -r $EXTFS_MOUNT_POINT/cdimage
		CLEANUP_UMOUNTBIND=0
		sudo rm -rf "$EXTFS_MOUNT_POINT/*"
		CLEANUP_HOST_RM_TMP_SCRIPT=0
		sudo umount $EXTFS_MOUNT_POINT
		CLEANUP_UMOUNTEXTFS=0
		sudo resize2fs -Mf $PARTITION_DEV
		FS_SIZE=`sudo dumpe2fs -h $PARTITION_DEV |& awk -F: '/Block count/{count=$2} /Block size/{size=$2} END{print count*size}'`
		PARTITION_BEGIN_OFFSET=`sudo parted -s $LO_DEV unit B print | sed 's/^ //g' | grep "^1 " | tr -s ' ' | cut -d ' ' -f2 | cut -d 'B' -f1`
		sudo parted /dev/loop17 ---pretend-input-tty << EOF
resizepart
1
$((FS_SIZE+PARTITION_BEGIN_OFFSET))B
Yes
EOF
		sudo losetup -d $LO_DEV
		sudo delpart $LO_DEV 1
		CLEANUP_LODEV=0
		truncate -s $((FS_SIZE+PARTITION_BEGIN_OFFSET)) $OUTPUT_FILENAME
	fi

	# cleanup

	CLEANUP_RMOUTPUT=0
}

chroot_main() {
	echo "chroot mode"
	echo

	# basic package
	locale-gen zh_CN.UTF-8 en_US.UTF-8
	mv /etc/apt/sources.list /etc/apt/sources.list.bak
	touch /etc/apt/sources.list
	RELEASE_CODE=`lsb_release -cs`
	echo "deb file:/cdimage "${RELEASE_CODE}" main restricted" > /etc/apt/sources.list
	apt-get update
	apt-get install -y --install-suggests \
		openssh-server \
		unzip \
		gcc \
		g++ \
		rsync \
		zip \
		make \
		avahi-daemon \
		git \
		nano \
		chrony \
		net-tools
	apt-get install -y pciutils strace nfs-common sysstat libelf1 libnuma1 dmidecode
	rm /etc/apt/sources.list
	mv /etc/apt/sources.list.bak /etc/apt/sources.list
	sed -i 's/^deb/# deb/g' /etc/apt/sources.list
	echo -e "\n" >> /etc/apt/sources.list
	cat << EOF >> /etc/apt/sources.list
deb ${MIRROR_URL} ${RELEASE_CODE} main restricted universe multiverse
# deb-src ${MIRROR_URL} ${RELEASE_CODE} main restricted universe multiverse
deb ${MIRROR_URL} ${RELEASE_CODE}-updates main restricted universe multiverse
# deb-src ${MIRROR_URL} ${RELEASE_CODE}-updates main restricted universe multiverse
deb ${MIRROR_URL} ${RELEASE_CODE}-backports main restricted universe multiverse
# deb-src ${MIRROR_URL} ${RELEASE_CODE}-backports main restricted universe multiverse
deb ${MIRROR_URL} ${RELEASE_CODE}-security main restricted universe multiverse
# deb-src ${MIRROR_URL} ${RELEASE_CODE}-security main restricted universe multiverse

EOF
	if [[ $ONLINE_UPGRADE -ne 0 ]];then
		mv /etc/resolv.conf /etc/resolv.conf.bak
		echo -e "nameserver 223.5.5.5\nnameserver 8.8.8.8" > /etc/resolv.conf
		apt-get update
		apt-get upgrade -y
		apt-get install -y cmake
		rm /etc/resolv.conf
		mv /etc/resolv.conf.bak /etc/resolv.conf
	fi

	# setup user
	adduser --gecos  "" $USER_NAME --disabled-password
	cat << EOF | chpasswd
$USER_NAME:$USER_PWD
EOF
	usermod -aG sudo $USER_NAME
	sed -i 's/%sudo\tALL=(ALL:ALL) ALL/%sudo\tALL=(ALL:ALL) NOPASSWD:ALL/g' /etc/sudoers

	# setup hostname
	echo $HOST_NAME > /etc/hostname
	echo -e "127.0.0.1\tlocalhost" > /etc/hosts
	echo -e "127.0.1.1\t$HOST_NAME" >> /etc/hosts

	# setup network
	cat << EOF >> /etc/netplan/00-installer-config.yaml
# This is the network config written by 'u4a.sh'
network:
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
  version: 2
EOF
	chmod 644 /etc/netplan/00-installer-config.yaml

	if [[ $KEEP_SHELL -ne 0 ]];then
		bash
	fi
}

# prepare configuration

while getopts "Ci:o:fhm:H:u:p:nk" o; do
	case "${o}" in
	C)
		IS_CHROOT_MODE=1
		;;
	i)
		INPUT_FILENAME=${OPTARG}
		;;
	o)
		OUTPUT_FILENAME=${OPTARG}
		;;
	f)
		FORCE_OVERWRITE=1
		;;
	n)
		ONLINE_UPGRADE=1
		;;
	m)
		MIRROR_URL=${OPTARG}
		;;
	H)
		HOST_NAME=${OPTARG}
		;;
	u)
		USER_NAME=${OPTARG}
		;;
	p)
		USER_PWD=${OPTARG}
		;;
	k)
		KEEP_SHELL=1
		;;
	h)
		usage 0
		;;
	*)
		usage 1
		;;
	esac
done
shift $((OPTIND-1))

if [[ $IS_CHROOT_MODE -ne 0 ]];then
	chroot_main
else
	if [ -z "${INPUT_FILENAME}" ] || [ -z "${OUTPUT_FILENAME}" ]; then
		usage 0
	fi
	host_main
fi

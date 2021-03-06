#!/bin/bash

# import common functions and rbd-usb.conf config
. /usr/lib/rbd-usb.env

function _zram_setup() {
	local zram_name=$1
	local zram_size=$2
	local zram_dev="/dev/${zram_name}"

	modprobe zram num_devices="1" || _fatal "failed to load zram module"

	[ -b $zram_dev ] || _fatal "$zram_dev block device not present"

	echo "${zram_size}" > /sys/block/$zram_name/disksize || _fatal

	mkfs.vfat -n "Config" $zram_dev || _fatal "failed to create Config FS"
}

function _zram_mount() {
	local zram_name=$1
	local zram_mnt=$2
	local zram_dev="/dev/${zram_name}"

	[ -d $zram_mnt ] || _fatal "zram mountpoint at $zram_mnt missing"
	mountpoint -q $zram_mnt && _fatal "$zram_mnt already mounted"

	[ -b $zram_dev ] || _fatal "$zram_dev block device not present"

	# get ownership of mountpoint dir so that it can be applied to the mounted fs
#	local owner=`stat --format="%U:%G" $zram_mnt`

	mount $zram_dev $zram_mnt || _fatal "failed to mount zram"
#	chown $owner $zram_mnt || _fatal

	echo "mounted $zram_name at $zram_mnt"
}

function _zram_umount() {
	local zram_name=$1
	local zram_mnt=$2
	local zram_dev="/dev/${zram_name}"

	[ -b $zram_dev ] || _fatal "$zram_dev block device not present"

	umount $zram_dev || _fatal "failed to unmount zram"
}

function _zram_fs_fill() {
	local zram_mnt=$1

	mkdir ${zram_mnt}/ceph || _fatal "failed to create zram dir"

	if [ -f /etc/ceph/ceph.conf ]; then
		cp /etc/ceph/ceph.conf ${zram_mnt}/ceph/ceph.conf \
			|| _fatal "failed to copy to zram"
	fi

	if [ -f /etc/ceph/keyring ]; then
		# XXX should consider only accepting keyrings, but not exposing
		# them?
		cp /etc/ceph/keyring ${zram_mnt}/ceph/keyring \
			|| _fatal "failed to copy to zram"
	fi

	if [ -f /etc/rbd-usb/rbd-usb.conf ]; then
		cp /etc/rbd-usb/rbd-usb.conf ${zram_mnt}/rbd-usb.conf \
			|| _fatal "failed to copy to zram"
	fi

	if [ -f /usr/lib/rbd-usb-run-conf.flag ]; then
		touch ${zram_mnt}/rbd-usb-run-conf.flag \
			|| _fatal "failed to write to zram"
	fi

	if [ -f /var/log/rbd-usb.service.log ]; then
		cp /var/log/rbd-usb.service.log ${zram_mnt}/ \
			|| _fatal "failed to write to zram"
		rm /var/log/rbd-usb.service.log \
			|| echo "failed to remove old log"
	fi

	mkdir ${zram_mnt}/dm-crypt || _fatal "failed to create zram dir"
	echo "Place a LUKS key file \"luks.key\" in this directory to have" \
	     "it used for encryption" > ${zram_mnt}/dm-crypt/readme.txt

	if [ -f /etc/rbd-usb/luks.key ]; then
		# XXX should consider only accepting keys, but not exposing
		# them?
		cp /etc/rbd-usb/luks.key ${zram_mnt}/dm-crypt/luks.key \
			|| _fatal "failed to copy to zram"
	fi
}

function _zram_fs_config_commit() {
	local zram_mnt=$1

	mkdir -p /etc/ceph/
	mkdir -p /etc/rbd-usb/

	if [ -f ${zram_mnt}/ceph/ceph.conf ]; then
		cp ${zram_mnt}/ceph/ceph.conf /etc/ceph/ceph.conf.new \
			|| _fatal "failed to copy from zram"
		mv /etc/ceph/ceph.conf.new /etc/ceph/ceph.conf
	fi

	if [ -f ${zram_mnt}/ceph/keyring ]; then
		cp ${zram_mnt}/ceph/keyring /etc/ceph/keyring.new \
			|| _fatal "failed to copy from zram"
		mv /etc/ceph/keyring.new /etc/ceph/keyring
	fi

	if [ -f ${zram_mnt}/rbd-usb.conf ]; then
		cp ${zram_mnt}/rbd-usb.conf /etc/rbd-usb/rbd-usb.conf.new \
			|| _fatal "failed to copy from zram"
		mv /etc/rbd-usb/rbd-usb.conf.new /etc/rbd-usb/rbd-usb.conf
	fi

	if [ -f ${zram_mnt}/rbd-usb-run-conf.flag ]; then
		touch /usr/lib/rbd-usb-run-conf.flag \
			|| _fatal "failed to modify FS"
	else
		rm /usr/lib/rbd-usb-run-conf.flag \
			|| _fatal "failed to modify FS"
	fi

	if [ -f ${zram_mnt}/dm-crypt/luks.key ]; then
		cp ${zram_mnt}/dm-crypt/luks.key /etc/rbd-usb/luks.key \
			|| _fatal "failed to copy from zram"
	fi

	sync || _fatal "failed to sync FS changes"
}

function _usb_eject_wait() {
	_led_set_blue_only "heartbeat"

	echo "waiting for initiator eject event..."

	cd /sys/kernel/config/usb_gadget/ceph || _fatal "usb_gadget not present"
	# sadly inotify doesn't work with configfs nodes, so poll instead
	while [ -n "`cat functions/mass_storage.usb0/lun.0/file`" ]; do
		sleep 1
	done

	echo "+ ejected"
	_led_set_blue_only "default-on"
}

set -x

_led_set_blue_only

cat /proc/mounts | grep configfs &> /dev/null
if [ $? -ne 0 ]; then
	mount -t configfs configfs /sys/kernel/config \
		|| _fatal "failed to mount configfs"
fi

if [ -f /usr/lib/rbd-usb-run-conf.flag ]; then

	_zram_setup "zram0" 100M

	tmp_dir=`mktemp --directory "/tmp/rbd-usb-cfg.XXXXXXXXXX"` \
		|| _fatal "failed to create tmpdir for mount"
	_zram_mount "zram0" "$tmp_dir"

	_zram_fs_fill "$tmp_dir"

	_zram_umount "zram0" "$tmp_dir"

	_usb_expose "/dev/zram0" "openSUSE" "Ceph USB Config" "fedcba9876543210" \
		"1"	# removable

	set +x

	_usb_eject_wait

	set -x

	_usb_unexpose

	_zram_mount "zram0" "$tmp_dir"

	_zram_fs_config_commit "$tmp_dir"

	_zram_umount "zram0" "$tmp_dir"

	rmdir "$tmp_dir" || _fatal "failed to remove $tmp_dir"
else
	echo "rbd-usb-conf.flag not present - config skipped"
fi

set +x

# rbd-usb.sh will reboot on failure, so that config state restarts
/bin/rbd-usb.sh --start || _reboot "rbd-usb.sh failed to start"

# working config, generate a fast minimal rbd-usb initrd

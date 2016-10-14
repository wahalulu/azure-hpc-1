#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# != 1 ]; then
    echo "Usage: $0 <ManagementHost>"
    exit 1
fi

MGMT_HOSTNAME=$1

# Shares
SHARE_SCRATCH=/share/scratch
BEEGFS_METADATA=/data/beegfs/meta
BEEGFS_STORAGE=/data/beegfs/storage

# Installs all required packages.
#
install_pkgs()
{
    yum -y install epel-release
    yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs gcc gcc-c++ nfs-utils rpcbind mdadm wget python-pip kernel kernel-devel openmpi openmpi-devel automake autoconf
}

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    devices="$3"
    raidDevice="$4"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in $devices; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done
    
    sleep 10

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/$raidDevice --level 0 --raid-devices $devices $createdPartitions
        
        sleep 10
        
        mdadm /dev/$raidDevice

        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/$raidDevice
            echo "/dev/$raidDevice $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$raidDevice
            sleep 5
            tune2fs -o user_xattr /dev/$raidDevice
            echo "/dev/$raidDevice $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        fi
        
        sleep 10
        
        mount /dev/$raidDevice
    fi
}

setup_disks()
{
    mkdir -p $SHARE_SCRATCH
       
    # Dump the current disk config for debugging
    fdisk -l
    
    # Dump the scsi config
    lsscsi
    
    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=`mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g'`
    
    # Get the TMP disk so we know which device and can ignore it later
    tmpDevice=`mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g'`

    # Get the metadata and storage disk sizes from fdisk, we ignore the disks above
    metadataDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n -r | tail -1`
    storageDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n | tail -1`

    if [ "$metadataDiskSize" == "$storageDiskSize" ]; then
        # If metadata and storage disks are the same size, we grab 1/3 for meta, 2/3 for storage
		# TODO : Compute number of disks
		nbMetadaDisks = 1
		nbStorageDisks = 3
        metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbMetadaDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
        storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tail -$nbStorageDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
    else
        # Based on the known disk sizes, grab the meta and storage devices
        metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
        storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
    fi

    mkdir -p $BEEGFS_STORAGE
    mkdir -p $BEEGFS_METADATA
    
    setup_data_disks $BEEGFS_STORAGE "xfs" "$storageDevices" "md10"
    setup_data_disks $BEEGFS_METADATA "ext4" "$metadataDevices" "md20"

    mount -a
}

install_beegfs()
{
    systemctl stop firewalld
    systemctl disable firewalld
	
    # Install BeeGFS repo
    wget -O beegfs-rhel7.repo http://www.beegfs.com/release/latest-stable/dists/beegfs-rhel7.repo
    mv beegfs-rhel7.repo /etc/yum.repos.d/beegfs.repo
    rpm --import http://www.beegfs.com/release/latest-stable/gpg/RPM-GPG-KEY-beegfs
    
    # Disable SELinux
    sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    setenforce 0
    
	# setup metata data
	yum install -y beegfs-meta
	sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$BEEGFS_METADATA'|g' /etc/beegfs/beegfs-meta.conf
	sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf
	systemctl daemon-reload
	systemctl enable beegfs-meta.service
	
	# See http://www.beegfs.com/wiki/MetaServerTuning#xattr
	echo deadline > /sys/block/sdX/queue/scheduler
		   
	# setup storage
	yum install -y beegfs-storage
	sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$BEEGFS_STORAGE'|g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf
	systemctl daemon-reload
	systemctl enable beegfs-storage.service
}

setup_swap()
{
    fallocate -l 5g /mnt/resource/swap
	chmod 600 /mnt/resource/swap
	mkswap /mnt/resource/swap
	swapon /mnt/resource/swap
	echo "/mnt/resource/swap   none  swap  sw  0 0" >> /etc/fstab
}

tune_tcp()
{
    echo "net.ipv4.neigh.default.gc_thresh1=1100" >> /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh2=2200" >> /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh3=4400" >> /etc/sysctl.conf
}

SETUP_MARKER=/var/tmp/configured
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

setup_swap
install_pkgs
setup_disks
tune_tcp
install_beegfs

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0

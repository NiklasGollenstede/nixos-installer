
##
# NixOS Maintenance
##

## On the host and for the user it is called by, creates/registers a VirtualBox VM meant to run the shells target host. Requires the path to the target host's »diskImage« as the result of running the install script. The image file may not be deleted or moved. If »bridgeTo« is set (to a host interface name, e.g. as »eth0«), it is added as bridged network "Adapter 2" (which some hosts need).
function register-vbox {( set -eu # 1: diskImage, 2?: bridgeTo
    diskImage=$1 ; bridgeTo=${2:-}
    vmName="nixos-@{config.networking.hostName}"

    if [[ ! -e $diskImage.vmdk ]] ; then
        VBoxManage internalcommands createrawvmdk -filename $diskImage.vmdk -rawdisk $diskImage # pass-through
    fi

    VBoxManage createvm --name "$vmName" --register --ostype Linux26_64
    VBoxManage modifyvm "$vmName" --memory 2048 --pae off --firmware efi

    VBoxManage storagectl "$vmName" --name SATA --add sata --portcount 4 --bootable on --hostiocache on
    VBoxManage storageattach "$vmName" --storagectl SATA --port 0 --device 0 --type hdd --medium $diskImage.vmdk

    if [[ $bridgeTo ]] ; then # VBoxManage list bridgedifs
        VBoxManage modifyvm "$vmName" --nic2 bridged --bridgeadapter2 $bridgeTo
    fi

    VBoxManage modifyvm "$vmName" --uart1 0x3F8 4 --uartmode1 server /run/user/$(id -u)/$vmName.socket # (guest sets speed)

    set +x # avoid double-echoing
    echo '# VM info:'
    echo " VBoxManage showvminfo $vmName"
    echo '# start VM:'
    echo " VBoxManage startvm $vmName --type headless"
    echo '# kill VM:'
    echo " VBoxManage controlvm $vmName poweroff"
    echo '# create TTY:'
    echo " socat UNIX-CONNECT:/run/user/$(id -u)/$vmName.socket PTY,link=/run/user/$(id -u)/$vmName.pty"
    echo '# connect TTY:'
    echo " screen /run/user/$(id -u)/$vmName.pty"
    echo '# screenshot:'
    echo " ssh $(hostname) VBoxManage controlvm $vmName screenshotpng /dev/stdout | display"
)}


## Builds the current system's (single »partitionDuringInstallation«ed) disk image and calls »deploy-image-to-hetzner-vps«. The installation heeds any »args« / CLI flags set.
function deploy-system-to-hetzner-vps { # 1: name, 2: serverType

    if [[ ! ${args[quiet]:-} ]] ; then echo 'Building the worker image' ; fi
    local image ; image=$( mktemp -u ) && prepend_trap "rm -f '$image'" EXIT || return
    local buildPid ; install-system "$image" & buildPid=$!
    if [[ ! ${args[parallel-build-deploy]:-} ]] ; then wait $buildPid || return ; fi

    deploy-image-to-hetzner-vps "$1" "$2" "$image" ${args[parallel-build-deploy]:+"$buildPid"} || return
}

## Creates a new Hetzner Cloud VPS of name »name« and type/size »serverType«, optionally waits for »waitPid« to exit (successfully), copies the system image from the local »imagePath« to the new VPS, boots it, and waits until port 22 is open.
function deploy-image-to-hetzner-vps { # 1: name, 2: serverType, 3: imagePath, 4?: waitPid
    local name=$1 serverType=$2 imagePath=$3 waitPid=${4:-}
    local stdout=/dev/stdout ; if [[ ${args[quiet]:-} ]] ; then stdout=/dev/null ; fi

    local work ; work=$( mktemp -d ) && prepend_trap "rm -rf $work" EXIT || return
    local keyName ; for keyName in host login ; do
        @{native.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f $work/$keyName -C $keyName || return
    done

    echo 'Creating the VPS' >$stdout
    if [[ ! ${args[vps-keep-on-build-failure]:-} ]] ; then prepend_trap "if [[ ! -e $work/buildSucceeded ]] ; then @{native.hcloud}/bin/hcloud server delete '$name' ; fi" EXIT || return ; fi
    cat <<EOC |
#cloud-config
chpasswd: null
#ssh_pwauth: false
package_update: false
package_upgrade: false
ssh_authorized_keys:
    - '$( cat $work/login.pub )'
ssh_genkeytypes: [ ]
ssh_keys:
    ed25519_public: '$( cat $work/host.pub )'
    ed25519_private: |
$( cat $work/host | @{native.perl}/bin/perl -pe 's/^/        /' )
EOC
    @{native.hcloud}/bin/hcloud server create --image=ubuntu-22.04 --name="$name" --type="$serverType" --user-data-from-file - ${args[vps-suppress-create-email]:+--ssh-key dummy} >$stdout || return
    # @{native.hcloud}/bin/hcloud server poweron "$name" || return # --start-after-create=false

    local ip ; ip=$( @{native.hcloud}/bin/hcloud server ip "$name" ) && echo "$ip" >$work/ip || return
    printf "%s %s\n" "$ip" "$( cat $work/host.pub )" >$work/known_hosts || return
    local sshCmd ; sshCmd="@{native.openssh}/bin/ssh -oUserKnownHostsFile=$work/known_hosts -i $work/login root@$ip"

    printf %s 'Preparing the VPS/worker for image transfer ' >$stdout
    sleep 5 ; local i ; for i in $(seq 20) ; do sleep 1 ; if $sshCmd -- true &>/dev/null ; then break ; fi ; printf . >$stdout ; done ; printf ' ' >$stdout
    # The system takes a minimum of time to boot, so might as well chill first. Then the loop fails (loops) only before the VM is created, afterwards it blocks until sshd is up.
    $sshCmd 'set -o pipefail -u -e
        # echo u > /proc/sysrq-trigger # remount all FSes as r/o (did not cut it)
        mkdir /tmp/tmp-root ; mount -t tmpfs -o size=100% none /tmp/tmp-root
        umount /boot/efi ; rm -rf /var/lib/{apt,dpkg} /var/cache /usr/lib/firmware /boot ; printf . >'$stdout'
        cp -axT / /tmp/tmp-root/ ; printf . >'$stdout'
        mount --make-rprivate / ; mkdir -p /tmp/tmp-root/old-root
        pivot_root /tmp/tmp-root /tmp/tmp-root/old-root
        for i in dev proc run sys ; do mkdir -p /$i ; mount --move /old-root/$i /$i ; done
        systemctl daemon-reexec ; systemctl restart sshd
    ' || return ; echo . >$stdout

    if [[ $waitPid ]] ; then wait $buildPid || return ; fi
    echo 'Writing worker image to VPS' >$stdout
    @{native.zstd}/bin/zstd -c "$imagePath" | $sshCmd 'set -o pipefail -u -e
        </dev/null fuser -mk /old-root &>/dev/null ; sleep 2
        </dev/null umount /old-root
        </dev/null blkdiscard -f /dev/sda &>/dev/null
        </dev/null sync # this seems to be crucial
        zstdcat - >/dev/sda
        </dev/null sync # this seems to be crucial
    ' || return
    @{native.hcloud}/bin/hcloud server reset "$name" >$stdout || return

    printf %s 'Waiting for the worker to boot ' >$stdout
    sleep 2 ; local i ; for i in $(seq 20) ; do sleep 1 ; if ( exec 2>&- ; echo >/dev/tcp/"$ip"/22 ) ; then touch $work/buildSucceeded ; break ; fi ; printf . >$stdout ; done ; echo >$stdout

    if [[ ! -e $work/buildSucceeded ]] ; then echo 'Unable to connect to VPS worker, it may not have booted correctly ' 1>&2 ; \return 1 ; fi
}

#!/bin/bash
# vim:expandtab:shiftwidth=4:softtabstop=4:tabstop=4:

trap 'print_summary && echo "test-framework exiting on error"' ERR
set -e
#set -x


export REFORMAT=${REFORMAT:-""}
export VERBOSE=false
export GMNALNID=${GMNALNID:-/usr/sbin/gmlndnid}
export CATASTROPHE=${CATASTROPHE:-/proc/sys/lnet/catastrophe}
export GSS=false
export GSS_KRB5=false
export GSS_PIPEFS=false
export IDENTITY_UPCALL=default
#export PDSH="pdsh -S -Rssh -w"

# eg, assert_env LUSTRE MDSNODES OSTNODES CLIENTS
assert_env() {
    local failed=""
    for name in $@; do
        if [ -z "${!name}" ]; then
            echo "$0: $name must be set"
            failed=1
        fi
    done
    [ $failed ] && exit 1 || true
}

usage() {
    echo "usage: $0 [-r] [-f cfgfile]"
    echo "       -r: reformat"

    exit
}

print_summary () {
    [ "$TESTSUITE" == "lfscktest" ] && return 0
    [ -n "$ONLY" ] && echo "WARNING: ONLY is set to ${ONLY}."
    local form="%-13s %-17s %s\n"
    printf "$form" "status" "script" "skipped tests E(xcluded) S(low)"
    echo "------------------------------------------------------------------------------------"
    for O in $TESTSUITE_LIST; do
        local skipped=""
        local slow=""
        local o=$(echo $O | tr "[:upper:]" "[:lower:]")
        o=${o//_/-}
        o=${o//tyn/tyN}
        local log=${TMP}/${o}.log
        [ -f $log ] && skipped=$(grep excluded $log | awk '{ printf " %s", $3 }' | sed 's/test_//g')
        [ -f $log ] && slow=$(grep SLOW $log | awk '{ printf " %s", $3 }' | sed 's/test_//g')
        [ "${!O}" = "done" ] && \
            printf "$form" "Done" "$O" "E=$skipped" && \
            [ -n "$slow" ] && printf "$form" "-" "-" "S=$slow"

    done

    for O in $TESTSUITE_LIST; do
        [ "${!O}" = "no" ] && \
            printf "$form" "Skipped" "$O" ""
    done

    for O in $TESTSUITE_LIST; do
        [ "${!O}" = "done" -o "${!O}" = "no" ] || \
            printf "$form" "UNFINISHED" "$O" ""
    done
}

init_test_env() {
    export LUSTRE=`absolute_path $LUSTRE`
    export TESTSUITE=`basename $0 .sh`
    export LTESTDIR=${LTESTDIR:-$LUSTRE/../ltest}

    [ -d /r ] && export ROOT=${ROOT:-/r}
    export TMP=${TMP:-$ROOT/tmp}
    export TESTSUITELOG=${TMP}/${TESTSUITE}.log
    export HOSTNAME=${HOSTNAME:-`hostname`}

    export PATH=:$PATH:$LUSTRE/utils:$LUSTRE/utils/gss:$LUSTRE/tests
    export LCTL=${LCTL:-"$LUSTRE/utils/lctl"}
    [ ! -f "$LCTL" ] && export LCTL=$(which lctl)
    export LFS=${LFS:-"$LUSTRE/utils/lfs"}
    [ ! -f "$LFS" ] && export LFS=$(which lfs)
    export L_GETIDENTITY=${L_GETIDENTITY:-"$LUSTRE/utils/l_getidentity"}
    if [ ! -f "$L_GETIDENTITY" ]; then
        if `which l_getidentity > /dev/null 2>&1`; then
            export L_GETIDENTITY=$(which l_getidentity)
        else
            export L_GETIDENTITY=NONE
        fi
    fi
    export MKFS=${MKFS:-"$LUSTRE/utils/mkfs.lustre"}
    [ ! -f "$MKFS" ] && export MKFS=$(which mkfs.lustre)
    export TUNEFS=${TUNEFS:-"$LUSTRE/utils/tunefs.lustre"}
    [ ! -f "$TUNEFS" ] && export TUNEFS=$(which tunefs.lustre)
    export CHECKSTAT="${CHECKSTAT:-"checkstat -v"} "
    export FSYTPE=${FSTYPE:-"ldiskfs"}
    export NAME=${NAME:-local}
    export LPROC=/proc/fs/lustre
    export LGSSD=${LGSSD:-"$LUSTRE/utils/gss/lgssd"}
    [ "$GSS_PIPEFS" = "true" ] && [ ! -f "$LGSSD" ] && \
        export LGSSD=$(which lgssd)
    export LSVCGSSD=${LSVCGSSD:-"$LUSTRE/utils/gss/lsvcgssd"}
    [ ! -f "$LSVCGSSD" ] && export LSVCGSSD=$(which lsvcgssd)
    export KRB5DIR=${KRB5DIR:-"/usr/kerberos"}
    export DIR2

    if [ "$ACCEPTOR_PORT" ]; then
        export PORT_OPT="--port $ACCEPTOR_PORT"
    fi

    case "x$SEC" in
        xkrb5*)
            echo "Using GSS/krb5 ptlrpc security flavor"
            GSS=true
            GSS_KRB5=true
            ;;
    esac

    case "x$IDUP" in
        xtrue)
            IDENTITY_UPCALL=true
            ;;
        xfalse)
            IDENTITY_UPCALL=false
            ;;
    esac

    # Paths on remote nodes, if different
    export RLUSTRE=${RLUSTRE:-$LUSTRE}
    export RPWD=${RPWD:-$PWD}
    export I_MOUNTED=${I_MOUNTED:-"no"}

    # command line

    while getopts "rvf:" opt $*; do
        case $opt in
            f) CONFIG=$OPTARG;;
            r) REFORMAT=--reformat;;
            v) VERBOSE=true;;
            \?) usage;;
        esac
    done

    shift $((OPTIND - 1))
    ONLY=${ONLY:-$*}

    [ "$TESTSUITELOG" ] && rm -f $TESTSUITELOG || true

}

load_module() {
    EXT=".ko"
    module=$1
    shift
    BASE=`basename $module $EXT`
    lsmod | grep -q ${BASE} || \
      if [ -f ${LUSTRE}/${module}${EXT} ]; then
        insmod ${LUSTRE}/${module}${EXT} $@
    else
        # must be testing a "make install" or "rpm" installation
        # note failed to load ptlrpc_gss is considered not fatal
        if [ "$BASE" == "ptlrpc_gss" ]; then
            modprobe $BASE $@ 2>/dev/null || echo "gss/krb5 is not supported"
        else
            modprobe $BASE $@
        fi
    fi
}

load_modules() {
    if [ -n "$MODPROBE" ]; then
        # use modprobe
    return 0
    fi
    if [ "$HAVE_MODULES" = true ]; then
    # we already loaded
        return 0
    fi
    HAVE_MODULES=true

    echo Loading modules from $LUSTRE
    load_module ../lnet/libcfs/libcfs
    [ -f /etc/modprobe.conf ] && MODPROBECONF=/etc/modprobe.conf
    [ -f /etc/modprobe.d/Lustre ] && MODPROBECONF=/etc/modprobe.d/Lustre
    [ -z "$LNETOPTS" -a -n "$MODPROBECONF" ] && \
        LNETOPTS=$(awk '/^options lnet/ { print $0}' $MODPROBECONF | sed 's/^options lnet //g')
    echo "lnet options: '$LNETOPTS'"
    # note that insmod will ignore anything in modprobe.conf
    load_module ../lnet/lnet/lnet $LNETOPTS
    LNETLND=${LNETLND:-"socklnd/ksocklnd"}
    load_module ../lnet/klnds/$LNETLND
    load_module lvfs/lvfs
    load_module obdclass/obdclass
    load_module ptlrpc/ptlrpc
    load_module ptlrpc/gss/ptlrpc_gss
    # Now, some modules depend on lquota without USE_QUOTA check,
    # will fix later. Disable check "$USE_QUOTA" = "yes" temporary.
    #[ "$USE_QUOTA" = "yes" ] && load_module quota/lquota
    load_module quota/lquota
    load_module fid/fid
    load_module fld/fld
    load_module lmv/lmv
    load_module mdc/mdc
    load_module osc/osc
    load_module lov/lov
    load_module mgc/mgc
    if [ -z "$CLIENTONLY" ]; then
        [ "$FSTYPE" = "ldiskfs" ] && load_module ../ldiskfs/ldiskfs/ldiskfs
        load_module mgs/mgs
        load_module mds/mds
        load_module mdd/mdd
        load_module mdt/mdt
        load_module lvfs/fsfilt_$FSTYPE
        load_module cmm/cmm
        load_module osd/osd
        load_module ost/ost
        load_module obdfilter/obdfilter
    fi

    load_module llite/lustre
    load_module llite/llite_lloop
    rm -f $TMP/ogdb-$HOSTNAME
    OGDB=$TMP
    [ -d /r ] && OGDB="/r/tmp"
    $LCTL modules > $OGDB/ogdb-$HOSTNAME

    # 'mount' doesn't look in $PATH, just sbin
    [ -f $LUSTRE/utils/mount.lustre ] && cp $LUSTRE/utils/mount.lustre /sbin/. || true
}

RMMOD=rmmod
if [ `uname -r | cut -c 3` -eq 4 ]; then
    RMMOD="modprobe -r"
fi

wait_for_lnet() {
    local UNLOADED=0
    local WAIT=0
    local MAX=60
    MODULES=$($LCTL modules | awk '{ print $2 }')
    while [ -n "$MODULES" ]; do
    sleep 5
    $RMMOD $MODULES > /dev/null 2>&1 || true
    MODULES=$($LCTL modules | awk '{ print $2 }')
        if [ -z "$MODULES" ]; then
        return 0
        else
            WAIT=$((WAIT + 5))
            echo "waiting, $((MAX - WAIT)) secs left"
        fi
        if [ $WAIT -eq $MAX ]; then
            echo "LNET modules $MODULES will not unload"
        lsmod
            return 3
        fi
    done
}

unload_modules() {
    wait_exit_ST client # bug 12845

    lsmod | grep lnet > /dev/null && $LCTL dl && $LCTL dk $TMP/debug
    local MODULES=$($LCTL modules | awk '{ print $2 }')
    $RMMOD $MODULES > /dev/null 2>&1 || true
     # do it again, in case we tried to unload ksocklnd too early
    MODULES=$($LCTL modules | awk '{ print $2 }')
    [ -n "$MODULES" ] && $RMMOD $MODULES > /dev/null 2>&1 || true
    MODULES=$($LCTL modules | awk '{ print $2 }')
    if [ -n "$MODULES" ]; then
    echo "Modules still loaded: "
    echo $MODULES
    if [ -e $LPROC ]; then
        echo "Lustre still loaded"
        cat $LPROC/devices || true
        lsmod
        return 2
    else
        echo "Lustre stopped but LNET is still loaded, waiting..."
        wait_for_lnet || return 3
    fi
    fi
    HAVE_MODULES=false

    LEAK_LUSTRE=$(dmesg | tail -n 30 | grep "obd mem.*leaked" || true)
    LEAK_PORTALS=$(dmesg | tail -n 20 | grep "Portals memory leaked" || true)
    if [ "$LEAK_LUSTRE" -o "$LEAK_PORTALS" ]; then
        echo "$LEAK_LUSTRE" 1>&2
        echo "$LEAK_PORTALS" 1>&2
        mv $TMP/debug $TMP/debug-leak.`date +%s` || true
        echo "Memory leaks detected"
	[ -n "$IGNORE_LEAK" ] && echo "ignoring leaks" && return 0
        return 254
    fi
    echo "modules unloaded."
    return 0
}

check_gss_daemon_facet() {
    facet=$1
    dname=$2

    num=`do_facet $facet ps -o cmd -C $dname | grep $dname | wc -l`
    if [ $num -ne 1 ]; then
        echo "$num instance of $dname on $facet"
        return 1
    fi
    return 0
}

send_sigint() {
    local facet=$1
    shift
    do_facet $facet "killall -2 $@ 2>/dev/null || true"
}

start_gss_daemons() {
    # starting on MDT
    for num in `seq $MDSCOUNT`; do
        do_facet mds$num "$LSVCGSSD -v"
        if $GSS_PIPEFS; then
            do_facet mds$num "$LGSSD -v"
        fi
    done
    # starting on OSTs
    for num in `seq $OSTCOUNT`; do
        do_facet ost$num "$LSVCGSSD -v"
    done
    # starting on client
    # FIXME: is "client" the right facet name?
    if $GSS_PIPEFS; then
        do_facet client "$LGSSD -v"
    fi

    # wait daemons entering "stable" status
    sleep 5

    #
    # check daemons are running
    #
    for num in `seq $MDSCOUNT`; do
        check_gss_daemon_facet mds$num lsvcgssd
        if $GSS_PIPEFS; then
            check_gss_daemon_facet mds$num lgssd
        fi
    done
    for num in `seq $OSTCOUNT`; do
        check_gss_daemon_facet ost$num lsvcgssd
    done
    if $GSS_PIPEFS; then
        check_gss_daemon_facet client lgssd
    fi
}

stop_gss_daemons() {
    for num in `seq $MDSCOUNT`; do
        send_sigint mds$num lsvcgssd lgssd
    done
    for num in `seq $OSTCOUNT`; do
        send_sigint ost$num lsvcgssd
    done
    send_sigint client lgssd
}

init_gss() {
    if $GSS; then
        start_gss_daemons
    fi
}

cleanup_gss() {
    if $GSS; then
        stop_gss_daemons
        # maybe cleanup credential cache?
    fi
}

mdsdevlabel() {
    local num=$1
    local device=`mdsdevname $num`
    local label=`do_facet mds$num "e2label ${device}" | grep -v "CMD: "`
    echo -n $label
}

ostdevlabel() {
    local num=$1
    local device=`ostdevname $num`
    local label=`do_facet ost$num "e2label ${device}" | grep -v "CMD: "`
    echo -n $label
}

# Facet functions
# start facet device options
start() {
    facet=$1
    shift
    device=$1
    shift
    echo "Starting ${facet}: $@ ${device} ${MOUNT%/*}/${facet}"
    do_facet ${facet} mkdir -p ${MOUNT%/*}/${facet}
    do_facet ${facet} mount -t lustre $@ ${device} ${MOUNT%/*}/${facet}
    RC=${PIPESTATUS[0]}
    if [ $RC -ne 0 ]; then
        echo mount -t lustre $@ ${device} ${MOUNT%/*}/${facet}
        echo Start of ${device} on ${facet} failed ${RC}
    else
        do_facet ${facet} "sysctl -w lnet.debug=$PTLDEBUG; \
        sysctl -w lnet.subsystem_debug=${SUBSYSTEM# }; \
        sysctl -w lnet.debug_mb=${DEBUG_SIZE}"

        do_facet ${facet} sync
        label=$(do_facet ${facet} "e2label ${device}")
        [ -z "$label" ] && echo no label for ${device} && exit 1
        eval export ${facet}_svc=${label}
        eval export ${facet}_dev=${device}
        eval export ${facet}_opt=\"$@\"
        echo Started ${label}
    fi
    return $RC
}

stop() {
    local running
    facet=$1
    shift
    HOST=`facet_active_host $facet`
    [ -z $HOST ] && echo stop: no host for $facet && return 0

    running=$(do_facet ${facet} "grep -c ${MOUNT%/*}/${facet}' ' /proc/mounts") || true
    if [ ${running} -ne 0 ]; then
        echo "Stopping ${MOUNT%/*}/${facet} (opts:$@)"
        do_facet ${facet} umount -d $@ ${MOUNT%/*}/${facet}
    fi

    # umount should block, but we should wait for unrelated obd's
    # like the MGS or MGC to also stop.
    wait_exit_ST ${facet}
}

zconf_mount() {
    local OPTIONS
    local client=$1
    local mnt=$2
    # Only supply -o to mount if we have options
    if [ -n "$MOUNTOPT" ]; then
        OPTIONS="-o $MOUNTOPT"
    fi
    local device=$MGSNID:/$FSNAME
    if [ -z "$mnt" -o -z "$FSNAME" ]; then
        echo Bad zconf mount command: opt=$OPTIONS dev=$device mnt=$mnt
        exit 1
    fi

    echo "Starting client: $OPTIONS $device $mnt"
    do_node $client mkdir -p $mnt
    do_node $client mount -t lustre $OPTIONS $device $mnt || return 1

    do_node $client "sysctl -w lnet.debug=$PTLDEBUG;
        sysctl -w lnet.subsystem_debug=${SUBSYSTEM# };
        sysctl -w lnet.debug_mb=${DEBUG_SIZE}"
    [ -d /r ] && $LCTL modules > /r/tmp/ogdb-$HOSTNAME
    return 0
}

zconf_umount() {
    client=$1
    mnt=$2
    [ "$3" ] && force=-f
    local running=$(do_node $client "grep -c $mnt' ' /proc/mounts") || true
    if [ $running -ne 0 ]; then
        echo "Stopping client $mnt (opts:$force)"
        lsof | grep "$mnt" || true
        do_node $client umount $force $mnt
    fi
}

shutdown_facet() {
    facet=$1
    if [ "$FAILURE_MODE" = HARD ]; then
        $POWER_DOWN `facet_active_host $facet`
        sleep 2
    elif [ "$FAILURE_MODE" = SOFT ]; then
        stop $facet
    fi
}

reboot_facet() {
    facet=$1
    if [ "$FAILURE_MODE" = HARD ]; then
        $POWER_UP `facet_active_host $facet`
    else
        sleep 10
    fi
}

# verify that lustre actually cleaned up properly
cleanup_check() {
    [ -f $CATASTROPHE ] && [ `cat $CATASTROPHE` -ne 0 ] && \
        error "LBUG/LASSERT detected"
    BUSY=`dmesg | grep -i destruct || true`
    if [ "$BUSY" ]; then
        echo "$BUSY" 1>&2
        [ -e $TMP/debug ] && mv $TMP/debug $TMP/debug-busy.`date +%s`
        exit 205
    fi
    LEAK_LUSTRE=`dmesg | tail -n 30 | grep "obd mem.*leaked" || true`
    LEAK_PORTALS=`dmesg | tail -n 20 | grep "Portals memory leaked" || true`
    if [ "$LEAK_LUSTRE" -o "$LEAK_PORTALS" ]; then
        echo "$0: $LEAK_LUSTRE" 1>&2
        echo "$0: $LEAK_PORTALS" 1>&2
        echo "$0: Memory leak(s) detected..." 1>&2
        mv $TMP/debug $TMP/debug-leak.`date +%s`
        exit 204
    fi

    [ "`lctl dl 2> /dev/null | wc -l`" -gt 0 ] && lctl dl && \
        echo "$0: lustre didn't clean up..." 1>&2 && return 202 || true

    if [ "`/sbin/lsmod 2>&1 | egrep 'lnet|libcfs'`" ]; then
        echo "$0: modules still loaded..." 1>&2
        /sbin/lsmod 1>&2
        return 203
    fi
    return 0
}

wait_delete_completed () {
    local TOTALPREV=`awk 'BEGIN{total=0}; {total+=$1}; END{print total}' \
            $LPROC/osc/*/kbytesavail`

    local WAIT=0
    local MAX_WAIT=20
    while [ "$WAIT" -ne "$MAX_WAIT" ]; do
        sleep 1
        TOTAL=`awk 'BEGIN{total=0}; {total+=$1}; END{print total}' \
            $LPROC/osc/*/kbytesavail`
        [ "$TOTAL" -eq "$TOTALPREV" ] && break
        echo "Waiting delete completed ... prev: $TOTALPREV current: $TOTAL "
        TOTALPREV=$TOTAL
        WAIT=$(( WAIT + 1))
    done
    echo "Delete completed."
}

wait_for_host() {
    HOST=$1
    check_network "$HOST" 900
    while ! do_node $HOST "ls -d $LUSTRE " > /dev/null; do sleep 5; done
}

wait_for() {
    facet=$1
    HOST=`facet_active_host $facet`
    wait_for_host $HOST
}

wait_mds_recovery_done () {
    local timeout=`do_facet mds cat /proc/sys/lustre/timeout`
#define OBD_RECOVERY_TIMEOUT (obd_timeout * 5 / 2)
# as we are in process of changing obd_timeout in different ways
# let's set MAX longer than that
    MAX=$(( timeout * 4 ))
    WAIT=0
    while [ $WAIT -lt $MAX ]; do
        STATUS=`do_facet $SINGLEMDS grep status /proc/fs/lustre/mdt/*-MDT*/recovery_status`
        echo $STATUS | grep COMPLETE && return 0
        sleep 5
        WAIT=$((WAIT + 5))
        echo "Waiting $(($MAX - $WAIT)) secs for MDS recovery done"
    done
    echo "MDS recovery not done in $MAX sec"
    return 1
}

wait_exit_ST () {
    local facet=$1

    local WAIT=0
    local INTERVAL=1
    # conf-sanity 31 takes a long time cleanup
    while [ $WAIT -lt 300 ]; do
        running=$(do_facet ${facet} "[ -e $LPROC ] && grep ST' ' $LPROC/devices") || true
        [ -z "${running}" ] && return 0
        echo "waited $WAIT for${running}"
        [ $INTERVAL -lt 64 ] && INTERVAL=$((INTERVAL + INTERVAL))
        sleep $INTERVAL
        WAIT=$((WAIT + INTERVAL))
    done
    echo "service didn't stop after $WAIT seconds.  Still running:"
    echo ${running}
    return 1
}

client_df() {
    # not every config has many clients
    if [ ! -z "$CLIENTS" ]; then
        $PDSH $CLIENTS "df $MOUNT" > /dev/null
    fi
}

client_reconnect() {
    uname -n >> $MOUNT/recon
    if [ ! -z "$CLIENTS" ]; then
        $PDSH $CLIENTS "df $MOUNT; uname -n >> $MOUNT/recon" > /dev/null
    fi
    echo Connected clients:
    cat $MOUNT/recon
    ls -l $MOUNT/recon > /dev/null
    rm $MOUNT/recon
}

facet_failover() {
    facet=$1
    echo "Failing $facet on node `facet_active_host $facet`"
    shutdown_facet $facet
    reboot_facet $facet
    client_df &
    DFPID=$!
    echo "df pid is $DFPID"
    change_active $facet
    TO=`facet_active_host $facet`
    echo "Failover $facet to $TO"
    wait_for $facet
    local dev=${facet}_dev
    local opt=${facet}_opt
    start $facet ${!dev} ${!opt} || error "Restart of $facet failed"
}

obd_name() {
    local facet=$1
}

replay_barrier() {
    local facet=$1
    do_facet $facet sync
    df $MOUNT
    local svc=${facet}_svc
    do_facet $facet $LCTL --device %${!svc} readonly
    do_facet $facet $LCTL --device %${!svc} notransno
    do_facet $facet $LCTL mark "$facet REPLAY BARRIER on ${!svc}"
    $LCTL mark "local REPLAY BARRIER on ${!svc}"
}

replay_barrier_nodf() {
    local facet=$1    echo running=${running}
    do_facet $facet sync
    local svc=${facet}_svc
    echo Replay barrier on ${!svc}
    do_facet $facet $LCTL --device %${!svc} readonly
    do_facet $facet $LCTL --device %${!svc} notransno
    do_facet $facet $LCTL mark "$facet REPLAY BARRIER on ${!svc}"
    $LCTL mark "local REPLAY BARRIER on ${!svc}"
}

mds_evict_client() {
    UUID=`cat /proc/fs/lustre/mdc/${mds1_svc}-mdc-*/uuid`
    do_facet mds1 "echo $UUID > /proc/fs/lustre/mdt/${mds1_svc}/evict_client"
}

ost_evict_client() {
    UUID=`grep ${ost1_svc}-osc- $LPROC/devices | egrep -v 'MDT' | awk '{print $5}'`
    do_facet ost1 "echo $UUID > /proc/fs/lustre/obdfilter/${ost1_svc}/evict_client"
}

fail() {
    facet_failover $* || error "failover: $?"
    df $MOUNT || error "post-failover df: $?"
}

fail_nodf() {
        local facet=$1
        facet_failover $facet
}

fail_abort() {
    local facet=$1
    stop $facet
    change_active $facet
    local svc=${facet}_svc
    local dev=${facet}_dev
    local opt=${facet}_opt
    start $facet ${!dev} ${!opt}
    do_facet $facet lctl --device %${!svc} abort_recovery
    df $MOUNT || echo "first df failed: $?"
    sleep 1
    df $MOUNT || error "post-failover df: $?"
}

do_lmc() {
    echo There is no lmc.  This is mountconf, baby.
    exit 1
}

h2gm () {
    if [ "$1" = "client" -o "$1" = "'*'" ]; then echo \'*\'; else
        ID=`$PDSH $1 $GMNALNID -l | cut -d\  -f2`
        echo $ID"@gm"
    fi
}

h2name_or_ip() {
    if [ "$1" = "client" -o "$1" = "'*'" ]; then echo \'*\'; else
        echo $1"@$2"
    fi
}

h2ptl() {
   if [ "$1" = "client" -o "$1" = "'*'" ]; then echo \'*\'; else
       ID=`xtprocadmin -n $1 2>/dev/null | egrep -v 'NID' | awk '{print $1}'`
       if [ -z "$ID" ]; then
           echo "Could not get a ptl id for $1..."
           exit 1
       fi
       echo $ID"@ptl"
   fi
}
declare -fx h2ptl

h2tcp() {
    h2name_or_ip "$1" "tcp"
}
declare -fx h2tcp

h2elan() {
    if [ "$1" = "client" -o "$1" = "'*'" ]; then echo \'*\'; else
        if type __h2elan >/dev/null 2>&1; then
            ID=$(__h2elan $1)
        else
            ID=`echo $1 | sed 's/[^0-9]*//g'`
        fi
        echo $ID"@elan"
    fi
}
declare -fx h2elan

h2openib() {
    h2name_or_ip "$1" "openib"
}
declare -fx h2openib

h2o2ib() {
    h2name_or_ip "$1" "o2ib"
}
declare -fx h2o2ib

facet_host() {
    local facet=$1
    varname=${facet}_HOST
    if [ -z "${!varname}" ]; then
        if [ "${facet:0:3}" == "ost" ]; then
            eval ${facet}_HOST=${ost_HOST}
        fi
    fi
    echo -n ${!varname}
}

facet_active() {
    local facet=$1
    local activevar=${facet}active

    if [ -f ./${facet}active ] ; then
        source ./${facet}active
    fi

    active=${!activevar}
    if [ -z "$active" ] ; then
        echo -n ${facet}
    else
        echo -n ${active}
    fi
}

facet_active_host() {
    local facet=$1
    local active=`facet_active $facet`
    if [ "$facet" == client ]; then
        echo $HOSTNAME
    else
        echo `facet_host $active`
    fi
}

change_active() {
    local facet=$1
    failover=${facet}failover
    host=`facet_host $failover`
    [ -z "$host" ] && return
    curactive=`facet_active $facet`
    if [ -z "${curactive}" -o "$curactive" == "$failover" ] ; then
        eval export ${facet}active=$facet
    else
        eval export ${facet}active=$failover
    fi
    # save the active host for this facet
    activevar=${facet}active
    echo "$activevar=${!activevar}" > ./$activevar
}

do_node() {
    HOST=$1
    shift
    local myPDSH=$PDSH
    if [ "$HOST" = "$HOSTNAME" ]; then
        myPDSH="no_dsh"
    elif [ -z "$myPDSH" -o "$myPDSH" = "no_dsh" ]; then
        echo "cannot run remote command on $HOST with $myPDSH"
        return 128
    fi
    if $VERBOSE; then
        echo "CMD: $HOST $@" >&2
        $myPDSH $HOST $LCTL mark "$@" > /dev/null 2>&1 || :
    fi

    if [ "$myPDSH" = "rsh" ]; then
# we need this because rsh does not return exit code of an executed command
	local command_status="$TMP/cs"
	rsh $HOST ":> $command_status"
	rsh $HOST "(PATH=\$PATH:$RLUSTRE/utils:$RLUSTRE/tests:/sbin:/usr/sbin;
		    cd $RPWD; sh -c \"$@\") || 
		    echo command failed >$command_status"
	[ -n "$($myPDSH $HOST cat $command_status)" ] && return 1 || true
        return 0
    fi
    $myPDSH $HOST "(PATH=\$PATH:$RLUSTRE/utils:$RLUSTRE/tests:/sbin:/usr/sbin; cd $RPWD; sh -c \"$@\")" | sed "s/^${HOST}: //"
    return ${PIPESTATUS[0]}
}

do_facet() {
    facet=$1
    shift
    HOST=`facet_active_host $facet`
    [ -z $HOST ] && echo No host defined for facet ${facet} && exit 1
    do_node $HOST $@
}

add() {
    local facet=$1
    shift
    # make sure its not already running
    stop ${facet} -f
    rm -f ${facet}active
    do_facet ${facet} $MKFS $*
}

ostdevname() {
    num=$1
    DEVNAME=OSTDEV$num
    #if $OSTDEVn isn't defined, default is $OSTDEVBASE + num
    eval DEVPTR=${!DEVNAME:=${OSTDEVBASE}${num}}
    echo -n $DEVPTR
}

mdsdevname() {
    num=$1
    DEVNAME=MDSDEV$num
    #if $MDSDEVn isn't defined, default is $MDSDEVBASE + num
    eval DEVPTR=${!DEVNAME:=${MDSDEVBASE}${num}}
    echo -n $DEVPTR
}

########
## MountConf setup

stopall() {
    # make sure we are using the primary server, so test-framework will
    # be able to clean up properly.
    activemds=`facet_active mds1`
    if [ $activemds != "mds1" ]; then
        fail mds1
    fi

    # assume client mount is local
    grep " $MOUNT " /proc/mounts && zconf_umount $HOSTNAME $MOUNT $*
    grep " $MOUNT2 " /proc/mounts && zconf_umount $HOSTNAME $MOUNT2 $*
    [ "$CLIENTONLY" ] && return
    for num in `seq $MDSCOUNT`; do
        stop mds$num -f
    done
    for num in `seq $OSTCOUNT`; do
        stop ost$num -f
    done
    return 0
}

cleanupall() {
    stopall $*
    unload_modules
    cleanup_gss
}

mdsmkfsopts()
{
    local nr=$1
    test $nr = 1 && echo -n $MDS_MKFS_OPTS || echo -n $MDSn_MKFS_OPTS
}

formatall() {
    [ "$FSTYPE" ] && FSTYPE_OPT="--backfstype $FSTYPE"

    if [ ! -z $SEC ]; then
        MDS_MKFS_OPTS="$MDS_MKFS_OPTS --param srpc.flavor.default=$SEC"
        OST_MKFS_OPTS="$OST_MKFS_OPTS --param srpc.flavor.default=$SEC"
    fi

    stopall
    # We need ldiskfs here, may as well load them all
    load_modules
    [ "$CLIENTONLY" ] && return
    echo "Formatting mdts, osts"
    for num in `seq $MDSCOUNT`; do
        echo "Format mds$num: $(mdsdevname $num)"
        if $VERBOSE; then
            add mds$num `mdsmkfsopts $num` $FSTYPE_OPT --reformat `mdsdevname $num` || exit 9
        else
            add mds$num `mdsmkfsopts $num` $FSTYPE_OPT --reformat `mdsdevname $num` > /dev/null || exit 9
        fi
    done

    for num in `seq $OSTCOUNT`; do
        echo "Format ost$num: $(ostdevname $num)"
        if $VERBOSE; then
            add ost$num $OST_MKFS_OPTS --reformat `ostdevname $num` || exit 10
        else
            add ost$num $OST_MKFS_OPTS --reformat `ostdevname $num` > /dev/null || exit 10
        fi
    done
}

mount_client() {
    grep " $1 " /proc/mounts || zconf_mount $HOSTNAME $*
}

umount_client() {
    grep " $1 " /proc/mounts && zconf_umount `hostname` $*
}

# return value:
# 0: success, the old identity set already.
# 1: success, the old identity does not set.
# 2: fail.
switch_identity() {
    local num=$1
    local switch=$2
    local j=`expr $num - 1`
    local MDT="`do_facet mds$num find $LPROC/mdt/ -name \*MDT\*$j -printf %f 2>/dev/null || true`"

    if [ -z "$MDT" ]; then
        return 2
    fi

    local old="`do_facet mds$num cat $LPROC/mdt/$MDT/identity_upcall`"

    if $switch; then
        do_facet mds$num "echo \"$L_GETIDENTITY\" > $LPROC/mdt/$MDT/identity_upcall"
    else
        do_facet mds$num "echo \"NONE\" > $LPROC/mdt/$MDT/identity_upcall"
    fi

    do_facet mds$num "echo \"-1\" > $LPROC/mdt/$MDT/identity_flush"

    if [ $old = "NONE" ]; then
        return 1
    else
        return 0
    fi
}

remount_client()
{
	zconf_umount `hostname` $1 || error "umount failed"
	zconf_mount `hostname` $1 || error "mount failed"
}

set_obd_timeout() {
    local facet=$1
    local timeout=$2

    do_facet $facet lsmod | grep -q obdclass || \
        do_facet $facet "modprobe obdclass"

    do_facet $facet "sysctl -w lustre.timeout=$timeout"
}

setupall() {
    load_modules
    init_gss
    if [ -z "$CLIENTONLY" ]; then
        echo "Setup mdts, osts"
        for num in `seq $MDSCOUNT`; do
            DEVNAME=$(mdsdevname $num)
            echo $REFORMAT | grep -q "reformat" \
            || do_facet mds$num "$TUNEFS --writeconf $DEVNAME"
            set_obd_timeout mds$num $TIMEOUT
            start mds$num $DEVNAME $MDS_MOUNT_OPTS
	    if [ $IDENTITY_UPCALL != "default" ]; then
                switch_identity $num $IDENTITY_UPCALL
	    fi
        done
        for num in `seq $OSTCOUNT`; do
            DEVNAME=$(ostdevname $num)
            set_obd_timeout ost$num $TIMEOUT
            start ost$num $DEVNAME $OST_MOUNT_OPTS
        done
    fi
    [ "$DAEMONFILE" ] && $LCTL debug_daemon start $DAEMONFILE $DAEMONSIZE
    mount_client $MOUNT
    if [ "$MOUNT_2" ]; then
	mount_client $MOUNT2
    fi

    # by remounting mdt before ost, initial connect from mdt to ost might
    # timeout because ost is not ready yet. wait some time to its fully
    # recovery. initial obd_connect timeout is 5s; in GSS case it's preceeded
    # by a context negotiation rpc with $TIMEOUT.
    # FIXME better by monitoring import status.
    if $GSS; then
        sleep $((TIMEOUT + 5))
    else
        sleep 5
    fi
}

mounted_lustre_filesystems() {
	awk '($3 ~ "lustre" && $1 ~ ":") { print $2 }' /proc/mounts
}

check_and_setup_lustre() {
    MOUNTED="`mounted_lustre_filesystems`"
    if [ -z "$MOUNTED" ]; then
        [ "$REFORMAT" ] && formatall
        setupall
        MOUNTED="`mounted_lustre_filesystems`"
        [ -z "$MOUNTED" ] && error "NAME=$NAME not mounted"
        export I_MOUNTED=yes
    fi
    if [ "$ONLY" == "setup" ]; then
        exit 0
    fi
}

cleanup_and_setup_lustre() {
    if [ "$ONLY" == "cleanup" -o "`mount | grep $MOUNT`" ]; then
        sysctl -w lnet.debug=0 || true
        cleanupall
        if [ "$ONLY" == "cleanup" ]; then
    	    exit 0
        fi
    fi
    check_and_setup_lustre
}

check_and_cleanup_lustre() {
    if [ "`mount | grep $MOUNT`" ]; then
        [ -n "$DIR" ] && rm -rf $DIR/[Rdfs][0-9]*
    fi
    if [ "$I_MOUNTED" = "yes" ]; then
        cleanupall -f || error "cleanup failed"
    fi
    unset I_MOUNTED
}

#######
# General functions

check_network() {
    local NETWORK=0
    local WAIT=0
    local MAX=$2
    while [ $NETWORK -eq 0 ]; do
        ping -c 1 -w 3 $1 > /dev/null
        if [ $? -eq 0 ]; then
            NETWORK=1
        else
            WAIT=$((WAIT + 5))
            echo "waiting for $1, $((MAX - WAIT)) secs left"
            sleep 5
        fi
        if [ $WAIT -gt $MAX ]; then
            echo "Network not available"
            exit 1
        fi
    done
}
check_port() {
    while( !($DSH2 $1 "netstat -tna | grep -q $2") ) ; do
        sleep 9
    done
}

no_dsh() {
    shift
    eval $@
}

comma_list() {
    # the sed converts spaces to commas, but leaves the last space
    # alone, so the line doesn't end with a comma.
    echo "$*" | tr -s " " "\n" | sort -b -u | tr "\n" " " | sed 's/ \([^$]\)/,\1/g'
}

absolute_path() {
    (cd `dirname $1`; echo $PWD/`basename $1`)
}

##################################
# OBD_FAIL funcs

drop_request() {
# OBD_FAIL_MDS_ALL_REQUEST_NET
    RC=0
    do_facet mds sysctl -w lustre.fail_loc=0x123
    do_facet client "$1" || RC=$?
    do_facet mds sysctl -w lustre.fail_loc=0
    return $RC
}

drop_reply() {
# OBD_FAIL_MDS_ALL_REPLY_NET
    RC=0
    do_facet mds sysctl -w lustre.fail_loc=0x122
    do_facet client "$@" || RC=$?
    do_facet mds sysctl -w lustre.fail_loc=0
    return $RC
}

drop_reint_reply() {
# OBD_FAIL_MDS_REINT_NET_REP
    RC=0
    do_facet mds sysctl -w lustre.fail_loc=0x119
    do_facet client "$@" || RC=$?
    do_facet mds sysctl -w lustre.fail_loc=0
    return $RC
}

pause_bulk() {
#define OBD_FAIL_OST_BRW_PAUSE_BULK      0x214
    RC=0
    do_facet ost1 sysctl -w lustre.fail_loc=0x214
    do_facet client "$1" || RC=$?
    do_facet client "sync"
    do_facet ost1 sysctl -w lustre.fail_loc=0
    return $RC
}

drop_ldlm_cancel() {
#define OBD_FAIL_LDLM_CANCEL             0x304
    RC=0
    do_facet client sysctl -w lustre.fail_loc=0x304
    do_facet client "$@" || RC=$?
    do_facet client sysctl -w lustre.fail_loc=0
    return $RC
}

drop_bl_callback() {
#define OBD_FAIL_LDLM_BL_CALLBACK        0x305
    RC=0
    do_facet client sysctl -w lustre.fail_loc=0x305
    do_facet client "$@" || RC=$?
    do_facet client sysctl -w lustre.fail_loc=0
    return $RC
}

drop_ldlm_reply() {
#define OBD_FAIL_LDLM_REPLY              0x30c
    RC=0
    do_facet mds sysctl -w lustre.fail_loc=0x30c
    do_facet client "$@" || RC=$?
    do_facet mds sysctl -w lustre.fail_loc=0
    return $RC
}

clear_failloc() {
    facet=$1
    pause=$2
    sleep $pause
    echo "clearing fail_loc on $facet"
    do_facet $facet "sysctl -w lustre.fail_loc=0"
}

cancel_lru_locks() {
    $LCTL mark "cancel_lru_locks $1 start"
    for d in `find $LPROC/ldlm/namespaces | egrep -i $1`; do
        [ -f $d/lru_size ] && echo clear > $d/lru_size
        [ -f $d/lock_unused_count ] && grep [1-9] $d/lock_unused_count /dev/null
    done
    $LCTL mark "cancel_lru_locks $1 stop"
}

default_lru_size()
{
        NR_CPU=$(grep -c "processor" /proc/cpuinfo)
        DEFAULT_LRU_SIZE=$((100 * NR_CPU))
        echo "$DEFAULT_LRU_SIZE"
}

lru_resize_enable()
{
        NS=$1
        test "x$NS" = "x" && NS="mdc"
        for F in $LPROC/ldlm/namespaces/*$NS*/lru_size; do
                D=$(dirname $F)
                log "Enable lru resize for $(basename $D)"
                echo "0" > $F
        done
}

lru_resize_disable()
{
        NS=$1
        test "x$NS" = "x" && NS="mdc"
        for F in $LPROC/ldlm/namespaces/*$NS*/lru_size; do
                D=$(dirname $F)
                log "Disable lru resize for $(basename $D)"
                DEFAULT_LRU_SIZE=$(default_lru_size)
                echo "$DEFAULT_LRU_SIZE" > $F
        done
}

pgcache_empty() {
    for a in /proc/fs/lustre/llite/*/dump_page_cache; do
        if [ `wc -l $a | awk '{print $1}'` -gt 1 ]; then
            echo there is still data in page cache $a ?
            cat $a;
            return 1;
        fi
    done
    return 0
}

debugsave() {
    DEBUGSAVE="$(sysctl -n lnet.debug)"
}

debugrestore() {
    [ -n "$DEBUGSAVE" ] && sysctl -w lnet.debug="${DEBUGSAVE}"
    DEBUGSAVE=""
}

##################################
# Test interface
##################################

error() {
    local FAIL_ON_ERROR=${FAIL_ON_ERROR:-true}
    local TYPE=${TYPE:-"FAIL"}
    local ERRLOG
    sysctl -w lustre.fail_loc=0 2> /dev/null || true
    log " ${TESTSUITE} ${TESTNAME}: @@@@@@ ${TYPE}: $@ "
    ERRLOG=$TMP/lustre_${TESTSUITE}_${TESTNAME}.$(date +%s)
    echo "Dumping lctl log to $ERRLOG"
    # We need to dump the logs on all nodes
    local NODES=$(nodes_list)
    for NODE in $NODES; do
        do_node $NODE $LCTL dk $ERRLOG
    done
    debugrestore
    [ "$TESTSUITELOG" ] && echo "$0: ${TYPE}: $TESTNAME $@" >> $TESTSUITELOG
    if $FAIL_ON_ERROR; then
	exit 1
    fi
}

# use only if we are ignoring failures for this test, bugno required.
# (like ALWAYS_EXCEPT, but run the test and ignore the results.)
# e.g. error_ignore 5494 "your message"
error_ignore() {
    FAIL_ON_ERROR=false TYPE="IGNORE (bz$1)" error $2
}

skip () {
	log " SKIP: ${TESTSUITE} ${TESTNAME} $@"
	[ "$TESTSUITELOG" ] && echo "${TESTSUITE}: SKIP: $TESTNAME $@" >> $TESTSUITELOG
}

build_test_filter() {
    [ "$ONLY" ] && log "only running test `echo $ONLY`"
    for O in $ONLY; do
        eval ONLY_${O}=true
    done
    [ "$EXCEPT$ALWAYS_EXCEPT" ] && \
        log "skipping tests: `echo $EXCEPT $ALWAYS_EXCEPT`"
    [ "$EXCEPT_SLOW" ] && \
        log "skipping tests SLOW=no: `echo $EXCEPT_SLOW`"
    for E in $EXCEPT $ALWAYS_EXCEPT; do
        eval EXCEPT_${E}=true
    done
    for E in $EXCEPT_SLOW; do
        eval EXCEPT_SLOW_${E}=true
    done
    for G in $GRANT_CHECK_LIST; do
        eval GCHECK_ONLY_${G}=true
   	done
}

_basetest() {
    echo $*
}

basetest() {
    IFS=abcdefghijklmnopqrstuvwxyz _basetest $1
}

run_test() {
    export base=`basetest $1`
    if [ ! -z "$ONLY" ]; then
        testname=ONLY_$1
        if [ ${!testname}x != x ]; then
            run_one $1 "$2"
            return $?
        fi
        testname=ONLY_$base
        if [ ${!testname}x != x ]; then
            run_one $1 "$2"
            return $?
        fi
        echo -n "."
        return 0
    fi
    testname=EXCEPT_$1
    if [ ${!testname}x != x ]; then
        TESTNAME=test_$1 skip "skipping excluded test $1"
        return 0
    fi
    testname=EXCEPT_$base
    if [ ${!testname}x != x ]; then
        TESTNAME=test_$1 skip "skipping excluded test $1 (base $base)"
        return 0
    fi
    testname=EXCEPT_SLOW_$1
    if [ ${!testname}x != x ]; then
        TESTNAME=test_$1 skip "skipping SLOW test $1"
        return 0
    fi
    testname=EXCEPT_SLOW_$base
    if [ ${!testname}x != x ]; then
        TESTNAME=test_$1 skip "skipping SLOW test $1 (base $base)"
        return 0
    fi

    run_one $1 "$2"

    return $?
}

EQUALS="======================================================================"
equals_msg() {
    msg="$@"

    local suffixlen=$((${#EQUALS} - ${#msg}))
    [ $suffixlen -lt 5 ] && suffixlen=5
    log `echo $(printf '===== %s %.*s\n' "$msg" $suffixlen $EQUALS)`
}

log() {
    echo "$*"
    lsmod | grep lnet > /dev/null || load_modules

    local MSG="$*"
    # Get rif of '
    MSG=${MSG//\'/\\\'}
    MSG=${MSG//\(/\\\(}
    MSG=${MSG//\)/\\\)}
    MSG=${MSG//\;/\\\;}
    MSG=${MSG//\|/\\\|}
    MSG=${MSG//\>/\\\>}
    MSG=${MSG//\</\\\<}
    local NODES=$(nodes_list)
    for NODE in $NODES; do
        do_node $NODE $LCTL mark "$MSG" 2> /dev/null || true
    done
}

trace() {
	log "STARTING: $*"
	strace -o $TMP/$1.strace -ttt $*
	RC=$?
	log "FINISHED: $*: rc $RC"
	return 1
}

pass() {
    echo PASS $@
}

check_mds() {
    FFREE=`cat /proc/fs/lustre/osd/*MDT*/filesfree`
    FTOTAL=`cat /proc/fs/lustre/osd/*MDT*/filestotal`
    [ $FFREE -ge $FTOTAL ] && error "files free $FFREE > total $FTOTAL" || true
}

reset_fail_loc () {
    local myNODES=$(nodes_list)
    local NODE

    for NODE in $myNODES; do
        do_node $NODE sysctl -w lustre.fail_loc=0 || true
    done
}

run_one() {
    testnum=$1
    message=$2
    tfile=f${testnum}
    export tdir=d0.${TESTSUITE}/d${base}
    local SAVE_UMASK=`umask`
    umask 0022
    mkdir -p $DIR/$tdir

    BEFORE=`date +%s`
    log "== test $testnum: $message ============ `date +%H:%M:%S` ($BEFORE)"
    #check_mds
    export TESTNAME=test_$testnum
    test_${testnum} || error "test_$testnum failed with $?"
    #check_mds
    reset_fail_loc
    check_grant ${testnum} || error "check_grant $testnum failed with $?"
    [ -f $CATASTROPHE ] && [ `cat $CATASTROPHE` -ne 0 ] && \
        error "LBUG/LASSERT detected"
    pass "($((`date +%s` - $BEFORE))s)"
    rmdir ${DIR}/$tdir >/dev/null 2>&1 || true
    unset TESTNAME
    unset tdir
    umask $SAVE_UMASK
    cd $SAVE_PWD
    $CLEANUP
}

canonical_path() {
    (cd `dirname $1`; echo $PWD/`basename $1`)
}

sync_clients() {
    [ -d $DIR1 ] && cd $DIR1 && sync; sleep 1; sync
    [ -d $DIR2 ] && cd $DIR2 && sync; sleep 1; sync
	cd $SAVE_PWD
}

check_grant() {
    export base=`basetest $1`
    [ "$CHECK_GRANT" == "no" ] && return 0

	testname=GCHECK_ONLY_${base}
        [ ${!testname}x == x ] && return 0

	echo -n "checking grant......"
	cd $SAVE_PWD
	# write some data to sync client lost_grant
	rm -f $DIR1/${tfile}_check_grant_* 2>&1
	for i in `seq $OSTCOUNT`; do
		$LFS setstripe $DIR1/${tfile}_check_grant_$i -i $(($i -1)) -c 1
		dd if=/dev/zero of=$DIR1/${tfile}_check_grant_$i bs=4k \
					      count=1 > /dev/null 2>&1
	done
	# sync all the data and make sure no pending data on server
	sync_clients
	
	#get client grant and server grant
	client_grant=0
    for d in ${LPROC}/osc/*/cur_grant_bytes; do
		client_grant=$((client_grant + `cat $d`))
	done
	server_grant=0
	for d in ${LPROC}/obdfilter/*/tot_granted; do
		server_grant=$((server_grant + `cat $d`))
	done

	# cleanup the check_grant file
	for i in `seq $OSTCOUNT`; do
	        rm $DIR1/${tfile}_check_grant_$i
	done

	#check whether client grant == server grant
	if [ $client_grant != $server_grant ]; then
		echo "failed: client:${client_grant} server: ${server_grant}"
		return 1
	else
		echo "pass"
	fi
}

########################
# helper functions

osc_to_ost()
{
    osc=$1
    ost=`echo $1 | awk -F_ '{print $3}'`
    if [ -z $ost ]; then
        ost=`echo $1 | sed 's/-osc.*//'`
    fi
    echo $ost
}

remote_mds ()
{
    [ ! -e /proc/fs/lustre/mdt/*MDT* ]
}

remote_mds_nodsh()
{
    remote_mds && [ "$PDSH" = "no_dsh" -o -z "$PDSH" -o -z "$mds_HOST" ]
}

remote_ost ()
{
    [ $(grep -c obdfilter $LPROC/devices) -eq 0 ]
}

remote_ost_nodsh()
{
    remote_ost && [ "$PDSH" = "no_dsh" -o -z "$PDSH" -o -z "$ost_HOST" ]
}

mdts_nodes () {
    local MDSNODES=$(facet_host $SINGLEMDS)
    local NODES_sort

    # FIXME: Currenly we use only $SINGLEMDS,
    # should be fixed when we will start to test cmd.
    echo $MDSNODES
    return

    for num in `seq $MDSCOUNT`; do
        local myMDS=$(facet_host mds$num)
        MDSNODES="$MDSNODES $myMDS"
    done
    NODES_sort=$(for i in $MDSNODES; do echo $i; done | sort -u)

    echo $NODES_sort
}

osts_nodes () {
    local OSTNODES=$(facet_host ost1)
    local NODES_sort

    for num in `seq $OSTCOUNT`; do
        local myOST=$(facet_host ost$num)
        OSTNODES="$OSTNODES $myOST"
    done
    NODES_sort=$(for i in $OSTNODES; do echo $i; done | sort -u)

    echo $NODES_sort
}

nodes_list () {
    # FIXME. We need a list of clients
    local myNODES=$HOSTNAME
    local myNODES_sort

    if [ "$PDSH" -a "$PDSH" != "no_dsh" ]; then
        myNODES="$myNODES $(osts_nodes) $(mdts_nodes)"
    fi

    myNODES_sort=$(for i in $myNODES; do echo $i; done | sort -u)

    echo $myNODES_sort
}

is_patchless ()
{
    grep -q patchless $LPROC/version
}

check_runas_id() {
    local myRUNAS_ID=$1
    shift
    local myRUNAS=$@

    if $GSS_KRB5; then
        $myRUNAS krb5_login.sh || \
            error "Failed to refresh Kerberos V5 TGT for UID $myRUNAS_ID."
    fi

    mkdir $DIR/d0_runas_test
    chmod 0755 $DIR
    chown $myRUNAS_ID:$myRUNAS_ID $DIR/d0_runas_test
    $myRUNAS touch $DIR/d0_runas_test/f$$ || \
        error "unable to write to $DIR/d0_runas_test as UID $myRUNAS_ID.
        Please set RUNAS_ID to some UID which exists on MDS and client or
        add user $myRUNAS_ID:$myRUNAS_ID on these nodes."
    rm -rf $DIR/d0_runas_test
}

# Run multiop in the background, but wait for it to print
# "PAUSING" to its stdout before returning from this function.
multiop_bg_pause() {
    MULTIOP_PROG=${MULTIOP_PROG:-multiop}
    FILE=$1
    ARGS=$2

    TMPPIPE=/tmp/multiop_open_wait_pipe.$$
    mkfifo $TMPPIPE

    echo "$MULTIOP_PROG $FILE v$ARGS"
    $MULTIOP_PROG $FILE v$ARGS > $TMPPIPE &

    echo "TMPPIPE=${TMPPIPE}"
    read -t 60 multiop_output < $TMPPIPE
    if [ $? -ne 0 ]; then
        rm -f $TMPPIPE
        return 1
    fi
    rm -f $TMPPIPE
    if [ "$multiop_output" != "PAUSING" ]; then
        echo "Incorrect multiop output: $multiop_output"
        kill -9 $PID
        return 1
    fi

    return 0
}

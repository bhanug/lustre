FSNAME=lustre

# facet hosts
mds_HOST=${mds_HOST:-`hostname`}
mdsfailover_HOST=${mdsfailover_HOST}
mgs_HOST=${mgs_HOST:-$mds_HOST}
ost_HOST=${ost_HOST:-`hostname`}
ostfailover_HOST=${ostfailover_HOST}
PDSH=${PDSH:-no_dsh}

TMP=${TMP:-/tmp}
MDSDEV=${MDSDEV:-$TMP/${FSNAME}-mdt}
MDSSIZE=${MDSSIZE:-400000}
MDSOPT=${MDSOPT:-"--mountfsoptions=user_xattr,acl,"}

OSTCOUNT=${OSTCOUNT:-6}
OSTDEVBASE=${OSTDEVBASE:-$TMP/${FSNAME}-ost}
OSTSIZE=${OSTSIZE:-150000}

NETTYPE=${NETTYPE:-tcp}
MGSNID=${MGSNID:-`h2$NETTYPE $mgs_HOST`}
FSTYPE=${FSTYPE:-ldiskfs}
STRIPE_BYTES=${STRIPE_BYTES:-1048576}
STRIPES_PER_OBJ=${STRIPES_PER_OBJ:-$((OSTCOUNT -1))}
TIMEOUT=${TIMEOUT:-20}
PTLDEBUG=${PTLDEBUG:-0x33f0404}
SUBSYSTEM=${SUBSYSTEM:- 0xffb7e3ff}

L_GETGROUPS=${L_GETGROUPS:-`do_facet mds which l_getgroups || echo`}

MKFSOPT=""
MOUNTOPT=""
[ "x$MDSJOURNALSIZE" != "x" ] &&
    MKFSOPT=$MKFSOPT" -J size=$MDSJOURNALSIZE"
[ "x$MDSISIZE" != "x" ] &&
    MKFSOPT=$MKFSOPT" -i $MDSISIZE"
[ "x$MKFSOPT" != "x" ] &&
    MKFSOPT="--mkfsoptions=\"$MKFSOPT\""
[ "x$mdsfailover_HOST" != "x" ] &&
    MOUNTOPT=$MOUNTOPT" --failnode=`h2$NETTYPE $mdsfailover_HOST`"
[ "x$STRIPE_BYTES" != "x" ] &&
    MOUNTOPT=$MOUNTOPT" --param lov.stripesize=$STRIPE_BYTES"
[ "x$STRIPES_PER_OBJ" != "x" ] &&
    MOUNTOPT=$MOUNTOPT" --param lov.stripecount=$STRIPES_PER_OBJ"
[ "x$L_GETGROUPS" != "x" ] &&
    MOUNTOPT=$MOUNTOPT" --param mdt.group_upcall=$L_GETGROUPS"
MDS_MKFS_OPTS="--mgs --mdt --fsname=$FSNAME --device-size=$MDSSIZE --param sys.timeout=$TIMEOUT $MKFSOPT $MOUNTOPT $MDSOPT"

MKFSOPT=""
MOUNTOPT=""
[ "x$OSTJOURNALSIZE" != "x" ] &&
    MKFSOPT=$MKFSOPT" -J size=$OSTJOURNALSIZE"
[ "x$MKFSOPT" != "x" ] &&
    MKFSOPT="--mkfsoptions=\"$MKFSOPT\""
[ "x$ostfailover_HOST" != "x" ] &&
    MOUNTOPT=$MOUNTOPT" --failnode=`h2$NETTYPE $ostfailover_HOST`"
OST_MKFS_OPTS="--ost --fsname=$FSNAME --device-size=$OSTSIZE --mgsnode=$MGSNID --param sys.timeout=$TIMEOUT $MKFSOPT $MOUNTOPT $OSTOPT"

MDS_MOUNT_OPTS="-o loop"
OST_MOUNT_OPTS="-o loop"

#client
MOUNT=${MOUNT:-/mnt/${FSNAME}}
MOUNT1=${MOUNT1:-$MOUNT}
MOUNT2=${MOUNT2:-${MOUNT}2}
MOUNTOPT=${MOUNTOPT:-"user_xattr,"}
DIR=${DIR:-$MOUNT}
DIR1=${DIR:-$MOUNT1}
DIR2=${DIR2:-$MOUNT2}

FAILURE_MODE=${FAILURE_MODE:-SOFT} # or HARD
POWER_DOWN=${POWER_DOWN:-"powerman --off"}
POWER_UP=${POWER_UP:-"powerman --on"}

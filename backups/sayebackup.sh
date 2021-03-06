#!/bin/bash
# Licensed GNU GPLv3 or later: http://www.gnu.org/licenses/lgpl.html

# die with descriptive error messages
SCRIPTNAME=`basename $0` ; STARTPWD=`pwd`
function die  { e="$1"; shift; [ -n "$*" ] && echo "$SCRIPTNAME: $*" >&2; exit "$e" ; }
function warn { [ -n "$*" ] && echo "$SCRIPTNAME: warning: $*" >&2; }

# default config
CWD=
SOURCES=
INC=false
DRY=false
FPREFIX=bak-
FPOSTFIX=-snap
IPREFIX=bak-
IPOSTFIX=-rinc
RSYNC_OPTIONS="--partial"
RSYNC_QUIET='-v --progress'	# -i -v=verbose
NOP=-p	# used as "NOP" rsync option
EXCLUDEFILE=$NOP
SSHACCOUNT=
SSHPORT=
SSHKEYFILE=
unset LINKDESTS	# array of --link-dest arguments
if [ -z "$RSYNC_BINARY" ]; then
  BINRSYNC=rsync
else
  BINRSYNC=`readlink -f "$RSYNC_BINARY"`
  [ -x "$BINRSYNC" ] || die 1 "Failed to execute rsync binary: $BINRSYNC"
fi

# usage and help
function usagedie { # exitcode message...
  e="$1"; shift;
  [ -n "$*" ] && echo "$SCRIPTNAME: $*" >&2
  echo "Usage: $SCRIPTNAME [options] sources..."
  echo "OPTIONS:"
  echo "  --inc		make reverse incremental backup"
  echo "  --dry		run and show rsync with --dry-run option"
  echo "  --help	print usage summary"
  echo "  -C <dir>	backup directory (default: '.')"
  echo "  -E <exclfile>	file with rsync exclude list"
  echo "  -l <account>	ssh user name to use (see ssh(1) -l)"
  echo "  -i <identity>	ssh identity key file to use (see ssh(1) -i)"
  echo "  -P <sshport>	ssh port to use on the remote system"
  echo "  -L <linkdest>	hardlink dest files from <linkdest>/"
  echo "  -o <prefix>	output directory name (default: 'bak')"
  echo "  -q, --quiet	suppress progress information"
  echo "  -c		perform checksum based file content comparisons"
  echo "  --one-file-system"
  echo "  -x            disable crossing of filesystem boundaries"
  echo "  --version     script and rsync versions"
  echo "DESCRIPTION:"
  echo "  This script creates full or reverse incremental backups using the"
  echo "  rsync(1) command. Backup directory names contain the date and time"
  echo "  of each backup run to allow sorting and selective pruning."
  echo "  At the end of each successful backup run, a symlink '*-current' is"
  echo "  updated to always point at the latest backup. To reduce remote file"
  echo "  transfers, the '-L' option can be used (possibly multiple times) to"
  echo "  specify existing local file trees from which files will be"
  echo "  hard-linked into the backup."
  echo " Full Backups:"
  echo "  Upon each invocation, a new backup directory is created that contains"
  echo "  all files of the source system. Hard links are created to files of"
  echo "  previous backups where possible, so extra storage space is only required"
  echo "  for contents that changed between backups."
  echo " Incremental Backups:"
  echo "  In incremental mode, the most recent backup is always a full backup,"
  echo "  while the previous full backup is degraded to a reverse incremental"
  echo "  backup, which only contains differences between the current and the"
  echo "  last backup."
  echo " RSYNC_BINARY Environment variable used to override the rsync binary path."
  exit "$e"
}

# parse options
[ -z "$*" ] && usagedie 0
parse_options=1
while test $# -ne 0 -a $parse_options = 1; do
  case "$1" in
    --dry-run|--dry)  	DRY=true ;;   # simulation
    --inc)		INC=true ;;
    -c)			RSYNC_OPTIONS="$RSYNC_OPTIONS -c" ;;
    -x|--one-file-system) RSYNC_OPTIONS="$RSYNC_OPTIONS -x" ;;
    -q|--quiet)		RSYNC_QUIET=-q ;;
    --help)		usagedie 0 ;;
    -C)			CWD="$2" ; shift ;;
    -E)			EXCLUDEFILE="$2" ; shift ;;
    -o)			IPREFIX="$2"- ; FPREFIX="$2"- ; shift ;;
    -l)			SSHACCOUNT="$2" ; shift ;;
    -i)			SSHKEYFILE="$2" ; shift ;;
    -P)			SSHPORT="$2" ; shift ;;
    -L)			LINKDESTS[$[${#LINKDESTS[@]}+1]]="$2" ; shift ;;
    --version)		echo "sayebackup.sh version 0.0.1"; $BINRSYNC --version | head -n1 ; exit 0 ;;
    --)  		parse_options=0 ;;
    -*)		     	usagedie 1 "option not supported: $1" ;;
    *)		     	parse_options=0 ; break ;;
  esac
  shift
done
[ -z "$*" ] && usagedie 1 "No sources specified"

# operate in backup directory
[ -n "$CWD" ] && { cd "$CWD"/. || die 2 "Invalid CWD: $CWD" ; }
[ -z "$CWD" -a / = "`pwd`" ] && die 2 "Refusing to backup in / - invoked from cron without -C?"
pwd | fgrep -q : && die 2 "CWD contains invalid special (rsync) character: :"

# create --link-dest arguments with absolute pathnames
for i in `seq ${#LINKDESTS[@]}` ; do
  ldest="${LINKDESTS[$i]}"
  [ "${ldest:0:1}" != "/" ] && ldest="$STARTPWD/$ldest"
  LINKDESTS[$i]="--link-dest=$ldest"
done

# setup definitions
CURRENT="$FPREFIX""current"
unset COMPRESS	# only set on remote invocation
RSHCOMMAND="--rsh=ssh -x -oBatchMode=yes -oStrictHostKeyChecking=no -oCompression=yes"
[ -n "$SSHPORT" ] && RSHCOMMAND="$RSHCOMMAND -p $SSHPORT"
[ -n "$SSHACCOUNT$SSHKEYFILE" ] && {
  [ -n "$SSHACCOUNT" ] && RSHCOMMAND="$RSHCOMMAND -l $SSHACCOUNT"
  [ "${SSHKEYFILE:0:1}" != "/" ] && SSHKEYFILE="$STARTPWD/$SSHKEYFILE"
  [ -n "$SSHKEYFILE" ] && RSHCOMMAND="$RSHCOMMAND -i $SSHKEYFILE -o IdentitiesOnly=yes"
  COMPRESS="--compress-level=7"
}
echo " $*" | fgrep -q : && COMPRESS="--compress-level=7"
[ -n "$COMPRESS" ] && RSYNC_OPTIONS="$RSYNC_OPTIONS $COMPRESS --block-size=33000"
# block-size=33000 needed for rsync<3.0.7, see: http://samba.anu.edu.au/rsync/FAQ.html#13 # inflate (token) returned -5
NOWDIR="$FPREFIX"`date +%Y-%m-%d-%H:%M:%S`"$FPOSTFIX"	# assumed to be sortable

# find last backup for hard links
[ -L "$CURRENT" ] && {
	LAST=`readlink "$CURRENT"`
} || {
	LAST=`find . -maxdepth 1 -name "$FPREFIX*$FPOSTFIX" | sort | tail -n1`
}
INCDIR=`printf %s "$LAST" | sed "s,^\(\./\)\?\($FPREFIX\)\?,$IPREFIX, ; s,\($FPOSTFIX\)\?$,$IPOSTFIX,"`

# sanity checks
[ -d "$NOWDIR" ] &&		die 3 "Target backup dir exists already: $NOWDIR"
$INC && [ -d "$INCDIR" ] &&	die 3 "Incremental target exists already: $INCDIR"
  #$INC && [ ! -d "$LAST" ] &&	die 3 "Missing last backup dir: $LAST"

# handle exclude files
[ "$EXCLUDEFILE" != $NOP ] && {
	[ ! -e "$EXCLUDEFILE" ] && die 3 "Missing exclude file: $EXCLUDEFILE"
	EXCLUDEFILE="--exclude-from=$EXCLUDEFILE"
}

# prepare transfer directories
LASTLINKDIR=
if $DRY ; then
  TARGET_DIR="./$NOWDIR"
  MODE="$MODE --dry-run"
else
  # create temporary working directory without special-:
  TMPDIR=`mktemp -d "./sayebackup_tmpXXXXXX"` || die 5 "$0: Failed to create temporary dir"
  trap 'rm -rf "$TMPDIR"' 0 HUP QUIT TRAP USR1 PIPE TERM
  # prepare incremental/full backups
  if $INC ; then
    # clone old backup with hard links to reduce transfers
    [ -d "$LAST" ] && {
      cp -al "$LAST" "$TMPDIR/full" || warn "Failed to fully clone backup dir: $LAST -> $TMPDIR/full"
    }
    LASTLINKDIR="--link-dest=../full --backup-dir=../incremental"
    MODE="-ab --del --ignore-errors"
  else
    # symlink old backup to reduce transfers (and avoid special-:)
    [ -n "$LAST" ] && {
      ln -s "../$LAST" "$TMPDIR/lasttransfer"
      LASTLINKDIR="--link-dest=../lasttransfer"
    }
    MODE="-aH"
  fi
  TARGET_DIR="$TMPDIR/full"
fi

# work around bogus "file vanished" messages, see https://bugzilla.samba.org/show_bug.cgi?id=3653
VANISHING_PATTERN='^(file has vanished: |rsync warning: some files vanished before they could be transferred)'

# run rsync, destination full/, reusing lasttransfer/, backup dir is incremental/
( $DRY && set -x # echo commands
  nice -n15 ionice -c3 \
    $BINRSYNC $RSYNC_QUIET "$RSHCOMMAND" "$EXCLUDEFILE" $RSYNC_OPTIONS $MODE $LASTLINKDIR "${LINKDESTS[@]}" "$@" "$TARGET_DIR" ) \
    2> >(egrep -v "$VANISHING_PATTERN")
RSYNC_CODE="$?"

$DRY && exit 0

# handle rsync error codes
case "$RSYNC_CODE" in
  0)	;; 						# success
  24)	;;						# some source files vanished
  25)	;;						# deletion lmit reached
  23)	trap "" 0 HUP INT QUIT TRAP USR1 PIPE TERM 	# partial transfer (ENOSPC)
        die 7 "Incomplete backup (partial transfer) - retaining temporaries: $TMPDIR" ;;
  20)	trap "" 0 HUP INT QUIT TRAP USR1 PIPE TERM 	# interrupted (got SIGINT)
        die 7 "Interruption during rsync - retaining temporaries: $TMPDIR" ;;
  130)	trap "" 0 HUP INT QUIT TRAP USR1 PIPE TERM 	# interrupted (child died, SIGINT?)
        die 7 "Interruption during rsync - retaining temporaries: $TMPDIR" ;;
  *)	die 7 "Error during rsync ($RSYNC_CODE) - purging temporaries..." ;;
esac

# make sure the file system contents have been writen out before renaming
sync ; sync ; sync

# rename newly synced backup dir
mv "$TMPDIR/full" "$NOWDIR" || die 8 "Failed to create target backup dir: $TMPDIR/full -> $NOWDIR"

# point to newly synced backup dir
[ -L "$CURRENT" -o ! -e "$CURRENT" ] && {
  rm -f "$CURRENT" && ln -s "$NOWDIR" "$CURRENT"
}

# finish incremental backups
$INC && {
  # rename newly created incremental dir
  [ -d "$TMPDIR"/incremental ] && {
    mv "$TMPDIR"/incremental "$INCDIR" || \
      die 8 "Failed to create target backup dir: $TMPDIR/incremental -> $INCDIR"
  }
  # purge olddir, $INCDIR replaces it
  [ -w "$LAST" ] && { rm -rf "$LAST" || warn "Failed to purge left over dir: $LAST" ; }
}

# cleanup
rm -f "$TMPDIR/lasttransfer"
rmdir "$TMPDIR"

# ensure everything is flushed to disk
sync
sync	# some unixes use staggered syncing

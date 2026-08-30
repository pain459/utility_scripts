#!/usr/bin/env bash
#
# photo-sync
#
# One-way, accumulating photo sync using rsync.
#
# Behaviour:
#   - New files on the memory card are copied to destination.
#   - Existing identical files are skipped.
#   - Changed files are updated.
#   - Files deleted from the memory card remain in destination.
#   - Destination-only files are NEVER deleted.
#   - Interrupted transfers can be resumed.
#
# Usage:
#   photo-sync [options] <source> <destination>
#
# Examples:
#   photo-sync /media/$USER/SONY /mnt/STORAGE/photos
#   photo-sync --dry-run /media/$USER/SONY /mnt/STORAGE/photos
#   photo-sync --verify /media/$USER/SONY /mnt/STORAGE/photos
#   Sample location of mmc /run/media/ravik/disk
#   To sync location /run/media/ravik/COLD/camera_dump

set -Eeuo pipefail


# -------------------------------------------------------------------
# Defaults
# -------------------------------------------------------------------

DRY_RUN=false
VERIFY=false
VERBOSE=false


# -------------------------------------------------------------------
# Functions
# -------------------------------------------------------------------

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [options] <source> <destination>

Options:
  -n, --dry-run
      Show what would be copied without making any changes.

  -c, --verify
      Compare file contents using checksums instead of relying only
      on file size and modification time.

  -v, --verbose
      Show individual file changes.

  -h, --help
      Show this help.

Examples:

  Normal sync:
    $(basename "$0") /media/\$USER/SONY /mnt/STORAGE/photos

  Preview first:
    $(basename "$0") --dry-run /media/\$USER/SONY /mnt/STORAGE/photos

  Checksum-based sync:
    $(basename "$0") --verify /media/\$USER/SONY /mnt/STORAGE/photos

IMPORTANT:
  This is a one-way accumulating sync.

  Deleting a file from SOURCE does NOT delete it from DESTINATION.

EOF
}


die() {
    echo "ERROR: $*" >&2
    exit 1
}


cleanup() {
    # Reserved for future cleanup requirements.
    :
}


trap cleanup EXIT
trap 'echo; echo "Sync interrupted." >&2; exit 130' INT TERM


# -------------------------------------------------------------------
# Parse arguments
# -------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;

        -c|--verify)
            VERIFY=true
            shift
            ;;

        -v|--verbose)
            VERBOSE=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            shift
            break
            ;;

        -*)
            die "Unknown option: $1"
            ;;

        *)
            break
            ;;
    esac
done


if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi


SOURCE="${1%/}"
DEST="${2%/}"


# -------------------------------------------------------------------
# Safety checks
# -------------------------------------------------------------------

command -v rsync >/dev/null 2>&1 ||
    die "rsync is not installed."

[[ -d "$SOURCE" ]] ||
    die "Source directory does not exist: $SOURCE"

[[ -r "$SOURCE" ]] ||
    die "Source directory is not readable: $SOURCE"

# Do NOT automatically create the destination.
#
# This protects against accidentally writing thousands of photos
# into a local directory when an external storage disk failed
# to mount.
[[ -d "$DEST" ]] ||
    die "Destination directory does not exist: $DEST"

[[ -w "$DEST" ]] ||
    die "Destination directory is not writable: $DEST"


SOURCE_REAL="$(realpath "$SOURCE")"
DEST_REAL="$(realpath "$DEST")"


[[ "$SOURCE_REAL" != "$DEST_REAL" ]] ||
    die "Source and destination are the same directory."


# Prevent obviously dangerous destinations.
case "$DEST_REAL" in
    /|/home|/usr|/etc|/var|/bin|/sbin)
        die "Refusing suspicious destination: $DEST_REAL"
        ;;
esac


# -------------------------------------------------------------------
# Display operation
# -------------------------------------------------------------------

echo
echo "============================================================"
echo "                    PHOTO SYNC"
echo "============================================================"
echo
echo " Source      : $SOURCE_REAL"
echo " Destination : $DEST_REAL"
echo
echo " Mode        : One-way accumulating sync"
echo " Dry run     : $DRY_RUN"
echo " Checksum    : $VERIFY"
echo
echo " Destination-only files will NOT be deleted."
echo "============================================================"
echo


# -------------------------------------------------------------------
# rsync options
# -------------------------------------------------------------------

RSYNC_OPTS=(
    --recursive
    --times

    # Human-readable output.
    --human-readable

    # Overall transfer progress.
    --info=progress2

    # Keep partially transferred files so interrupted imports
    # don't have to start large files from zero.
    --partial

    # Put partial files in a dedicated directory.
    --partial-dir=.rsync-partial

    # Handle filenames containing spaces and unusual characters.
    --protect-args

    # Filesystem statistics at the end.
    --stats
)


if $DRY_RUN; then
    RSYNC_OPTS+=(--dry-run)
fi


if $VERIFY; then
    # Compare actual file contents.
    #
    # This is slower because every source and destination file
    # must be read completely.
    RSYNC_OPTS+=(--checksum)
fi


if $VERBOSE; then
    RSYNC_OPTS+=(
        --verbose
        --itemize-changes
    )
fi


# -------------------------------------------------------------------
# Synchronize
# -------------------------------------------------------------------
#
# IMPORTANT:
#
# There is deliberately NO:
#
#   --delete
#   --delete-before
#   --delete-after
#   --delete-during
#   --delete-excluded
#
# Therefore files existing only in DESTINATION are left untouched.
#
# The trailing slash on SOURCE is intentional:
#
#   SOURCE/
#
# means "copy the contents of SOURCE into DEST".
#
# -------------------------------------------------------------------

rsync \
    "${RSYNC_OPTS[@]}" \
    "$SOURCE_REAL/" \
    "$DEST_REAL/"


# -------------------------------------------------------------------
# Result
# -------------------------------------------------------------------

echo

if $DRY_RUN; then
    echo "============================================================"
    echo " Dry run complete."
    echo " No files were changed."
    echo "============================================================"
else
    echo "============================================================"
    echo " Photo sync complete."
    echo " Destination-only files were preserved."
    echo "============================================================"
fi

echo


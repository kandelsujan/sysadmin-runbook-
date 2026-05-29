#!/usr/bin/env bash
# Author: Sujan Kandel
# Description: Archives files from a source NFS share to a destination NFS share
#              for a given year, validates the transfer via checksum, retries any
#              failed files up to a configurable limit, deletes validated files
#              from the source, cleans up empty directories, and logs all activity.
#
# Usage: ./archive.sh [ARCHIVE_YEAR]
#        ARCHIVE_YEAR defaults to the current year if not provided.
#
# Environment variable overrides:
#        SOURCE_SHARE       - Source NFS share path
#        DESTINATION_SHARE  - Destination NFS share path
#        LOG_DIRECTORY      - Directory to write logs and manifests
#        DRY_RUN            - Set to 'true' to test without moving files
#        MAX_RETRIES        - Number of retry attempts for failed files (default 3)

# -------------------------------------------------------------
# set -euo pipefail
# -e  : Exit immediately if any command returns a non-zero status.
#       Prevents the script from continuing after a failure.
# -u  : Treat unset variables as errors. Prevents silent failures
#       from typos in variable names.
# -o pipefail : If any command in a pipeline fails, the whole pipeline
#       returns a non-zero status. Without this, only the last
#       command's exit status is checked.
# -------------------------------------------------------------
set -euo pipefail

# -------------------------------------------------------------
# Explicitly set PATH for cron compatibility.
# Cron runs with a minimal environment and may not have the same
# PATH as an interactive shell. Without this, commands like rsync,
# flock, and stat may not be found when the script runs via cron.
# -------------------------------------------------------------
export PATH=/usr/local/bin:/usr/bin:/bin

# ============================================================
# CONFIGURATION
# Each variable uses the syntax ${VAR:-default} which means:
# use the environment variable if set, otherwise use the default.
# This allows the script to be configured without editing it,
# which is useful for testing or running in different environments.
# ============================================================

SOURCE_SHARE=${SOURCE_SHARE:-'/home/sk901741/garbage_data'}
DESTINATION_SHARE=${DESTINATION_SHARE:-'/home/sk901741/local_development/shell_scripts/work_in_progess/test_rsync_location'}
LOG_DIRECTORY=${LOG_DIRECTORY:-'/home/sk901741/local_development/shell_scripts/work_in_progess'}

# Accept archive year as first CLI argument, defaulting to the current year.
# This makes the script reusable across years without editing it.
ARCHIVE_YEAR=${1:-$(date +%Y)}

# Calculate the year boundaries used in the find command.
# We look for files newer than Dec 31 of the prior year and
# not newer than Jan 1 of the next year, which cleanly captures
# all files modified during the archive year.
PRIOR_YEAR_ARCHIVE=$(( ARCHIVE_YEAR - 1 ))
NEXT_YEAR_ARCHIVE=$(( ARCHIVE_YEAR + 1 ))

# Dry run mode allows testing the script without actually moving
# or deleting files. Set DRY_RUN=true in the environment to enable.
DRY_RUN=${DRY_RUN:-false}

# Maximum number of retry attempts for files that fail checksum
# validation. Configurable via environment variable so it can be
# adjusted without editing the script. Default is 3 attempts.
MAX_RETRIES=${MAX_RETRIES:-3}

# Email address to notify when retries are exhausted and manual
# intervention is required.
ALERT_EMAIL=${ALERT_EMAIL:-'admin@yourdomain.com'}

# -------------------------------------------------------------
# Log files - year is appended so each year's run gets its own
# log files and they never overwrite each other.
#
# ARCHIVE_LOG_FILE : Structured, human-readable log written by
#                    the log() function with timestamps and levels.
# STDERR_LOG_FILE  : Catch-all for any unexpected output or errors
#                    that bypass the log() function, such as bash
#                    errors triggered by set -euo pipefail.
# -------------------------------------------------------------
ARCHIVE_LOG_FILE="${LOG_DIRECTORY}/archive_${ARCHIVE_YEAR}.log"
STDERR_LOG_FILE="${LOG_DIRECTORY}/archive_stderr_${ARCHIVE_YEAR}.log"

# Lock file prevents two instances of the script from running at
# the same time, which could cause duplicate transfers or data
# corruption. Only one process can hold the lock at a time.
LOCK_FILE="${LOG_DIRECTORY}/archive.LCK"

# -------------------------------------------------------------
# Manifest and reference logs - year appended for same reason
# as log files above.
#
# ARCHIVE_MANIFEST  : Full list of files found by find_files().
#                     Written before rsync so we have a permanent
#                     record of what was intended to be archived,
#                     regardless of whether rsync succeeds. Also
#                     fed directly into rsync and validation via
#                     --files-from to avoid loading 1M+ paths into
#                     memory as a bash array.
#
# FAILED_FILES_LOG  : Files that failed checksum validation written
#                     by rsync_cmp(). Captures full file paths using
#                     rsync --out-format="%f" so the list can be used
#                     directly as input for retry attempts without
#                     having to grep through the main log. Updated
#                     after each retry attempt to reflect only the
#                     files still failing. Source files are never
#                     deleted if this file has any entries.
#
# DELETED_FILES_LOG : Full list of files successfully deleted from
#                     the source share after validation. Written
#                     immediately as each file is deleted to provide
#                     a real-time audit trail. Critical when moving
#                     1M+ files as it shows exactly what was removed
#                     even if the script is interrupted mid-deletion.
# -------------------------------------------------------------
ARCHIVE_MANIFEST="${LOG_DIRECTORY}/manifest_${ARCHIVE_YEAR}.txt"
FAILED_FILES_LOG="${LOG_DIRECTORY}/failed_files_${ARCHIVE_YEAR}.txt"
DELETED_FILES_LOG="${LOG_DIRECTORY}/deleted_files_${ARCHIVE_YEAR}.txt"

# ============================================================
# INITIAL SETUP
# This runs before any functions are called or the lock is acquired.
# ============================================================

# Create log directory if it doesn't exist.
# -p flag prevents an error if the directory already exists and
# also creates any missing parent directories.
mkdir -p "${LOG_DIRECTORY}"

# Redirect all stdout and stderr from this point forward to the
# stderr log file. This captures anything that bypasses the log()
# function, such as errors from set -euo pipefail, unexpected
# command output, or stack traces. We use >> to append rather than
# overwrite so previous runs are not lost.
exec >> "${STDERR_LOG_FILE}" 2>&1

# -------------------------------------------------------------
# Acquire an exclusive lock using file descriptor 9.
# exec 9> opens the lock file on FD 9.
# flock -n 9 attempts a non-blocking lock on FD 9.
# If another process already holds the lock, flock returns non-zero
# and we log the error and exit rather than waiting.
# We log directly here instead of using the log() function because
# trap and log() are not yet set up at this point.
# -------------------------------------------------------------
exec 9> "${LOCK_FILE}"
flock -n 9 || {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] Another process is currently running. Aborting..." >> "${ARCHIVE_LOG_FILE}"
    exit 1
}

# ============================================================
# FUNCTIONS
# ============================================================

# -------------------------------------------------------------
# log()
# Writes a structured, timestamped message to the archive log.
# All log entries follow the format:
#   [YYYY-MM-DD HH:MM:SS] [LEVEL] Message
#
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $2 - Message to log
#
# We use >> to append so the log file grows across the run.
# We do NOT use tee here since this script runs via cron and
# there is no terminal to write to.
# -------------------------------------------------------------
log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "${ARCHIVE_LOG_FILE}"
}

# -------------------------------------------------------------
# cleanup()
# Registered with trap to run automatically when the script exits,
# whether it exits normally, via exit 1, or due to a signal.
# This ensures the lock file and file descriptor are always cleaned
# up even if the script fails partway through.
# -------------------------------------------------------------
cleanup() {
    # Only remove the lock file if it exists.
    # Guards against the edge case where cleanup runs before the
    # lock file was created.
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}"
    fi

    # Close file descriptor 9.
    # This releases the flock lock and is good practice to avoid
    # leaking file descriptors.
    exec 9>&-

    log "INFO" "Cleanup complete. Exiting."
}

# -------------------------------------------------------------
# notify_failure()
# Sends an email alert when retries are exhausted and manual
# intervention is required. Uses mailx if available.
#
# We check for mailx availability before attempting to send
# rather than letting a missing command trigger set -e and
# obscure the real error that caused the alert.
#
# Arguments:
#   $1 - Subject line for the alert email
#   $2 - Body of the alert email
# -------------------------------------------------------------
notify_failure() {
    local subject=$1
    local body=$2

    if command -v mailx &>/dev/null; then
        echo "${body}" | mailx -s "${subject}" "${ALERT_EMAIL}"
        log "INFO" "Failure notification sent to ${ALERT_EMAIL}"
    else
        log "WARN" "mailx not available. Could not send failure notification to ${ALERT_EMAIL}"
    fi
}

# -------------------------------------------------------------
# verify_nfs_shares()
# Confirms that both source and destination paths are NFS mounts.
# We use nfs* (glob) rather than an exact match for "nfs" so that
# both nfs and nfs4 mount types are accepted.
#
# We use exit 1 rather than return 1 because a non-NFS mount is a
# fatal error. There is no point continuing the script if the shares
# are not what we expect — we could end up moving files to or from
# the wrong location entirely.
# -------------------------------------------------------------
verify_nfs_shares() {
    local source_type
    local dest_type
    source_type=$(stat -f -c %T "${SOURCE_SHARE}")
    dest_type=$(stat -f -c %T "${DESTINATION_SHARE}")

    if [[ "${source_type}" == nfs* ]]; then
        log "INFO" "Source share is an NFS mount (${source_type})"
    else
        log "ERROR" "Source share is not an NFS mount (found: ${source_type}). EXITING..."
        exit 1
    fi

    if [[ "${dest_type}" == nfs* ]]; then
        log "INFO" "Destination share is an NFS mount (${dest_type})"
    else
        log "ERROR" "Destination share is not an NFS mount (found: ${dest_type}). EXITING..."
        exit 1
    fi
}

# -------------------------------------------------------------
# verify_write_permissions()
# Confirms the script can write to both the source and destination
# shares before attempting any file operations.
#
# We use $$ (current PID) in the test filename to avoid collisions
# if two processes somehow start at the same time before the lock
# is acquired.
#
# We redirect touch errors to /dev/null because we are deliberately
# testing for failure and do not want the error output cluttering
# the stderr log — we handle the failure ourselves via the log function.
#
# We use exit 1 rather than return 1 because inability to write
# is a fatal error. Continuing without write permissions would cause
# rsync to fail anyway, but with a much less clear error message.
# -------------------------------------------------------------
verify_write_permissions() {
    local source_test_file="${SOURCE_SHARE}/.write_test_$$"
    local dest_test_file="${DESTINATION_SHARE}/.write_test_$$"

    if touch "${source_test_file}" 2>/dev/null; then
        rm -f "${source_test_file}"
        log "INFO" "Script has write permissions on the source share"
    else
        log "ERROR" "Script does not have write permissions on the source share. EXITING..."
        exit 1
    fi

    if touch "${dest_test_file}" 2>/dev/null; then
        rm -f "${dest_test_file}"
        log "INFO" "Script has write permissions on the destination share"
    else
        log "ERROR" "Script does not have write permissions on the destination share. EXITING..."
        exit 1
    fi
}

# -------------------------------------------------------------
# find_files()
# Finds all files on the source share that were last modified
# during the archive year and writes them to the manifest file.
#
# We write directly to the manifest file rather than storing paths
# in a bash array because with 1M+ files, loading everything into
# memory as an array would be unreliable and slow. Writing to a
# file is much more memory efficient and gives us the manifest as
# a side effect for free.
#
# The find date boundaries work as follows:
#   -newermt "${PRIOR_YEAR}-12-31"    : modified after Dec 31 of prior year
#   ! -newermt "${NEXT_YEAR}-01-01"   : and not modified on or after Jan 1 of next year
# Together these capture everything modified during the archive year.
#
# We only look for files (-type f) here. Directories do not need
# to be in the manifest because rsync -aR recreates the full
# directory structure automatically when transferring the files.
# Similarly, delete_source_files handles directory cleanup
# separately after all files are deleted, using find -empty to
# remove only directories that are genuinely empty.
#
# We use return 0 rather than exit 1 when no files are found because
# finding no files is not an error — it is a valid outcome that simply
# means the script has nothing to do for that year.
# -------------------------------------------------------------
find_files() {
    log "INFO" "Searching for files in ${SOURCE_SHARE} modified during ${ARCHIVE_YEAR}..."

    find "${SOURCE_SHARE}" -type f \
        -newermt "${PRIOR_YEAR_ARCHIVE}-12-31" \
        ! -newermt "${NEXT_YEAR_ARCHIVE}-01-01" \
        -print > "${ARCHIVE_MANIFEST}"

    # Count files found without loading them into memory.
    # wc -l counts newlines which equals the number of file paths
    # since find -print outputs one path per line.
    local file_count
    file_count=$(wc -l < "${ARCHIVE_MANIFEST}")

    if [ "${file_count}" -eq 0 ]; then
        log "INFO" "No files found for archive year ${ARCHIVE_YEAR}. Nothing to do."
        # Remove the empty manifest so downstream functions know
        # there is nothing to process by checking for its existence.
        rm -f "${ARCHIVE_MANIFEST}"
        return 0
    fi

    log "INFO" "Found ${file_count} file(s) to archive. Manifest written to ${ARCHIVE_MANIFEST}"
}

# -------------------------------------------------------------
# rsync_to_destination()
# Rsyncs files listed in the manifest to the destination share.
#
# We use --files-from to feed the manifest directly to rsync
# rather than passing file paths as arguments. This avoids the
# shell argument length limit (getconf ARG_MAX) which would be
# exceeded with 1M+ files, and avoids loading all paths into
# memory as a bash array.
#
# The / as source path is required when using --files-from with
# absolute paths in the manifest. Rsync uses it as the root to
# resolve the absolute paths listed in the manifest file.
#
# -a  : Archive mode — preserves permissions, timestamps,
#       symlinks, owner, and group.
# -R  : Relative mode — preserves the full directory structure
#       from the source when writing to the destination. A file
#       at /source/projects/2025/report.txt will be written to
#       /destination/source/projects/2025/report.txt, recreating
#       the entire path automatically. No separate directory
#       handling is needed because of this flag.
# --no-motd : Suppresses the rsync MOTD banner in output.
#
# We build rsync options as an array so we can conditionally
# append --dry-run cleanly without string manipulation.
#
# We use exit 1 rather than return 1 because an rsync failure
# is fatal — there is no point running checksum validation if
# the files were not transferred successfully.
# -------------------------------------------------------------
rsync_to_destination() {
    if [ ! -f "${ARCHIVE_MANIFEST}" ]; then
        log "INFO" "No manifest file found. Skipping rsync."
        return 0
    fi

    local file_count
    file_count=$(wc -l < "${ARCHIVE_MANIFEST}")

    local -a rsync_opts=(-aR --no-motd --files-from="${ARCHIVE_MANIFEST}")

    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "[DRY RUN] Would rsync ${file_count} file(s) to ${DESTINATION_SHARE}"
        rsync_opts+=(--dry-run)
    else
        log "INFO" "Rsyncing ${file_count} file(s) to ${DESTINATION_SHARE}..."
    fi

    if rsync "${rsync_opts[@]}" / "${DESTINATION_SHARE}"; then
        log "INFO" "Rsync completed successfully."
    else
        log "ERROR" "Rsync encountered an error. EXITING..."
        exit 1
    fi
}

# -------------------------------------------------------------
# rsync_cmp()
# Validates the transfer by comparing source and destination files
# via checksum using rsync in dry-run checksum mode.
#
# -R  : Relative mode, preserves full paths for accurate comparison.
# -n  : Dry run — does not actually transfer anything.
# -c  : Forces checksum comparison instead of relying on file
#       size and modification time. More thorough but slower.
# --out-format="%f" : Outputs the full path of files that differ.
#       We use %f rather than %n so that the failed files log
#       contains full paths that can be used directly as input
#       for retry attempts without any additional path resolution.
#
# We collect mismatches into an indexed array (-a) not an
# associative array (-A). An associative array uses key-value
# pairs and cannot be appended to with +=("value") the way
# an indexed array can.
#
# If any files fail validation the full list is written to
# FAILED_FILES_LOG with complete paths so they can be retried
# by retry_failed_files() or investigated manually.
#
# We return 1 rather than exit 1 here because the caller
# (the main block) needs to know validation failed so it can
# decide whether to trigger retry_failed_files(). Exiting
# directly would bypass the retry logic entirely.
# -------------------------------------------------------------
rsync_cmp() {
    local manifest_to_check=$1

    if [ ! -f "${manifest_to_check}" ]; then
        log "INFO" "No manifest file found. Skipping checksum comparison."
        return 0
    fi

    log "INFO" "Comparing files via checksum using manifest: ${manifest_to_check}..."

    local -a mismatched_list=()

    while IFS= read -r mismatched_file; do
        log "WARN" "Checksum mismatch found: ${mismatched_file}"
        mismatched_list+=("${mismatched_file}")
    done < <(rsync -Rnc --no-motd --files-from="${manifest_to_check}" --out-format="%f" / "${DESTINATION_SHARE}" 2>/dev/null)

    if [ ${#mismatched_list[@]} -eq 0 ]; then
        local file_count
        file_count=$(wc -l < "${manifest_to_check}")
        log "INFO" "All ${file_count} file(s) validated successfully via checksum."
        return 0
    else
        # Write the full paths of failed files to the failed files log.
        # printf is used instead of echo because it handles filenames
        # with special characters more reliably than echo.
        # This file is used directly as the manifest for retry attempts.
        printf '%s\n' "${mismatched_list[@]}" > "${FAILED_FILES_LOG}"
        log "WARN" "${#mismatched_list[@]} file(s) failed checksum validation. See ${FAILED_FILES_LOG}"
        return 1
    fi
}

# -------------------------------------------------------------
# retry_failed_files()
# Attempts to re-rsync and re-validate files that failed checksum
# validation. Uses FAILED_FILES_LOG as the manifest since it
# contains the full paths of only the failed files.
#
# Each attempt:
#   1. Re-rsyncs only the currently failing files
#   2. Re-validates them via checksum
#   3. Updates FAILED_FILES_LOG to reflect only files still failing
#
# This means each retry pass only targets files that are genuinely
# still failing, not the full original set.
#
# MAX_RETRIES limits the number of attempts to avoid infinite loops
# in cases where files are genuinely corrupt or permanently
# inaccessible on the source or destination share.
#
# If all files pass within the retry limit, FAILED_FILES_LOG is
# removed and the function returns 0 so the main block can proceed
# to deletion safely.
#
# If files are still failing after all retries, notify_failure()
# is called to alert the administrator, and we exit 1 to ensure
# source files are never deleted with unvalidated transfers.
#
# -aR and / as source are used for the same reasons as
# rsync_to_destination — preserves directory structure and
# resolves absolute paths from the manifest correctly.
# -------------------------------------------------------------
retry_failed_files() {
    local attempt=0

    while [ "${attempt}" -lt "${MAX_RETRIES}" ]; do
        (( attempt++ )) || true

        local retry_count
        retry_count=$(wc -l < "${FAILED_FILES_LOG}")
        log "INFO" "Retry attempt ${attempt}/${MAX_RETRIES} for ${retry_count} failed file(s)..."

        # Re-rsync only the currently failing files.
        # -aR preserves the full directory structure for each
        # retried file just as it did in the original transfer.
        if rsync -aR --no-motd --files-from="${FAILED_FILES_LOG}" / "${DESTINATION_SHARE}"; then
            log "INFO" "Re-rsync of failed files completed on attempt ${attempt}."
        else
            log "WARN" "Re-rsync encountered errors on attempt ${attempt}. Will retry validation anyway."
        fi

        # Re-validate using the failed files log as the manifest.
        # rsync_cmp updates FAILED_FILES_LOG with only the files
        # still failing, so each subsequent retry targets a smaller
        # and smaller set of files.
        if rsync_cmp "${FAILED_FILES_LOG}"; then
            log "INFO" "All previously failed file(s) passed validation on attempt ${attempt}."
            # Remove the failed files log since everything passed.
            # Its absence signals to the main block that it is safe
            # to proceed to deletion.
            rm -f "${FAILED_FILES_LOG}"
            return 0
        fi

        log "WARN" "$(wc -l < "${FAILED_FILES_LOG}") file(s) still failing after attempt ${attempt}."
    done

    # All retry attempts exhausted. Alert and exit without deleting
    # anything from source to protect data integrity.
    local failed_count
    failed_count=$(wc -l < "${FAILED_FILES_LOG}")

    log "ERROR" "${failed_count} file(s) still failing after ${MAX_RETRIES} attempts. Manual intervention required. See ${FAILED_FILES_LOG}"

    notify_failure \
        "Archive ${ARCHIVE_YEAR} - Checksum Failures After ${MAX_RETRIES} Retries" \
        "Archive script on $(hostname) failed checksum validation for ${failed_count} file(s) after ${MAX_RETRIES} retry attempts.

Failed files are listed in: ${FAILED_FILES_LOG}
Archive log: ${ARCHIVE_LOG_FILE}
Stderr log: ${STDERR_LOG_FILE}

No source files have been deleted. Manual intervention is required."

    exit 1
}

# -------------------------------------------------------------
# delete_source_files()
# Deletes files from the source share that have been successfully
# archived and validated against the destination via checksum.
#
# This function is only called after rsync_cmp() and any retries
# confirm all files passed checksum validation. This is the
# critical safety gate — deleting before full validation would
# risk permanent data loss.
#
# We read directly from the manifest file line by line to avoid
# loading 1M+ paths into memory as a bash array.
#
# IFS= prevents leading/trailing whitespace from being stripped
# from file paths. -r prevents backslash interpretation in paths.
#
# Each successfully deleted file is written to DELETED_FILES_LOG
# immediately as it is deleted rather than batching at the end.
# This provides a real-time audit trail so that if the script is
# interrupted mid-deletion, the log reflects exactly which files
# were actually removed.
#
# (( counter++ )) || true is used instead of plain (( counter++ ))
# because the (( )) construct returns exit code 1 when the result
# is zero, which would trigger set -e and kill the script on the
# first file. The || true prevents that.
#
# After all files are deleted, empty directories are removed from
# the source share. We sort in reverse so deepest directories are
# processed first, allowing parent directories to become empty
# and be removed in the same pass. -mindepth 1 protects the source
# share root itself from ever being removed. -empty ensures we
# only remove directories that contain no remaining files, so
# directories shared with files from other years are never touched.
#
# We use exit 1 rather than return 1 because deletion failures
# leave the source in an inconsistent state that requires immediate
# investigation.
# -------------------------------------------------------------
delete_source_files() {
    if [ ! -f "${ARCHIVE_MANIFEST}" ]; then
        log "INFO" "No manifest file found. Skipping source deletion."
        return 0
    fi

    local file_count
    file_count=$(wc -l < "${ARCHIVE_MANIFEST}")

    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "[DRY RUN] Would delete ${file_count} file(s) from ${SOURCE_SHARE}"
        log "INFO" "[DRY RUN] Would remove empty directories from ${SOURCE_SHARE}"
        return 0
    fi

    log "INFO" "Starting deletion of ${file_count} file(s) from source share ${SOURCE_SHARE}..."

    local deleted_count=0
    local failed_count=0
    local -a failed_deletions=()

    while IFS= read -r file; do
        if rm -f "${file}" 2>/dev/null; then
            # Write each deleted file immediately for real-time audit trail.
            echo "${file}" >> "${DELETED_FILES_LOG}"
            (( deleted_count++ )) || true
        else
            log "WARN" "Failed to delete: ${file}"
            failed_deletions+=("${file}")
            (( failed_count++ )) || true
        fi
    done < "${ARCHIVE_MANIFEST}"

    log "INFO" "File deletion complete. Successfully deleted ${deleted_count} file(s)."
    log "INFO" "Deletion audit log written to ${DELETED_FILES_LOG}"

    # Report any files that could not be deleted before attempting
    # directory cleanup, so the log clearly separates file deletion
    # failures from directory cleanup activity.
    if [ "${failed_count}" -gt 0 ]; then
        printf '%s\n' "${failed_deletions[@]}" >> "${FAILED_FILES_LOG}"
        log "ERROR" "${failed_count} file(s) could not be deleted from source. See ${FAILED_FILES_LOG}"
        exit 1
    fi

    # -------------------------------------------------------------
    # Remove empty directories from the source share.
    # We do this after all file deletions are confirmed successful
    # so we never remove a directory while it may still have files
    # being processed.
    #
    # find -empty only matches directories that are genuinely empty.
    # Directories that still contain files from other years or other
    # archive runs are never touched.
    #
    # sort -r processes deepest paths first so child directories are
    # removed before their parents, allowing parents to become empty
    # and be cleaned up in the same pass without needing multiple runs.
    #
    # -mindepth 1 ensures the source share root directory itself is
    # never considered for removal regardless of its contents.
    #
    # rmdir is used instead of rm -rf as an additional safety measure.
    # rmdir will only remove a directory if it is completely empty and
    # will fail silently on non-empty directories, preventing any risk
    # of accidentally removing directories that still have content.
    # -------------------------------------------------------------
    log "INFO" "Removing empty directories from ${SOURCE_SHARE}..."

    local dir_count=0
    while IFS= read -r empty_dir; do
        if rmdir "${empty_dir}" 2>/dev/null; then
            log "INFO" "Removed empty directory: ${empty_dir}"
            (( dir_count++ )) || true
        else
            # Not treated as a fatal error. A directory that cannot
            # be removed is not ideal but does not affect the integrity
            # of the archive. We log it as a warning for investigation.
            log "WARN" "Could not remove directory: ${empty_dir}"
        fi
    done < <(find "${SOURCE_SHARE}" -mindepth 1 -type d -empty | sort -r)

    log "INFO" "Directory cleanup complete. Removed ${dir_count} empty directory(s)."
    log "INFO" "All source files and empty directories cleaned up successfully."
}

# ============================================================
# MAIN
# Register the cleanup function to run on EXIT so it is always
# called whether the script finishes normally, hits an exit 1,
# or is terminated by a signal. This guarantees the lock file
# and file descriptor are always cleaned up regardless of how
# the script ends.
# ============================================================
trap cleanup EXIT

log "INFO" "====== Archive Script Started: ${0} ======"
log "INFO" "Archive year  : ${ARCHIVE_YEAR}"
log "INFO" "Source        : ${SOURCE_SHARE}"
log "INFO" "Destination   : ${DESTINATION_SHARE}"
log "INFO" "Manifest      : ${ARCHIVE_MANIFEST}"
log "INFO" "Log file      : ${ARCHIVE_LOG_FILE}"
log "INFO" "Stderr log    : ${STDERR_LOG_FILE}"
log "INFO" "Deleted files : ${DELETED_FILES_LOG}"
log "INFO" "Max retries   : ${MAX_RETRIES}"
log "INFO" "Alert email   : ${ALERT_EMAIL}"
[[ "${DRY_RUN}" == true ]] && log "INFO" "DRY RUN MODE ENABLED - no files will be moved or deleted"

# Run preflight checks. Each function handles its own logging
# and calls exit 1 internally on failure so we do not need
# || exit 1 here. Keeping the main block clean makes it easy
# to read the overall flow of the script at a glance.
verify_nfs_shares
verify_write_permissions
find_files

# Only proceed if the manifest exists. find_files() removes the
# manifest if no files were found so checking for its existence
# is a reliable gate for whether there is anything to process.
#
# The critical safety chain is:
#   1. rsync_to_destination - copy files preserving directory structure
#   2. rsync_cmp            - validate every file via checksum
#   3. retry_failed_files   - retry any failures up to MAX_RETRIES times
#   4. delete_source_files  - delete files and clean empty directories
#
# Source files are never deleted unless the entire file set passes
# checksum validation, either on the first attempt or after retries.
# If retries are exhausted, notify_failure() alerts the administrator
# and the script exits without touching the source.
if [ -f "${ARCHIVE_MANIFEST}" ]; then
    rsync_to_destination

    # rsync_cmp returns 1 if any files fail validation and writes
    # them to FAILED_FILES_LOG. We check its return code explicitly
    # rather than letting set -e handle it so we can trigger retries
    # before deciding whether to exit.
    if ! rsync_cmp "${ARCHIVE_MANIFEST}"; then
        retry_failed_files
    fi

    delete_source_files
fi

log "INFO" "====== Archive Script Completed Successfully ======"

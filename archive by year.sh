#!/usr/bin/env bash
#==============================================================================
# archive_by_year.sh
#
# Archives files from an NFS source share to an NFS destination share, by
# modification year. Workflow:
#   1. Find all files on SOURCE_SHARE last modified during ARCHIVE_YEAR and
#      write them to a manifest file.
#   2. Rsync the manifest to DESTINATION_SHARE/ARCHIVE_YEAR/.
#   3. Validate every copied file via rsync checksum comparison; retry any
#      failures up to MAX_RETRIES times.
#   4. Optionally (DELETE_SOURCE=true) delete the source copies, but only if
#      validation fully passed.
#
# Usage:
#   ARCHIVE_YEAR=2021 \
#   SOURCE_SHARE=/mnt/nfs/source \
#   DESTINATION_SHARE=/mnt/nfs/archive \
#   [DRY_RUN=true|false] [DELETE_SOURCE=true|false] \
#   ./archive_by_year.sh
#
# DRY_RUN and DELETE_SOURCE are mutually exclusive. Both default to false.
#==============================================================================

# Exit on errors, undefined variables and pipe failures
set -euo pipefail

#------------------------------------------------------------------------------
# Declare all the global variables
#------------------------------------------------------------------------------

# Required inputs. The "${VAR:?message}" form means: expand VAR, but if it is
# unset OR empty, print "message" to stderr and exit immediately. It is the
# one-line way to make a variable mandatory — no manual "if missing" checks.
ARCHIVE_YEAR="${ARCHIVE_YEAR:?ERROR: ARCHIVE_YEAR must be provided via command line}"
SOURCE_SHARE="${SOURCE_SHARE:?ERROR: SOURCE_SHARE must be provided via command line}"
DESTINATION_SHARE="${DESTINATION_SHARE:?ERROR: DESTINATION_SHARE must be provided via command line}"

# Optional inputs. The "${VAR:-default}" form is the mirror image: expand VAR,
# but if it is unset OR empty, use "default" instead. So these default to false
# unless the caller explicitly passes true.
#   DRY_RUN: report how many files WOULD be moved, change nothing.
#   DELETE_SOURCE: delete source files after copy AND successful validation.
# (The two are mutually exclusive; that is enforced in main, below.)
DELETE_SOURCE="${DELETE_SOURCE:-false}"  # Defaults safely to false if omitted
DRY_RUN="${DRY_RUN:-false}"              # Set true to see how many files would move

# Defining other variables needed
SCRIPT_NAME="${0##*/}"   # "${0##*/}" strips the longest leading */ from the
                         # invocation path, leaving just the script's basename.
RUN_ID="$(date +'%Y%m%d_%H%M%S')_$$"   # timestamp + $$ (this shell's PID) =
                                       # a value unique to THIS run, used to
                                       # tag log lines and name temp files.
LOG_DIRECTORY="/home/sk901741/local_development/shell_scripts/work_in_progess"
LOG_FILE='archive.log'
ARCHIVE_LOG_FILE="${LOG_DIRECTORY}/${LOG_FILE}"

# RUN_ID already contains a timestamp + PID, so these names are unique per run.
# The error file is only created when rsync actually runs — no mktemp at parse
# time, so dry runs and aborted instances leave nothing behind.
RSYNC_ERR_FILE="${LOG_DIRECTORY}/RSYNC_ERR.${RUN_ID}"
FAILED_FILES_LIST="${LOG_DIRECTORY}/FAILED_FILES_LIST_${ARCHIVE_YEAR}"
FAILED_DELETES_LIST="${LOG_DIRECTORY}/FAILED_DELETES_${ARCHIVE_YEAR}"
LOCK_FILE="${LOG_DIRECTORY}/archive.LCK"
PRIOR_YEAR_ARCHIVE=$((ARCHIVE_YEAR - 1))

# Manifest is anchored to LOG_DIRECTORY so the script behaves the same no
# matter what directory it is launched from (cron runs from $HOME).
ARCHIVE_MANIFEST="${LOG_DIRECTORY}/${ARCHIVE_YEAR}_manifest"

MAX_RETRIES=4      # Maximum number of retry attempts when checksums differ
MAX_LOG_LINES=50000  # Trim archive.log to this many lines at startup (~10MB max)

#------------------------------------------------------------------------------
# Function Declarations
#------------------------------------------------------------------------------

# Write logs into the archive log file. The 'level' argument sets the priority
# of the log entry. Every line carries RUN_ID, so a single run can be
# reconstructed from the shared log with:  grep "<run_id>" archive.log
# e.g.:  log "INFO" "This is just a test log entry"
log() {
        local level=$1
        local message=$2
        local timestamp
        timestamp=$(date +'%Y-%m-%d %H:%M:%S')
        echo "[${timestamp}] [${RUN_ID}] [${level}] ${message}" >>"${ARCHIVE_LOG_FILE}"
}

# Prepare the shared log file at startup:
#   1. Ensure the log directory exists — without this, the first log call
#      fails its redirect and set -e kills the script with no message at all.
#   2. Trim the log to its newest MAX_LOG_LINES so it can't grow forever.
#   3. Write a visual separator so each run is easy to spot when scrolling.
init_log() {
        mkdir -p "${LOG_DIRECTORY}"

        # Keep only the newest MAX_LOG_LINES (no-op while the file is small)
        if [[ -f "${ARCHIVE_LOG_FILE}" ]]; then
                local line_count
                line_count=$(wc -l <"${ARCHIVE_LOG_FILE}")
                if [[ "${line_count}" -gt "${MAX_LOG_LINES}" ]]; then
                        tail -n "${MAX_LOG_LINES}" "${ARCHIVE_LOG_FILE}" >"${ARCHIVE_LOG_FILE}.tmp"
                        mv "${ARCHIVE_LOG_FILE}.tmp" "${ARCHIVE_LOG_FILE}"
                fi
        fi

        # Visual separator between runs
        {
                echo ""
                echo "#==============================================================================="
                echo "# NEW RUN ${RUN_ID} — $(date +'%Y-%m-%d %H:%M:%S') — ${SCRIPT_NAME}"
                echo "#==============================================================================="
        } >>"${ARCHIVE_LOG_FILE}"
}

# Count entries in a given file with wc. Echoes 0 for a missing file so it is
# always safe to use in arithmetic comparisons.
count_manifest_files() {
        local manifest="${1}"
        if [[ ! -f "${manifest}" ]]; then
                echo 0
                return 0
        fi
        wc -l <"${manifest}"
}

# Locate files modified during a specific archive year.
# Outputs results to a manifest file, logs the count, and deletes empty
# manifests.
#
# WHY WE DEFINE TIME EXPLICITLY:
# The '-newermt' flag defaults to 00:00:00 (midnight) if only a date is
# provided, which includes files modified on that exact day.
#
# By explicitly setting both dates to 23:59:59, we ensure:
#   1. The start date covers files modified AFTER 23:59:59 of the prior year.
#   2. The end date cuts off precisely at 23:59:59 of the archive year.
find_files() {
        # THE FIND COMMAND, explained:
        #   -type f                    only regular files (not dirs/symlinks)
        #   -newermt "<date> 23:59:59" match files modified STRICTLY AFTER this
        #                              timestamp. Anchored to the last second of
        #                              the prior year, so the window opens at the
        #                              very start of the archive year.
        #   ! -newermt "<date> ..."    the leading '!' negates the next test, so
        #                              this means "NOT newer than the end of the
        #                              archive year" = modified on or before it.
        #                              The two together form a closed window:
        #                              prior-year-end  <  file mtime  <=  year-end.
        #   -printf '%P\n'             print each path RELATIVE to SOURCE_SHARE
        #                              (%P strips the search-root prefix), one per
        #                              line. Relative paths are exactly what
        #                              rsync --files-from and the later deletes
        #                              expect, so the manifest is reusable as-is.
        #
        # If find hits an unreadable subdirectory it exits non-zero; without
        # the guard, set -e would kill the script with nothing in the log.
        if ! find "${SOURCE_SHARE}" -type f \
                -newermt "${PRIOR_YEAR_ARCHIVE}-12-31 23:59:59" \
                ! -newermt "${ARCHIVE_YEAR}-12-31 23:59:59" \
                -printf '%P\n' >"${ARCHIVE_MANIFEST}"; then
                log "ERROR" "find reported errors scanning ${SOURCE_SHARE} (permissions?). Manifest may be incomplete. Exiting."
                rm -f "${ARCHIVE_MANIFEST}"
                exit 1
        fi

        local file_count
        file_count=$(count_manifest_files "${ARCHIVE_MANIFEST}")
        if [[ ${file_count} -eq 0 ]]; then
                log "INFO" "No archive files found for archive year ${ARCHIVE_YEAR}"
                rm -f "${ARCHIVE_MANIFEST}"
                return 0
        fi

        log "INFO" "Found ${file_count} files to archive for year ${ARCHIVE_YEAR}"
        log "INFO" "Manifest written to ${ARCHIVE_MANIFEST}"
}

# Transfer archived files to the destination share.
# Validates the manifest, ensures the destination path exists, and executes
# rsync.
rsync_to_destination() {
        # Verify the manifest exists before proceeding
        if [[ ! -f "${ARCHIVE_MANIFEST}" ]]; then
                log "INFO" "No files to move to the destination share. Skipping Rsync"
                return 0
        fi

        # Ensure the target archive directory exists
        if [[ ! -d "${DESTINATION_SHARE}/${ARCHIVE_YEAR}" ]]; then
                log "INFO" "Destination directory for year ${ARCHIVE_YEAR} doesn't exist yet. Creating it now"
                mkdir -p "${DESTINATION_SHARE}/${ARCHIVE_YEAR}"
        fi

        # Retrieve total file count for final confirmation log
        local file_count
        file_count=$(count_manifest_files "${ARCHIVE_MANIFEST}")

        # Configure Rsync options
        # 1. -a to preserve all the file attributes from source to destination
        # 2. --no-motd suppresses MOTD from the destination host
        # 3. --files-from transfers the specific list of files read from the
        #    manifest file
        local -a rsync_opts=(
                -a
                --no-motd
                --files-from="${ARCHIVE_MANIFEST}"
        )

        # Execute file transfer and evaluate outcome.
        #
        # The two paths matter:
        #   "${SOURCE_SHARE}/"  trailing slash = "copy the CONTENTS of this
        #                       directory", not the directory itself. Combined
        #                       with --files-from, rsync recreates each manifest
        #                       path under the destination root.
        #   destination/year/   files land in a per-year subdirectory.
        #
        # Redirections:
        #   >/dev/null          discard normal progress output (not useful here)
        #   2>"${RSYNC_ERR_FILE}"  capture only stderr, so if rsync fails we
        #                       have the real error text to log and inspect.
        # Unlike the validation step, this is a REAL copy, so a non-zero exit
        # is a genuine failure: we log FATAL and stop before anything downstream
        # (validation, deletion) can act on an incomplete transfer.
        if rsync "${rsync_opts[@]}" "${SOURCE_SHARE}/" "${DESTINATION_SHARE}/${ARCHIVE_YEAR}/" >/dev/null 2>"${RSYNC_ERR_FILE}"; then
                log "INFO" "${file_count} files have been copied over successfully"

                # rsync wrote nothing to stderr (-s = "file exists and is
                # non-empty"; here we delete when it IS empty), so there is no
                # error file worth keeping.
                if [[ ! -s "${RSYNC_ERR_FILE}" ]]; then
                        rm -f "${RSYNC_ERR_FILE}"
                fi
                return 0
        else
                log "FATAL" "Rsync Failed. See ${RSYNC_ERR_FILE}. Exiting Now"
                exit 1
        fi
}

# Compare files between source and destination using checksums.
# Identifies mismatched files and records any failures to a tracking list.
#
# Accepts an optional manifest argument:
#   rsync_cmp                          -> validates the full ARCHIVE_MANIFEST
#   rsync_cmp "${FAILED_FILES_LIST}"   -> re-validates only the failed files
rsync_cmp() {
        local manifest="${1:-${ARCHIVE_MANIFEST}}"

        # Declare a local array to safely hold the failures
        local -a mismatched_list=()
        log "INFO" "Checking to see if we have a manifest file for the move"

        # Check if the manifest file exists
        if [[ ! -f "${manifest}" ]]; then
                log "INFO" "No manifest file found. Skipping Rsync Compare"
                return 0
        fi

        log "INFO" "Manifest File ${manifest} found. Comparing the moved files via checksum..."
        local cmp_output
        cmp_output="$(mktemp "${LOG_DIRECTORY}/cmp_output_file.${RUN_ID}.XXXX")"

        # Execute a dry-run checksum comparison and capture what rsync says
        # WOULD need re-copying. We are not transferring anything here — only
        # asking rsync to compare source vs destination by content.
        #
        # How this works, flag by flag:
        #   -a              archive mode (recursive + preserve perms, times,
        #                   symlinks, etc). Here it mainly sets the same
        #                   comparison basis used during the real copy.
        #   -n              --dry-run: report what would change, change nothing.
        #   -c              --checksum: decide "same or different" by computing
        #                   a checksum of every file's CONTENTS on both sides,
        #                   instead of the default quick check (size + mtime).
        #                   This is the whole point — it catches a file that
        #                   copied to the right size but with corrupted bytes.
        #                   It is also why this step is slow: it reads every
        #                   byte on both source and destination.
        #   --no-motd       suppress the server's message-of-the-day banner so
        #                   it can't contaminate the output we parse.
        #   --files-from    restrict the comparison to exactly the paths in the
        #                   manifest, rather than walking the entire tree.
        #   --out-format='%n'  print ONLY the name (%n) of each item rsync
        #                   thinks differs, one per line — no stats, no extra
        #                   columns. That makes the output a clean list we can
        #                   read straight into an array. (Directories whose
        #                   metadata differs also appear, ending in '/'; the
        #                   read loop below filters those out.)
        #   "${SOURCE_SHARE}/"  trailing slash means "the CONTENTS of this dir"
        #                   so paths line up with the destination correctly.
        #
        # An EMPTY output means every compared file matched by checksum — a
        # perfect copy. Any lines mean those files differ and need a retry.
        #
        # NOTE: rsync exits 0 even when files DIFFER — a difference is a normal
        # dry-run result, not an error. It only returns non-zero on an actual
        # failure (network drop, bad path, permissions), so 'if !' here means
        # "rsync itself broke", which is fatal and we exit.
        if ! rsync -anc --no-motd --files-from="${manifest}" --out-format='%n' \
                "${SOURCE_SHARE}/" "${DESTINATION_SHARE}/${ARCHIVE_YEAR}/" >"${cmp_output}"; then
                log "ERROR" "Rsync Checksum Validation Failed, Exiting Now"
                rm -f "${cmp_output}"
                exit 1
        fi

        # Read comparison output into an array if the file is not empty (-s)
        if [[ -s "${cmp_output}" ]]; then
                # Read rsync output line by line. Skip directories (entries
                # ending in '/') and blank lines — rsync also lists dirs whose
                # attributes changed, and those are not checksum failures.
                local mismatched_file
                while IFS= read -r mismatched_file; do
                        [[ -z "${mismatched_file}" ]] && continue
                        [[ "${mismatched_file}" == */ ]] && continue
                        mismatched_list+=("${mismatched_file}")
                done <"${cmp_output}"
        fi

        # Make sure we remove the cmp_output file
        rm -f "${cmp_output}"

        # Evaluate the results
        if [[ "${#mismatched_list[@]}" -eq 0 ]]; then
                log "INFO" "All Files Validated perfectly via checksum!"
                return 0
        else
                printf '%s\n' "${mismatched_list[@]}" >"${FAILED_FILES_LIST}"
                log "ERROR" "${#mismatched_list[@]} file(s) failed validation."
                return 1
        fi
}

# Automatically retry copying any files that failed checksum validation.
# Loops up to MAX_RETRIES times and re-runs validation after each attempt.
retry_failed_files() {
        local attempt=0
        while [[ "${attempt}" -lt "${MAX_RETRIES}" ]]; do
                ((attempt++)) || true

                local retry_count
                retry_count=$(count_manifest_files "${FAILED_FILES_LIST}")
                log "INFO" "Retry attempt ${attempt}/${MAX_RETRIES} for ${retry_count} failed file(s)..."

                if rsync -a --no-motd --files-from="${FAILED_FILES_LIST}" \
                        "${SOURCE_SHARE}/" "${DESTINATION_SHARE}/${ARCHIVE_YEAR}/"; then
                        log "INFO" "Re-sync of failed files completed on attempt ${attempt}"
                else
                        log "WARN" "Re-sync encountered errors on attempt ${attempt}. Will retry validation anyway."
                fi

                # Only re-validate the files that failed, not the whole manifest
                if rsync_cmp "${FAILED_FILES_LIST}"; then
                        log "INFO" "All previously failed file(s) passed validation on attempt: ${attempt}"
                        rm -f "${FAILED_FILES_LIST}"
                        return 0
                fi

                log "WARN" "$(count_manifest_files "${FAILED_FILES_LIST}") file(s) still failing after attempt ${attempt}."
        done

        local failed_count
        failed_count=$(count_manifest_files "${FAILED_FILES_LIST}")
        log "ERROR" "${failed_count} file(s) still failing after ${MAX_RETRIES} attempts. Manual intervention required. See ${FAILED_FILES_LIST}. No source files have been deleted"
        return 1
}

# Remove directories left empty after a successful source deletion.
# Cosmetic and best-effort: this NEVER fails the run (always returns 0),
# because the archive itself has already fully succeeded by the time it
# runs. It stays fully visible: it logs HOW MANY directories it pruned,
# writes the exact list to a file for the record, and on trouble logs a
# WARN with the error detail — so neither a silent prune nor a silent
# failure can happen.
#
#   -mindepth 1 : never consider SOURCE_SHARE itself, only its contents,
#                 so the share root (an NFS mountpoint!) is never deleted.
#   -print      : print each directory as it is removed, so we know exactly
#                 what was pruned (find -delete is otherwise silent).
#   -delete     : implies depth-first traversal, so a child is removed
#                 before its parent is tested — nested empty chains (a dir
#                 containing only empty subdirs) collapse in one pass, and
#                 -print emits them child-first in that same order.
# Directories still holding files from other years are left untouched.
#
# stdout (the pruned list) and stderr (any errors) are captured separately
# so error text never contaminates the list of removed directories.
prune_empty_source_dirs() {
        local pruned_list pruned_dirs="${LOG_DIRECTORY}/PRUNED_DIRS_${ARCHIVE_YEAR}"
        local prune_err="${LOG_DIRECTORY}/PRUNE_ERRORS_${ARCHIVE_YEAR}"

        if pruned_list=$(find "${SOURCE_SHARE}" -mindepth 1 -type d -empty -print -delete 2>"${prune_err}"); then
                rm -f "${prune_err}"   # no errors -> drop the empty error file
                local count=0
                if [[ -n "${pruned_list}" ]]; then
                        printf '%s\n' "${pruned_list}" >"${pruned_dirs}"
                        count=$(printf '%s\n' "${pruned_list}" | grep -c .)
                        log "INFO" "Pruned ${count} empty directory(ies) under ${SOURCE_SHARE}. List: ${pruned_dirs}"
                else
                        rm -f "${pruned_dirs}"   # nothing pruned -> no stale list
                        log "INFO" "No empty directories to prune under ${SOURCE_SHARE}"
                fi
        else
                # find hit an error. It may still have pruned some dirs before
                # failing, so record whatever it managed to print.
                if [[ -n "${pruned_list}" ]]; then
                        printf '%s\n' "${pruned_list}" >"${pruned_dirs}"
                fi
                log "WARN" "Empty-directory prune had errors; some empty dirs may remain under ${SOURCE_SHARE}. Archive itself succeeded. Errors: ${prune_err}"
        fi
        return 0   # cosmetic cleanup never fails the run
}

# Delete the source copies of every file in the manifest. Only ever called
# after validation fully passed AND DELETE_SOURCE=true, so every file in the
# manifest is known to exist at the destination with a matching checksum.
#
# Deletion is batched with xargs (thousands of files per rm invocation)
# rather than one rm per file — essential over NFS at large file counts.
# Because batching loses per-file error reporting, we verify afterward:
# any manifest entry still present on disk is recorded in
# FAILED_DELETES_LIST (separate from FAILED_FILES_LIST, which tracks
# checksum failures — different problem, different remediation).
#
# After a clean delete, empty directories are pruned via
# prune_empty_source_dirs (called only in the zero-survivors branch).
delete_source_files() {
        local file_count
        file_count=$(count_manifest_files "${ARCHIVE_MANIFEST}")
        log "INFO" "Validation passed and DELETE_SOURCE=true. Deleting ${file_count} source file(s) from ${SOURCE_SHARE}"

        # Batched delete, run from inside SOURCE_SHARE so the manifest's
        # relative paths resolve directly. Note: files already gone (deleted
        # by users during the long copy/validate window) are NOT an error —
        # 'rm -f' silently tolerates missing operands. The '|| true' is for
        # REAL failures (permission denied, stale NFS handle, I/O error):
        # rm exits non-zero, xargs propagates it as 123, and set -e would
        # kill the script here — before the survivor check below, which is
        # the step designed to judge and report partial failures properly.
        (cd "${SOURCE_SHARE}" && xargs -d '\n' -r rm -f -- ) <"${ARCHIVE_MANIFEST}" || true

        # Post-verification, batched like the delete itself. We need to know
        # which manifest files (if any) are STILL on disk after the delete —
        # those are real failures. Done as a set intersection:
        #
        #   left  = the manifest, sorted (everything we tried to delete)
        #   right = of those same paths, the ones that still exist. 'ls -d'
        #           via xargs prints a path only if it exists; 2>/dev/null
        #           throws away "No such file" noise for the ones we deleted.
        #   comm -12 = print only lines common to BOTH sorted inputs, i.e.
        #              (tried to delete) AND (still exists) = survivors.
        # comm requires both inputs sorted, hence the matching 'sort' on each.
        # Survivors land in FAILED_DELETES_LIST, itself a valid manifest you
        # can feed straight back to rm after fixing the cause.
        comm -12 \
                <(sort "${ARCHIVE_MANIFEST}") \
                <(cd "${SOURCE_SHARE}" && sort "${ARCHIVE_MANIFEST}" | xargs -d '\n' -r ls -d -- 2>/dev/null | sort) \
                >"${FAILED_DELETES_LIST}"

        local failed_deletes
        failed_deletes=$(wc -l <"${FAILED_DELETES_LIST}")

        if [[ "${failed_deletes}" -eq 0 ]]; then
                rm -f "${FAILED_DELETES_LIST}"
                log "INFO" "All ${file_count} source file(s) deleted successfully"
                prune_empty_source_dirs
                return 0
        else
                log "ERROR" "${failed_deletes} file(s) could not be deleted from the source share. Manual intervention required. See ${FAILED_DELETES_LIST}"
                return 1
        fi
}

# Cleanup function to remove the lock file and close FD 9 when the script
# finishes for any reason (normal exit, error, or signal).
cleanup() {
        if [[ -f "${LOCK_FILE}" ]]; then
                rm -f "${LOCK_FILE}"
        fi
        # Cleanup the file descriptor 9 when the script finishes
        exec 9>&- || true
}

# Check if the script can write to both source and destination directories.
verify_write_permissions() {
        local source_test_file="${SOURCE_SHARE}/source_testfile.txt"
        local dest_test_file="${DESTINATION_SHARE}/dest_testfile.txt"

        if touch "${source_test_file}" 2>/dev/null; then
                rm -f "${source_test_file}"
                log "INFO" "Script has permissions to write on the source share: ${SOURCE_SHARE}"
        else
                log "FATAL" "Script doesn't have the write permissions on the source share ${SOURCE_SHARE}. EXITING..."
                return 1
        fi

        if touch "${dest_test_file}" 2>/dev/null; then
                rm -f "${dest_test_file}"
                log "INFO" "Script has permissions to write on the destination share: ${DESTINATION_SHARE}"
        else
                log "FATAL" "Script doesn't have the write permissions on the destination share ${DESTINATION_SHARE}. EXITING..."
                return 1
        fi
}

# Check that both shares actually exist as directories before anything else
# touches them. This MUST run before verify_nfs_shares and
# verify_write_permissions, because those call stat/touch on the paths — if a
# path is a typo or an unmounted mountpoint, we want a clear "doesn't exist"
# message here rather than a confusing stat error or, worse, silent work
# against the wrong location.
#
# '-d' tests "exists AND is a directory", which also rejects the case where
# the path exists but is a plain file.
verify_shares_exist() {
        if [[ ! -d "${SOURCE_SHARE}" ]]; then
                log "FATAL" "Source Share ${SOURCE_SHARE} does not exist or is not a directory. EXITING..."
                return 1
        fi
        log "INFO" "Source Share ${SOURCE_SHARE} exists"

        if [[ ! -d "${DESTINATION_SHARE}" ]]; then
                log "FATAL" "Destination Share ${DESTINATION_SHARE} does not exist or is not a directory. EXITING..."
                return 1
        fi
        log "INFO" "Destination Share ${DESTINATION_SHARE} exists"
}

# Check if source and destination shares are both NFS. If they are not NFS
# shares, exit the script.
#
# 'stat -f' reports the FILESYSTEM (not the file), and '-c %T' prints that
# filesystem's type in human-readable form — "nfs" for an NFS mount, "ext2/ext3"
# for local disk, "tmpfs", etc. So this catches the dangerous mistake of
# pointing the script at a LOCAL path (e.g. an unmounted share that silently
# fell back to the underlying mountpoint directory), where archiving and then
# deleting could destroy data that was never really on the network share.
verify_nfs_shares() {
        if [[ $(stat -f -c %T "${SOURCE_SHARE}") == "nfs" ]]; then
                log "INFO" "Source Share ${SOURCE_SHARE} is a NFS mount"
        else
                log "FATAL" "Source Share ${SOURCE_SHARE} isn't a NFS mount. EXITING..."
                return 1
        fi

        if [[ $(stat -f -c %T "${DESTINATION_SHARE}") == "nfs" ]]; then
                log "INFO" "Destination Share ${DESTINATION_SHARE} is a NFS mount"
        else
                log "FATAL" "Destination Share ${DESTINATION_SHARE} isn't a NFS mount. EXITING..."
                return 1
        fi
}

#------------------------------------------------------------------------------
# Main Script Execution
#------------------------------------------------------------------------------

# Prepare the log: ensure the directory exists, trim old lines, write the
# run separator. Must happen before anything that might call log().
init_log

# Acquire a single-instance lock so two copies of this script can never run
# at once (e.g. a cron run that overruns into the next scheduled run).
#
# How this works:
#   exec 9>"${LOCK_FILE}"  opens the lock file and ties it to file descriptor
#                          9 for the rest of the script's life. The file's
#                          mere existence is NOT the lock — the kernel-level
#                          advisory lock on this open FD is.
#   flock -n 9             tries to grab an exclusive lock on FD 9. '-n' =
#                          non-blocking: if another process already holds it,
#                          fail immediately instead of waiting.
#   || { ... }            on failure, log and exit — another instance is live.
#
# The lock auto-releases when the script ends for ANY reason (normal exit,
# error, kill), because the kernel drops it when FD 9 closes with the process.
# That makes it crash-safe: a killed run can't leave a stuck lock behind.
exec 9>"${LOCK_FILE}"
flock -n 9 || {
        log "FATAL" "Another instance of this script is currently running. Aborting now..."
        exit 1
}

# Run cleanup() on EXIT (any exit path) to remove the lock file and close FD 9.
trap cleanup EXIT

# Write down the values that we are running with into the log file
log "INFO" "Running script ${SCRIPT_NAME} (DELETE_SOURCE=${DELETE_SOURCE}) (DRY_RUN=${DRY_RUN}) with Run ID of ${RUN_ID}"
log "INFO" "Target Year:        ${ARCHIVE_YEAR}"
log "INFO" "Source Share:       ${SOURCE_SHARE}"
log "INFO" "Destination Share:  ${DESTINATION_SHARE}"
log "INFO" "DRY RUN Mode:       ${DRY_RUN}"
log "INFO" "Delete Source:      ${DELETE_SOURCE}"

# Explicitly fail if both DRY_RUN and DELETE_SOURCE are set to true
if [[ "${DRY_RUN}" == true && "${DELETE_SOURCE}" == true ]]; then
        log "FATAL" "DRY_RUN and DELETE_SOURCE are mutually exclusive. Enable only one at a time. Exiting Now.."
        exit 1
fi

# Pre-flight checks, in order: the shares must exist, must both be NFS mounts,
# and the script must have write permission to both. Each exits the run on
# failure, so order matters — existence is verified before anything stats or
# writes to the paths.
verify_shares_exist
verify_nfs_shares
verify_write_permissions

# Clear any stale failure lists from a previously crashed run
rm -f "${FAILED_FILES_LIST}" "${FAILED_DELETES_LIST}"

# Step 1: Find the files and write them to a manifest file
log "INFO" "Finding files on ${SOURCE_SHARE} last modified in ${ARCHIVE_YEAR}"
find_files

if [[ ! -f "${ARCHIVE_MANIFEST}" ]]; then
        log "INFO" "Nothing to archive for ${ARCHIVE_YEAR}. Exiting."
        exit 0
fi

if [[ "${DRY_RUN}" == true ]]; then
        dry_count="$(count_manifest_files "${ARCHIVE_MANIFEST}")"
        log "INFO" "${SCRIPT_NAME} running in DRY-RUN mode. No files would be copied over"
        log "INFO" "Number files to be copied over ${SOURCE_SHARE} to the ${DESTINATION_SHARE}/${ARCHIVE_YEAR} is: ${dry_count}."
        log "INFO" "DRY RUN Mode Completed. Exiting Now"
        rm -f "${ARCHIVE_MANIFEST}"
        exit 0
fi

# Step 2: Copy files to the destination share
rsync_to_destination

# Step 3: Validate, then retry if needed. Track the final verdict explicitly
validation_passed=true
if ! rsync_cmp; then
        if ! retry_failed_files; then
                validation_passed=false
        fi
fi

# Step 4: Delete source only if validation fully passed AND deletion is enabled
if [[ "${validation_passed}" == true ]]; then
        if [[ "${DELETE_SOURCE}" == true ]]; then
                delete_source_files
        else
                log "INFO" "Validation passed. DELETE_SOURCE is false; source files retained (copy-only run)."
        fi
else
        log "ERROR" "Validation didn't fully pass. Source files retained. See ${FAILED_FILES_LIST}"
        exit 1
fi

log "INFO" "Archive run for the year ${ARCHIVE_YEAR} complete"

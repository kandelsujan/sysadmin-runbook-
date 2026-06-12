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

# Making sure these variables are passed during script invocation
ARCHIVE_YEAR="${ARCHIVE_YEAR:?ERROR: ARCHIVE_YEAR must be provided via command line}"
SOURCE_SHARE="${SOURCE_SHARE:?ERROR: SOURCE_SHARE must be provided via command line}"
DESTINATION_SHARE="${DESTINATION_SHARE:?ERROR: DESTINATION_SHARE must be provided via command line}"

# Options to turn on the following (mutually exclusive) options:
#   DRY_RUN: This will give us the number of files that would be moved over.
#   DELETE_SOURCE: This deletes source files once rsync copy is completed
#                  and files are validated.
DELETE_SOURCE="${DELETE_SOURCE:-false}"  # Defaults safely to false if omitted
DRY_RUN="${DRY_RUN:-false}"              # Set true to see how many files would move

# Defining other variables needed
SCRIPT_NAME="${0##*/}"
RUN_ID="$(date +'%Y%m%d_%H%M%S')_$$"
LOG_DIRECTORY="/home/sk901741/local_development/shell_scripts/work_in_progess"
LOG_FILE='archive.log'
ARCHIVE_LOG_FILE="${LOG_DIRECTORY}/${LOG_FILE}"

# RUN_ID already contains a timestamp + PID, so these names are unique per run.
# The error file is only created when rsync actually runs — no mktemp at parse
# time, so dry runs and aborted instances leave nothing behind.
RSYNC_ERR_FILE="${LOG_DIRECTORY}/RSYNC_ERR.${RUN_ID}"
FAILED_FILES_LIST="${LOG_DIRECTORY}/FAILED_FILES_LIST_${ARCHIVE_YEAR}"
LOCK_FILE="${LOG_DIRECTORY}/archive.LCK"
PRIOR_YEAR_ARCHIVE=$((ARCHIVE_YEAR - 1))

# Manifest is anchored to LOG_DIRECTORY so the script behaves the same no
# matter what directory it is launched from (cron runs from $HOME).
ARCHIVE_MANIFEST="${LOG_DIRECTORY}/${ARCHIVE_YEAR}_manifest"

MAX_RETRIES=4  # Maximum number of retry attempts when checksums differ

#------------------------------------------------------------------------------
# Function Declarations
#------------------------------------------------------------------------------

# Write logs into the archive log file. The 'level' argument sets the priority
# of the log entry. e.g.:  log "INFO" "This is just a test log entry"
log() {
        local level=$1
        local message=$2
        local timestamp
        timestamp=$(date +'%Y-%m-%d %H:%M:%S')
        echo "[${timestamp}] [${level}] ${message}" >>"${ARCHIVE_LOG_FILE}"
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

        # Execute file transfer and evaluate outcome
        if rsync "${rsync_opts[@]}" "${SOURCE_SHARE}/" "${DESTINATION_SHARE}/${ARCHIVE_YEAR}/" >/dev/null 2>"${RSYNC_ERR_FILE}"; then
                log "INFO" "${file_count} files have been copied over successfully"

                # Remove the error file if rsync finished without writing to it
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

        # Execute a dry-run checksum comparison (-c)
        # NOTE: Rsync exits with code 0 even if files differ; it only returns
        # non-zero on error.
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

# Delete the source copies of every file in the manifest. Only ever called
# after validation fully passed AND DELETE_SOURCE=true, so every file in the
# manifest is known to exist at the destination with a matching checksum.
# Failures are logged and counted rather than aborting mid-delete.
delete_source_files() {
        local file_count
        file_count=$(count_manifest_files "${ARCHIVE_MANIFEST}")
        log "INFO" "Validation passed and DELETE_SOURCE=true. Deleting ${file_count} source file(s) from ${SOURCE_SHARE}"

        local failed_deletes=0
        local rel_path
        while IFS= read -r rel_path; do
                [[ -z "${rel_path}" ]] && continue
                if ! rm -f -- "${SOURCE_SHARE}/${rel_path}"; then
                        log "ERROR" "Failed to delete ${SOURCE_SHARE}/${rel_path}"
                        ((failed_deletes++)) || true
                fi
        done <"${ARCHIVE_MANIFEST}"

        if [[ "${failed_deletes}" -eq 0 ]]; then
                log "INFO" "All ${file_count} source file(s) deleted successfully"
                return 0
        else
                log "ERROR" "${failed_deletes} file(s) could not be deleted from the source share. Manual intervention required."
                return 1
        fi
        # NOTE: the manifest only contains files (find -type f), so empty
        # directories are left behind on the source share. To prune them too:
        #   find "${SOURCE_SHARE}" -mindepth 1 -type d -empty -delete
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

# Check if source and destination shares are both NFS. If they are not NFS
# shares, exit the script.
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

# Acquire the lock; bail out if another instance holds it
exec 9>"${LOCK_FILE}"
flock -n 9 || {
        log "FATAL" "Another instance of this script is currently running. Aborting now..."
        exit 1
}
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

# Pre-flight checks: source and destination must be NFS, and the script must
# have write permissions to both of them
verify_nfs_shares
verify_write_permissions

# Clear any stale failure list from a previously crashed run
rm -f "${FAILED_FILES_LIST}"

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

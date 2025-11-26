#!/bin/bash

DELETE_ORIGINALS=false

check_unicode_support() {
    if [[ -n "$TERM" && "$TERM" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        if tput colors >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
            HAS_UNICODE=1
            GREEN='\033[0;32m'
            RED='\033[0;31m'
            YELLOW='\033[1;33m'
            BLUE='\033[0;34m'
            CYAN='\033[0;36m'
            NC='\033[0m'
            CHECK_MARK="✅"
            X_MARK="❌"
            WARNING="⚠️"
            INFO="ℹ️"
            TRASH="🗑️"
        else
            HAS_UNICODE=0
            GREEN=''; RED=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
            CHECK_MARK="[OK]"
            X_MARK="[ERROR]"
            WARNING="[WARN]"
            INFO="[INFO]"
            TRASH="[DELETE]"
        fi
    else
        HAS_UNICODE=0
        GREEN=''; RED=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
        CHECK_MARK="[OK]"
        X_MARK="[ERROR]"
        WARNING="[WARN]"
        INFO="[INFO]"
        TRASH="[DELETE]"
    fi
}

print_status() {
    local type="$1"
    local message="$2"
    
    case $type in
        "success")
            if [[ $HAS_UNICODE -eq 1 ]]; then
                echo -e "${GREEN}${CHECK_MARK} ${message}${NC}"
            else
                echo "${CHECK_MARK} ${message}"
            fi
            ;;
        "error")
            if [[ $HAS_UNICODE -eq 1 ]]; then
                echo -e "${RED}${X_MARK} ${message}${NC}"
            else
                echo "${X_MARK} ${message}"
            fi
            ;;
        "warning")
            if [[ $HAS_UNICODE -eq 1 ]]; then
                echo -e "${YELLOW}${WARNING} ${message}${NC}"
            else
                echo "${WARNING} ${message}"
            fi
            ;;
        "info")
            if [[ $HAS_UNICODE -eq 1 ]]; then
                echo -e "${BLUE}${INFO} ${message}${NC}"
            else
                echo "${INFO} ${message}"
            fi
            ;;
        "delete")
            if [[ $HAS_UNICODE -eq 1 ]]; then
                echo -e "${CYAN}${TRASH} ${message}${NC}"
            else
                echo "${TRASH} ${message}"
            fi
            ;;
    esac
}

setup_logging() {
    LOG_FILE="m4a_to_flac_conversion_$(date +%Y%m%d_%H%M%S).log"
    print_status "info" "Log file: $LOG_FILE"
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        "SUCCESS") print_status "success" "$message" ;;
        "ERROR") print_status "error" "$message" ;;
        "WARNING") print_status "warning" "$message" ;;
        "INFO") print_status "info" "$message" ;;
        "DELETE") print_status "delete" "$message" ;;
    esac
}

check_m4a_integrity() {
    local input_file="$1"
    
    if [[ ! -f "$input_file" ]]; then
        log_message "ERROR" "File '$input_file' does not exist"
        return 1
    fi
    
    if [[ ! -s "$input_file" ]]; then
        log_message "ERROR" "File '$input_file' is empty"
        return 1
    fi
    
    if ! ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | grep -q "aac\|alac"; then
        log_message "ERROR" "File '$input_file' does not contain AAC/ALAC audio track or is corrupted"
        return 1
    fi
    
    if ! ffmpeg -v error -i "$input_file" -f null - 2>/dev/null; then
        log_message "ERROR" "File '$input_file' is corrupted"
        return 1
    fi
    
    return 0
}

convert_m4a_to_flac() {
    local input_file="$1"
    local output_file="${input_file%.m4a}.flac"
    
    log_message "INFO" "Converting: $input_file -> $output_file"
    
    if ffmpeg -i "$input_file" -c:a flac -compression_level 8 -y "$output_file" 2>/dev/null; then
        if [[ -f "$output_file" && -s "$output_file" ]]; then
            log_message "SUCCESS" "Successfully converted: $output_file"
            
            if ffmpeg -v error -i "$output_file" -f null - 2>/dev/null; then
                log_message "SUCCESS" "FLAC file passed integrity check"
                
                if [[ "$DELETE_ORIGINALS" == true ]]; then
                    if rm "$input_file"; then
                        log_message "DELETE" "Original M4A file deleted: $input_file"
                    else
                        log_message "ERROR" "Failed to delete original file: $input_file"
                    fi
                fi
                return 0
            else
                log_message "ERROR" "FLAC file corrupted after conversion"
                rm -f "$output_file"
                return 1
            fi
        else
            log_message "ERROR" "Output file was not created or is empty"
            return 1
        fi
    else
        log_message "ERROR" "Conversion failed for file: $input_file"
        return 1
    fi
}

process_directory() {
    local dir="$1"
    
    log_message "INFO" "Processing directory: $dir"
    
    while IFS= read -r -d '' file; do
        if [[ -d "$file" ]]; then
            process_directory "$file"
        elif [[ -f "$file" && "${file,,}" == *.m4a ]]; then
            log_message "INFO" "Found M4A file: $file"
            
            if check_m4a_integrity "$file"; then
                log_message "SUCCESS" "M4A file passed integrity check"
                
                if convert_m4a_to_flac "$file"; then
                    log_message "SUCCESS" "File successfully processed"
                else
                    log_message "ERROR" "Conversion failed"
                fi
            else
                log_message "WARNING" "Skipping corrupted file: $file"
            fi
            echo "---"
        fi
    done < <(find "$dir" -mindepth 1 -print0 2>/dev/null)
}

check_dependencies() {
    local deps=("ffmpeg" "ffprobe")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_message "ERROR" "$dep is not installed"
            echo "Install ffmpeg:"
            echo "  Ubuntu/Debian: sudo apt install ffmpeg"
            echo "  CentOS/RHEL: sudo yum install ffmpeg"
            echo "  macOS: brew install ffmpeg"
            exit 1
        fi
    done
}

show_summary() {
    local success_count=$(grep -c "Successfully converted:" "$LOG_FILE" 2>/dev/null || echo 0)
    local error_count=$(grep -c "Conversion failed\|File corrupted\|does not contain" "$LOG_FILE" 2>/dev/null || echo 0)
    local delete_count=0
    
    if [[ "$DELETE_ORIGINALS" == true ]]; then
        delete_count=$(grep -c "Original M4A file deleted:" "$LOG_FILE" 2>/dev/null || echo 0)
    fi
    
    local total_count=$((success_count + error_count))
    
    echo
    print_status "info" "=== CONVERSION SUMMARY ==="
    print_status "success" "Successfully converted: $success_count files"
    if [[ "$DELETE_ORIGINALS" == true ]]; then
        print_status "delete" "Original M4A files deleted: $delete_count files"
    fi
    print_status "error" "Failed: $error_count files"
    print_status "info" "Total processed: $total_count files"
    print_status "info" "Detailed log: $LOG_FILE"
}

show_usage() {
    echo "Usage: $0 [OPTIONS] [DIRECTORY]"
    echo
    echo "Options:"
    echo "  -d, --delete-originals    Delete original M4A files after successful conversion"
    echo "  -h, --help               Show this help message"
    echo
    echo "If DIRECTORY is not specified, current directory will be used."
}

parse_arguments() {
    local start_dir="."
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--delete-originals)
                DELETE_ORIGINALS=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                start_dir="$1"
                shift
                ;;
        esac
    done
    
    echo "$start_dir"
}

main() {
    local start_dir
    
    start_dir=$(parse_arguments "$@")
    
    check_unicode_support
    setup_logging
    
    log_message "INFO" "Starting M4A to FLAC conversion script"
    log_message "INFO" "Unicode support: $HAS_UNICODE"
    log_message "INFO" "Delete originals: $DELETE_ORIGINALS"
    
    if [[ "$DELETE_ORIGINALS" == true ]]; then
        print_status "warning" "ORIGINAL M4A FILES WILL BE DELETED AFTER SUCCESSFUL CONVERSION"
        read -p "Are you sure you want to continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Operation cancelled"
            exit 0
        fi
    fi
    
    if [[ ! -d "$start_dir" ]]; then
        log_message "ERROR" "Directory '$start_dir' does not exist"
        exit 1
    fi
    
    start_dir=$(realpath "$start_dir")
    
    log_message "INFO" "Starting directory: $start_dir"
    log_message "INFO" "Searching for M4A files..."
    
    check_dependencies
    
    process_directory "$start_dir"
    
    log_message "INFO" "Processing completed"
    show_summary
}

main "$@"

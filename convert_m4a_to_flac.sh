#!/bin/bash

# Check if terminal supports Unicode and colors
check_unicode_support() {
    if [[ -n "$TERM" && "$TERM" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        if tput colors >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
            HAS_UNICODE=1
            GREEN='\033[0;32m'
            RED='\033[0;31m'
            YELLOW='\033[1;33m'
            BLUE='\033[0;34m'
            NC='\033[0m'
            CHECK_MARK="✅"
            X_MARK="❌"
            WARNING="⚠️"
            INFO="ℹ️"
        else
            HAS_UNICODE=0
            GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
            CHECK_MARK="[OK]"
            X_MARK="[ERROR]"
            WARNING="[WARN]"
            INFO="[INFO]"
        fi
    else
        HAS_UNICODE=0
        GREEN=''; RED=''; YELLOW=''; BLUE=''; NC=''
        CHECK_MARK="[OK]"
        X_MARK="[ERROR]"
        WARNING="[WARN]"
        INFO="[INFO]"
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
    local total_count=$((success_count + error_count))
    
    echo
    print_status "info" "=== CONVERSION SUMMARY ==="
    print_status "success" "Successfully converted: $success_count files"
    print_status "error" "Failed: $error_count files"
    print_status "info" "Total processed: $total_count files"
    print_status "info" "Detailed log: $LOG_FILE"
}

main() {
    local start_dir="${1:-.}"
    
    check_unicode_support
    setup_logging
    
    log_message "INFO" "Starting M4A to FLAC conversion script"
    log_message "INFO" "Unicode support: $HAS_UNICODE"
    
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

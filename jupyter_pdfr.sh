#!/bin/bash

# ==============================================================================
# JUPYTER_PDFR.SH - Advanced Jupyter to PDF/HTML Converter
# ==============================================================================
# - robust dependency checking
# - nested menus with 'q' to back/quit
# - overwrite protection (auto-renaming)
# - stitching options for PDF and HTML
# - user-defined file ordering and selection
#
# chmod +x jupyter_pdfr.sh && ./jupyter_pdfr.sh
# ==============================================================================

# UI Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global State Variables
SOURCE_DIR=""
BASE_OUT_DIR=""
FINAL_OUT_DIR=""
FORMAT=""
SHOW_CODE="true"
DO_STITCH="false"
STITCH_NAME=""
KEEP_INDIVIDUAL="false"

# ------------------------------------------------------------------------------
# UNIVERSAL NAVIGATION PROMPT
# ------------------------------------------------------------------------------
prompt_user() {
    local msg="$1"
    local response_var="$2"
    local val
    echo -ne "${CYAN}${msg}${NC}"
    IFS= read -r val
    if [[ "$val" == "q" || "$val" == "Q" ]]; then
        return 1
    fi
    printf -v "$response_var" '%s' "$val"
    return 0
}

# ------------------------------------------------------------------------------
# OVERWRITE PROTECTION ENGINE
# ------------------------------------------------------------------------------
get_safe_path() {
    local dir="$1" base="$2" ext="$3"
    local target="$dir/$base.$ext"
    local counter=1
    while [[ -e "$target" ]]; do
        target="$dir/$base($counter).$ext"
        ((counter++))
    done
    echo "$target"
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECK
# ------------------------------------------------------------------------------
check_deps() {
    echo -e "${BLUE}Scanning for mandatory dependencies...${NC}"
    local missing=()

    command -v jupyter  &>/dev/null || missing+=("jupyter")
    command -v pdftk    &>/dev/null || command -v pdfunite &>/dev/null || missing+=("pdftk|pdfunite")
    command -v xelatex  &>/dev/null || missing+=("xelatex (texlive-xetex)")

    if ! jupyter nbconvert --help &>/dev/null; then
        missing+=("nbconvert")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}[!] Missing items: ${missing[*]}${NC}"
        local ans
        if ! prompt_user "Attempt automatic installation via apt now? (y/n/q): " ans; then exit 0; fi
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            sudo apt-get update && sudo apt-get install -y \
                jupyter-core jupyter-nbconvert pdftk poppler-utils \
                texlive-xetex pandoc
        else
            echo -e "${RED}Fatal: Dependencies missing. Exiting.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}[OK] Environment validated.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# INITIAL LOCATION SETUP
# ------------------------------------------------------------------------------
init_directories() {
    local current; current=$(pwd)

    while true; do
        echo -e "\n${BLUE}=== Initialize Working Environments ===${NC}"

        local src_in
        if ! prompt_user "Enter Source Folder [Enter = $current]: " src_in; then exit 0; fi
        if [[ -z "$src_in" ]]; then
            SOURCE_DIR="$current"
        else
            SOURCE_DIR=$(realpath -q "$src_in" 2>/dev/null)
        fi
        if [[ ! -d "$SOURCE_DIR" ]]; then
            echo -e "${RED}Invalid source folder. Try again.${NC}"
            continue
        fi

        local out_in
        if ! prompt_user "Enter Base Output Destination [Enter = $current]: " out_in; then exit 0; fi
        if [[ -z "$out_in" ]]; then
            BASE_OUT_DIR="$current"
        else
            BASE_OUT_DIR=$(realpath -q "$out_in" 2>/dev/null)
        fi
        if ! mkdir -p "$BASE_OUT_DIR"; then
            echo -e "${RED}Cannot create/use output dir. Try again.${NC}"
            continue
        fi
        return 0
    done
}

# ------------------------------------------------------------------------------
# PIPELINE CONFIGURATION
# ------------------------------------------------------------------------------
configure_pipeline() {
    # 1. STYLE
    echo -e "\n${YELLOW}=== Visibility Style ===${NC}"
    echo " 1. Standard Convert (Include Code Cells)"
    echo " 2. Clean Convert (Hide Code Cells)"

    local style_choice=""
    if ! prompt_user "Select option: " style_choice; then return 1; fi
    if [[ "$style_choice" == "2" ]]; then SHOW_CODE="false"; else SHOW_CODE="true"; fi

    # 2. STITCHING
    local stitch_choice=""
    if ! prompt_user "Stitch into One Master File? (y/n/q): " stitch_choice; then return 1; fi
    if [[ "$stitch_choice" == "y" || "$stitch_choice" == "Y" ]]; then
        DO_STITCH="true"

        # NEW: keep the individual files too?
        local keep_choice=""
        if ! prompt_user "Keep individual files alongside the master? (y/n/q): " keep_choice; then return 1; fi
        if [[ "$keep_choice" == "y" || "$keep_choice" == "Y" ]]; then
            KEEP_INDIVIDUAL="true"
        else
            KEEP_INDIVIDUAL="false"
        fi

        if ! prompt_user "Enter the name of the file (no ext): " STITCH_NAME; then return 1; fi
        STITCH_NAME=$(printf '%s' "$STITCH_NAME" | tr -dc '[:alnum:]\-\_')
        if [[ -z "$STITCH_NAME" ]]; then
            echo -e "${RED}Invalid name; aborting.${NC}"
            return 1
        fi
    else
        DO_STITCH="false"
        STITCH_NAME=""
        KEEP_INDIVIDUAL="false"
    fi

    # 3. FOLDER ISOLATION
    local folder_choice=""
    if ! prompt_user "Output to new folder? (y/n/q): " folder_choice; then return 1; fi
    if [[ "$folder_choice" == "y" || "$folder_choice" == "Y" ]]; then
        # Default the folder name to the stitched master name (if any).
        local default_folder="$STITCH_NAME"
        local new_folder_name=""
        if [[ -n "$default_folder" ]]; then
            if ! prompt_user "Name the folder [Enter = ${default_folder}]: " new_folder_name; then return 1; fi
            [[ -z "$new_folder_name" ]] && new_folder_name="$default_folder"
        else
            if ! prompt_user "Name the folder: " new_folder_name; then return 1; fi
        fi
        new_folder_name=$(printf '%s' "$new_folder_name" | tr -dc '[:alnum:]\-\_')
        if [[ -z "$new_folder_name" ]]; then
            echo -e "${RED}Invalid folder name; aborting.${NC}"
            return 1
        fi
        FINAL_OUT_DIR="${BASE_OUT_DIR}/${new_folder_name}"
    else
        FINAL_OUT_DIR="$BASE_OUT_DIR"
    fi
    mkdir -p "$FINAL_OUT_DIR"

    # 4. DISCOVER NOTEBOOKS
    local available_files=()
    while IFS= read -r -d '' file; do
        available_files+=("$file")
    done < <(find "$SOURCE_DIR" -maxdepth 1 -name "*.ipynb" -print0 | sort -z)

    local total_count=${#available_files[@]}
    if [[ $total_count -eq 0 ]]; then
        echo -e "${RED}[!] No .ipynb files found in $SOURCE_DIR${NC}"
        return 1
    fi

    echo -e "\n${YELLOW}Discovered Notebooks:${NC}"
    for i in "${!available_files[@]}"; do
        printf " [%d] %s\n" "$((i+1))" "$(basename "${available_files[$i]}")"
    done

    echo -e "\nOptions: 1) All Files   2) Custom Selection/Order (e.g. '3 1 2')"
    local select_opt=""
    if ! prompt_user "Choice: " select_opt; then return 1; fi

    local working_set=()
    if [[ "$select_opt" == "2" ]]; then
        local target_idxs=""
        if ! prompt_user "Enter ordered index numbers (space-separated): " target_idxs; then return 1; fi
        for idx in $target_idxs; do
            local arr_idx=$((idx-1))
            if [[ $arr_idx -ge 0 && $arr_idx -lt $total_count ]]; then
                working_set+=("${available_files[$arr_idx]}")
            fi
        done
        local sel_count=${#working_set[@]}
        if [[ $sel_count -eq 0 ]]; then
            echo -e "${RED}No valid indices.${NC}"
            return 1
        fi
        if [[ $sel_count -lt $total_count ]]; then
            echo -e "\n${YELLOW}[!] You selected $sel_count of $total_count files.${NC}"
            local confirm=""
            if ! prompt_user "Is this correct? (y/n/q): " confirm; then return 1; fi
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 1
            fi
        fi
    else
        working_set=("${available_files[@]}")
    fi

    execute_conversion working_set
}

# ------------------------------------------------------------------------------
# EXECUTION ENGINE
# ------------------------------------------------------------------------------
execute_conversion() {
    local -n files_ref=$1

    # Pre-flight: xelatex needed for PDF
    if [[ "$FORMAT" == "pdf" ]] && ! command -v xelatex &>/dev/null; then
        echo -e "${RED}[!] xelatex not found; PDF conversion will fail.${NC}"
        echo -e "${RED}    Install with: sudo apt-get install texlive-xetex${NC}"
        return 1
    fi

    local flags=(--to "$FORMAT")
    [[ "$SHOW_CODE" == "false" ]] && flags+=(--no-input)

    echo -e "\n${GREEN}Starting Batch Conversion...${NC}"
    local staging_area="/tmp/pdfr_stage_$$"
    if ! mkdir -p "$staging_area"; then
        echo -e "${RED}Cannot create staging area $staging_area${NC}"
        return 1
    fi

    local historical_staged=()
    local failures=0

    for nb in "${files_ref[@]}"; do
        local base_no_ext; base_no_ext=$(basename "$nb" .ipynb)
        echo -e "Converting: ${CYAN}$(basename "$nb")${NC}"

        # NOTE: no silent redirect - user sees nbconvert errors
        jupyter nbconvert "${flags[@]}" "$nb" --output-dir="$staging_area"
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            local staged_output="$staging_area/${base_no_ext}.${FORMAT}"
            if [[ ! -f "$staged_output" ]]; then
                echo -e "${RED}  -> Expected output missing: $(basename "$staged_output")${NC}"
                ((failures++))
                continue
            fi

            if [[ "$DO_STITCH" == "true" ]]; then
                historical_staged+=("$staged_output")
                echo -e "  -> Staged for stitching."
            else
                local safe_dest; safe_dest=$(get_safe_path "$FINAL_OUT_DIR" "$base_no_ext" "$FORMAT")
                mv "$staged_output" "$safe_dest"
                echo -e "  -> Exported: $(basename "$safe_dest")"
            fi
        else
            echo -e "${RED}  -> nbconvert exited with code $rc${NC}"
            ((failures++))
        fi
    done

    # ---- STITCHING ----
    if [[ "$DO_STITCH" == "true" && ${#historical_staged[@]} -gt 0 ]]; then
        echo -e "\n${YELLOW}Stitching ${#historical_staged[@]} element(s)...${NC}"
        local master_target; master_target=$(get_safe_path "$FINAL_OUT_DIR" "$STITCH_NAME" "$FORMAT")

        if [[ "$FORMAT" == "pdf" ]]; then
            if command -v pdftk &>/dev/null; then
                pdftk "${historical_staged[@]}" cat output "$master_target"
            elif command -v pdfunite &>/dev/null; then
                pdfunite "${historical_staged[@]}" "$master_target"
            else
                echo -e "${RED}[Error] Neither pdftk nor pdfunite available.${NC}"
                rm -rf "$staging_area"
                return 1
            fi
        else
            # Valid HTML: pull <body>…</body> from each and wrap.
            {
                echo '<!DOCTYPE html>'
                echo '<html><head><meta charset="utf-8">'
                echo "<title>${STITCH_NAME}</title>"
                echo '<style>body{font-family:sans-serif;max-width:960px;margin:auto;padding:20px}
                      .pdfr-section{page-break-before:always;border-top:2px solid #ccc;
                                    margin-top:30px;padding-top:20px}
                      .pdfr-section:first-child{border-top:none;margin-top:0;padding-top:0}</style>'
                echo '</head><body>'
                for f in "${historical_staged[@]}"; do
                    echo "<section class=\"pdfr-section\">"
                    echo "<h1>$(basename "$f" .html)</h1>"
                    # Crude but effective: strip <html>/<head>/<body> wrappers
                    sed -n '/<body[^>]*>/,/<\/body>/p' "$f" | sed '1d;$d'
                    echo "</section>"
                done
                echo '</body></html>'
            } > "$master_target"
        fi

        if [[ -s "$master_target" ]]; then
            echo -e "${GREEN}[Success] Master file: $master_target${NC}"

            # NEW: preserve the per-notebook files if the user asked for them
            if [[ "$KEEP_INDIVIDUAL" == "true" ]]; then
                echo -e "${YELLOW}Preserving individual files...${NC}"
                for f in "${historical_staged[@]}"; do
                    local bname; bname=$(basename "$f" ".${FORMAT}")
                    local safe_dest; safe_dest=$(get_safe_path "$FINAL_OUT_DIR" "$bname" "$FORMAT")
                    mv "$f" "$safe_dest"
                    echo -e "  -> Kept: $(basename "$safe_dest")"
                done
            fi
        else
            echo -e "${RED}[Error] Stitching failed.${NC}"
        fi
    fi

    if [[ $failures -gt 0 ]]; then
        echo -e "${YELLOW}[!] $failures notebook(s) failed.${NC}"
    fi

    rm -rf "$staging_area"
    echo -ne "${CYAN}Press Enter to return to menu...${NC}"
    IFS= read -r _
}

# ==============================================================================
# MAIN
# ==============================================================================

check_deps
init_directories

while true; do
    echo -e "\n${BLUE}=========================================${NC}"
    echo    "   JUPYTER_PDFR - Main Controller"
    echo    "   Source: $SOURCE_DIR"
    echo    "   Output: $BASE_OUT_DIR"
    echo -e "${BLUE}=========================================${NC}"
    echo    " 1. Convert to HTML (Fast/Web View)"
    echo    " 2. Convert to PDF  (Print/Document View)"
    echo    " 3. Change Directory"
    echo    " q. Quit"
    echo -e "${BLUE}-----------------------------------------${NC}"

    main_choice=""
    if ! prompt_user "Select option: " main_choice; then echo "Goodbye."; exit 0; fi

    case "$main_choice" in
        1) FORMAT="html" ;;
        2) FORMAT="pdf"  ;;
        3) init_directories; continue ;;
        q|Q) echo "Exiting."; exit 0 ;;
        *) continue ;;
    esac

    configure_pipeline
done

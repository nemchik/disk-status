#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# https://en.wikipedia.org/wiki/S.M.A.R.T.#Known_ATA_S.M.A.R.T._attributes
declare -Agr ERROR_ATTRIBUTES=(
    [5]="Reallocated_Sector_Ct"
    [10]="Spin_Retry_Count"
    [184]="End-to-End_Error"
    [187]="Reported_Uncorrect"
    [188]="Command_Timeout"
    [196]="Reallocated_Event_Count"
    [197]="Current_Pending_Sector"
    [198]="Offline_Uncorrectable"
)
declare -Agr WARN_ATTRIBUTES=(
    [9]="Power_On_Hours"
    [194]="Temperature"
)

# Script Information
# https://stackoverflow.com/questions/59895/get-the-source-directory-of-a-bash-script-from-within-the-script-itself/246128#246128
get_scriptname() {
    # https://stackoverflow.com/questions/35006457/choosing-between-0-and-bash-source/35006505#35006505
    local SOURCE=${BASH_SOURCE[0]:-$0}
    while [[ -L ${SOURCE} ]]; do # resolve ${SOURCE} until the file is no longer a symlink
        local DIR
        DIR=$(cd -P "$(dirname "${SOURCE}")" > /dev/null 2>&1 && pwd)
        SOURCE=$(readlink "${SOURCE}")
        [[ ${SOURCE} != /* ]] && SOURCE="${DIR}/${SOURCE}" # if ${SOURCE} was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    echo "${SOURCE}"
}
readonly SCRIPTPATH=$(cd -P "$(dirname "$(get_scriptname)")" > /dev/null 2>&1 && pwd)
readonly SCRIPTNAME="${SCRIPTPATH}/$(basename "$(get_scriptname)")"

# Terminal Colors
if [[ ${CI:-} == true ]] || [[ -t 1 ]]; then
    readonly SCRIPTTERM=true
fi
tcolor() {
    if [[ -n ${SCRIPTTERM:-} ]]; then
        # http://linuxcommand.org/lc3_adv_tput.php
        local BF=${1:-}
        local CAP
        case ${BF} in
            [Bb]) CAP=setab ;;
            [Ff]) CAP=setaf ;;
            [Nn][Cc]) CAP=sgr0 ;;
            *) return ;;
        esac
        local COLOR_IN=${2:-}
        local VAL
        if [[ ${CAP} != "sgr0" ]]; then
            case ${COLOR_IN} in
                [Bb4]) VAL=4 ;; # Blue
                [Cc6]) VAL=6 ;; # Cyan
                [Gg2]) VAL=2 ;; # Green
                [Kk0]) VAL=0 ;; # Black
                [Mm5]) VAL=5 ;; # Magenta
                [Rr1]) VAL=1 ;; # Red
                [Ww7]) VAL=7 ;; # White
                [Yy3]) VAL=3 ;; # Yellow
                *) return ;;
            esac
        fi
        local COLOR_OUT
        if [[ $(tput colors 2> /dev/null) -ge 8 ]]; then
            COLOR_OUT=$(eval tput ${CAP:-} ${VAL:-} 2> /dev/null)
        fi
        echo "${COLOR_OUT:-}"
    else
        return
    fi
}
declare -Agr B=(
    [B]=$(tcolor B B)
    [C]=$(tcolor B C)
    [G]=$(tcolor B G)
    [K]=$(tcolor B K)
    [M]=$(tcolor B M)
    [R]=$(tcolor B R)
    [W]=$(tcolor B W)
    [Y]=$(tcolor B Y)
)
declare -Agr F=(
    [B]=$(tcolor F B)
    [C]=$(tcolor F C)
    [G]=$(tcolor F G)
    [K]=$(tcolor F K)
    [M]=$(tcolor F M)
    [R]=$(tcolor F R)
    [W]=$(tcolor F W)
    [Y]=$(tcolor F Y)
)
readonly NC=$(tcolor NC)

# Log Functions
readonly LOG_TEMP=$(mktemp) || echo "Failed to create temporary log file."
echo > "${LOG_TEMP}"
log() {
    local TOTERM=${1:-}
    local MESSAGE=${2:-}
    echo -e "${MESSAGE:-}" | (
        if [[ -n ${TOTERM} ]]; then
            tee -a "${LOG_TEMP}" >&2
        else
            cat >> "${LOG_TEMP}" 2>&1
        fi
    )
}
trace() { log "${TRACE:-}" "${NC}$(date +"%F %T") ${F[B]}[TRACE ]${NC}   $*${NC}"; }
debug() { log "${DEBUG:-}" "${NC}$(date +"%F %T") ${F[B]}[DEBUG ]${NC}   $*${NC}"; }
info() { log "${VERBOSE:-}" "${NC}$(date +"%F %T") ${F[B]}[INFO  ]${NC}   $*${NC}"; }
notice() { log "true" "${NC}$(date +"%F %T") ${F[G]}[NOTICE]${NC}   $*${NC}"; }
warn() { log "true" "${NC}$(date +"%F %T") ${F[Y]}[WARN  ]${NC}   $*${NC}"; }
error() { log "true" "${NC}$(date +"%F %T") ${F[R]}[ERROR ]${NC}   $*${NC}"; }
fatal() {
    log "true" "${NC}$(date +"%F %T") ${B[R]}${F[W]}[FATAL ]${NC}   $*${NC}"
    exit 1
}


# Cleanup Function
cleanup() {
    local -ri EXIT_CODE=$?

    if [[ ${EXIT_CODE} -ne 0 ]]; then
        error "Script did not finish running successfully."
    fi

    sudo sh -c "cat ${LOG_TEMP} >> ${SCRIPTPATH}/disk-status.log" || true

    exit ${EXIT_CODE}
    trap - 0 1 2 3 6 14 15
}
trap 'cleanup' 0 1 2 3 6 14 15

# Main Function
main() {
    for disk in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
        if [[ ! -e ${disk} ]]; then
            continue
        fi
        local SMARTCTL_OUTPUT
        SMARTCTL_OUTPUT=$(mktemp) || error "Failed to create temporary file for ${disk} SMART information."
        smartctl -a "${disk}" > ${SMARTCTL_OUTPUT} || true
        if ! grep -q 'SMART support is: Available - device has SMART capability.' "${SMARTCTL_OUTPUT}"; then
            error "${disk} SMART information is not available."
            echo
            continue
        fi

        notice "${disk}"
        local HEALTH_VAL
        HEALTH_VAL=$(grep --color=never -Po "SMART overall-health self-assessment test result:\s+\K.*" "${SMARTCTL_OUTPUT}") || true
        if [[ ${HEALTH_VAL} == "PASSED" ]]; then
            notice "Health:\t${HEALTH_VAL}"
        else
            error "Health:\t${HEALTH_VAL}"
        fi
        while IFS= read -r line; do
            local ID_VAL
            ID_VAL=$(echo "${line}" | awk '{ print $1 }' | xargs) || true
            local ATTRIBUTE_NAME_VAL
            ATTRIBUTE_NAME_VAL=$(echo "${line}" | awk '{ print $2 }' | xargs) || true
            local FLAG_VAL
            FLAG_VAL=$(echo "${line}" | awk '{ print $3 }' | xargs) || true
            local VALUE_VAL
            VALUE_VAL=$(echo "${line}" | awk '{ print $4 }' | xargs) || true
            local WORST_VAL
            WORST_VAL=$(echo "${line}" | awk '{ print $5 }' | xargs) || true
            local THRESH_VAL
            THRESH_VAL=$(echo "${line}" | awk '{ print $6 }' | xargs) || true
            local TYPE_VAL
            TYPE_VAL=$(echo "${line}" | awk '{ print $7 }' | xargs) || true
            local UPDATED_VAL
            UPDATED_VAL=$(echo "${line}" | awk '{ print $8 }' | xargs) || true
            local WHEN_FAILED_VAL
            WHEN_FAILED_VAL=$(echo "${line}" | awk '{ print $9 }' | xargs) || true
            local RAW_VALUE_VAL
            RAW_VALUE_VAL=$(echo "${line}" | awk '{ print $10 }' | xargs) || true

            if [[ ${TYPE_VAL} == "Pre-fail" ]]; then
                if [[ ${RAW_VALUE_VAL} > 0 ]] || [[ ${RAW_VALUE_VAL} > ${THRESH_VAL} ]]; then
                    local error="false"
                    for i in "${!ERROR_ATTRIBUTES[@]}"; do
                        if [[ ${i} == "${ID_VAL}" ]] && [[ ${ERROR_ATTRIBUTES[$i]} == "${ATTRIBUTE_NAME_VAL}" ]]; then
                            error="true"
                        fi
                    done
                    if [[ ${error} == "true" ]]; then
                        error "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                    else
                        warn "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                    fi
                else
                    info "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                fi
            elif [[ ${TYPE_VAL} == "Old_age" ]]; then
                if [[ ${RAW_VALUE_VAL} > ${THRESH_VAL} ]]; then
                    local notice="false"
                    for i in "${!WARN_ATTRIBUTES[@]}"; do
                        if [[ ${i} == "${ID_VAL}" ]] && [[ ${WARN_ATTRIBUTES[$i]} == "${ATTRIBUTE_NAME_VAL}" ]]; then
                            notice="true"
                        fi
                    done
                    if [[ ${notice} == "true" ]]; then
                        notice "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                    else
                        info "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                    fi
                else
                    info "${ATTRIBUTE_NAME_VAL}:\t${RAW_VALUE_VAL}"
                fi
            fi
        done < <(grep --color=never -P "(Pre-fail|Old_age)\s+(Always|Offline)" "${SMARTCTL_OUTPUT}")
        echo
    done
}
main

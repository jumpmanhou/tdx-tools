#!/bin/bash
#
# Launch QEMU-KVM to create Guest VM in following types:
# - Legacy VM: non-TDX VM boot with legacy(non-EFI) SEABIOS at /usr/share/qemu-kvm/bios.bin
# - EFI VM: non-TDX VM boot with EFI BIOS OVMF(Open Virtual Machine Firmware)
# - TD VM: TDX VM boot with OVMF via qemu-kvm launch parameter "kvm-type=tdx,confidential-guest-support=tdx"
#
# Prerequisite:
# 1. On Intel 4th Gen Xeon Server (Sapphire Rapids) or later platform
#   - Enable TDX in platform BIOS
#   - Install and boot TDX host kernel
#   - Install TDVF(Trust Domain Virtual Firmware) at /usr/share/qemu
#   - Install Qemu with TDX support at /usr/libexec/qemu-kvm (It might be
#     different path for Ubuntu and Debian)
# 2. Create TDX guest image with
#   - TDX guest kernel
#   - (optional)Modified Grub and Shim for TDX measurement to RTMR
#
# Note:
#
# - This script support "direct" and "grub" boot:
#   * direct: pass kernel image via "-kernel" and kernel command line via
#             "cmdline" via qemu-kvm launch parameter.
#   * grub: do not pass kernel and cmdline but leverage EFI BDS boot
#           shim->grub->kernel within guest image
# - To get consistent TD_REPORT within guest cross power cycle, please keep
#   consistent configurations for TDX guest such as same MAC address.
#

CURR_DIR=$(readlink -f "$(dirname "$0")")

# VM configurations
CORES=1
SOCKET=1
MEM=2G

# Installed from the package of intel-mvp-tdx-tdvf
OVMF_CODE="/usr/share/qemu/OVMF_CODE.fd"
OVMF_VARS="/usr/share/qemu/OVMF_VARS.fd"
# Installed from the package of intel-mvp-tdx-qemu-kvm
LEGACY_BIOS="/usr/share/qemu-kvm/bios.bin"
GUEST_IMG=""
DEFAULT_GUEST_IMG="${CURR_DIR}/td-guest.qcow2"
KERNEL=""
DEFAULT_KERNEL="${CURR_DIR}/vmlinuz"
VM_TYPE="td"
BOOT_TYPE="direct"
DEBUG=false
USE_VSOCK=false
USE_SERIAL_CONSOLE=false
FORWARD_PORT=10026
MONITOR_PORT=9001
KERNEL_CMD_NON_TD="root=/dev/vda3 rw selinux=0 console=hvc0"
KERNEL_CMD_TD="${KERNEL_CMD_NON_TD}"
MAC_ADDR=""

# Just log message of serial into file without input
HVC_CONSOLE="-chardev stdio,id=mux,mux=on,logfile=$CURR_DIR/vm_log_$(date +"%FT%H%M").log \
             -device virtio-serial,romfile= \
             -device virtconsole,chardev=mux -monitor chardev:mux \
             -serial chardev:mux "
#
# In grub boot, serial consle need input to select grub menu instead of HVC
# Please make sure console=ttyS0 is added in grub.cfg since no virtconsole
#
SERIAL_CONSOLE="-serial stdio"

# Default template for QEMU command line
QEMU_CMD="/usr/libexec/qemu-kvm -accel kvm \
          -name process=tdxvm,debug-threads=on \
          -smp $CORES,sockets=$SOCKET -m $MEM -vga none \
          -monitor pty \
          -no-hpet -nodefaults"
PARAM_CPU=" -cpu host,-kvm-steal-time,pmu=off"
PARAM_MACHINE=" -machine q35"

usage() {
    cat << EOM
Usage: $(basename "$0") [OPTION]...
  -i <guest image file>     Default is td-guest.qcow2 under current directory
  -k <kernel file>          Default is vmlinuz under current directory
  -t [legacy|efi|td]        VM Type, default is "td"
  -b [direct|grub]          Boot type, default is "direct" which requires kernel binary specified via "-k"
  -p <Monitor port>         Monitor via telnet
  -f <SSH Forward port>     Host port for forwarding guest SSH
  -o <OVMF_CODE file>       BIOS CODE firmware device file, for "td" and "efi" VM only
  -a <OVMF_VARS file>       BIOS VARS template, for "td" and "efi" VM only
  -m <11:22:33:44:55:66>    MAC address, impact TDX measurement RTMR
  -v                        Flag to enable vsock
  -d                        Flag to enable "debug=on" for GDB guest
  -s                        Flag to use serial console instead of HVC console
  -h                        Show this help
EOM
}

error() {
    echo -e "\e[1;31mERROR: $*\e[0;0m"
    exit 1
}

warn() {
    echo -e "\e[1;33mWARN: $*\e[0;0m"
}

process_args() {
    while getopts ":i:k:t:b:p:f:o:a:m:vdsh" option; do
        case "$option" in
            i) GUEST_IMG=$OPTARG;;
            k) KERNEL=$OPTARG;;
            t) VM_TYPE=$OPTARG;;
            b) BOOT_TYPE=$OPTARG;;
            p) MONITOR_PORT=$OPTARG;;
            f) FORWARD_PORT=$OPTARG;;
            o) OVMF_CODE=$OPTARG;;
            a) OVMF_VARS=$OPTARG;;
            m) MAC_ADDR=$OPTARG;;
            v) USE_VSOCK=true;;
            d) DEBUG=true;;
            s) USE_SERIAL_CONSOLE=true;;
            h) usage;;
            *) usage;;
        esac
    done

    if [[ ! -f /usr/libexec/qemu-kvm ]]; then
        error "Please install qemu-kvm which supports TDX."
    fi

    GUEST_IMG="${GUEST_IMG:-${DEFAULT_GUEST_IMG}}"
    if [[ ! -f ${GUEST_IMG} ]]; then
        usage
        error "Guest image file ${GUEST_IMG} not exist. Please specify via option \"-i\""
    fi

    # Create Variable firmware device file from template
    if [[ ${OVMF_VARS} == "/usr/share/qemu/OVMF_VARS.fd" ]]; then
        OVMF_VARS="${CURR_DIR}/OVMF_VARS.fd"
        if [[ ! -f ${OVMF_VARS} ]]; then
            if [[ ! -f /usr/share/qemu/OVMF_CODE.fd ]]; then
                error "Could not find /usr/share/qemu/OVMF_CODE.fd. Please install TDVF(Trusted Domain Virtual Firmware)."
            fi
            echo "Create ${OVMF_VARS} from template /usr/share/qemu/OVMF_VARS.fd"
            cp /usr/share/qemu/OVMF_VARS.fd "${OVMF_VARS}"
        fi
    fi

    # Check parameter MAC address
    if [[ -n ${MAC_ADDR} ]]; then
        if [[ ! ${MAC_ADDR} =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
            error "Invalid MAC address: ${MAC_ADDR}"
        fi
    fi

    QEMU_CMD+=" -drive file=$(readlink -f "${GUEST_IMG}"),if=virtio,format=qcow2 "
    QEMU_CMD+=" -monitor telnet:127.0.0.1:${MONITOR_PORT},server,nowait "

    if [[ ${DEBUG} == true ]]; then
        OVMF_CODE="/usr/share/qemu/OVMF_CODE.debug.fd"
    fi

    case ${VM_TYPE} in
        "td")
            cpu_tsc=$(grep 'cpu MHz' /proc/cpuinfo | head -1 | awk -F: '{print $2/1024}')
            if (( $(echo "$cpu_tsc < 1" |bc -l) )); then
                PARAM_CPU+=",tsc-freq=1000000000"
            fi
            # Note: "pic=no" could only be used in TD mode but not for non-TD mode
            PARAM_MACHINE+=",pic=no,kernel_irqchip=split,kvm-type=tdx,confidential-guest-support=tdx"
            QEMU_CMD+=" -device loader,file=${OVMF_CODE},id=fd0"
            QEMU_CMD+=",config-firmware-volume=${OVMF_VARS}"
            QEMU_CMD+=" -object tdx-guest,id=tdx"
            if [[ ${DEBUG} == true ]]; then
                QEMU_CMD+=",debug=on"
            fi
            ;;
        "efi")
            PARAM_MACHINE+=",kernel_irqchip=split"
            QEMU_CMD+=" -drive if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
            QEMU_CMD+=" -drive if=pflash,format=raw,file=${OVMF_VARS}"
            ;;
        "legacy")
            if [[ ! -f ${LEGACY_BIOS} ]]; then
                error "${LEGACY_BIOS} does not exist!"
            fi
            QEMU_CMD+=" -bios ${LEGACY_BIOS} "
            ;;
        *)
            error "Invalid ${VM_TYPE}, must be [legacy|efi|td]"
            ;;
    esac

    QEMU_CMD+=$PARAM_CPU
    QEMU_CMD+=$PARAM_MACHINE
    QEMU_CMD+=" -device virtio-net-pci,netdev=mynet0"

    # Customize MAC address. NOTE: it will impact TDX measurement RTMR.
    if [[ -n ${MAC_ADDR} ]]; then
        QEMU_CMD+=",mac=${MAC_ADDR}"
    fi

    # Forward SSH port to the host
    QEMU_CMD+=" -netdev user,id=mynet0,hostfwd=tcp::$FORWARD_PORT-:22 "

    # Enable vsock
    if [[ ${USE_VSOCK} == true ]]; then
        QEMU_CMD+=" -device vhost-vsock-pci,guest-cid=3 "
    fi

    case ${BOOT_TYPE} in
        "direct")
            KERNEL="${KERNEL:-${DEFAULT_KERNEL}}"
            if [[ ! -f ${KERNEL} ]]; then
                usage
                error "Kernel image file ${KERNEL} not exist. Please specify via option \"-k\""
            fi

            QEMU_CMD+=" -kernel $(readlink -f "${KERNEL}") "
            if [[ ${VM_TYPE} == "td" ]]; then
                # shellcheck disable=SC2089
                QEMU_CMD+=" -append \"${KERNEL_CMD_TD}\" "
            else
                # shellcheck disable=SC2089
                QEMU_CMD+=" -append \"${KERNEL_CMD_NON_TD}\" "
            fi
            ;;
        "grub")
            if [[ ${USE_SERIAL_CONSOLE} == false ]]; then
                warn "Using HVC console for grub, could not accept key input in grub menu"
            fi
            ;;
        *)
            echo "Invalid ${BOOT_TYPE}, must be [direct|grub]"
            exit 1
            ;;
    esac

    echo "========================================="
    echo "Guest Image       : ${GUEST_IMG}"
    echo "Kernel binary     : ${KERNEL}"
    echo "OVMF_CODE         : ${OVMF_CODE}"
    echo "OVMF_VARS         : ${OVMF_VARS}"
    echo "VM Type           : ${VM_TYPE}"
    echo "Boot type         : ${BOOT_TYPE}"
    echo "Monitor port      : ${MONITOR_PORT}"
    echo "Enable vsock      : ${USE_VSOCK}"
    echo "Enable debug      : ${DEBUG}"
    if [[ -n ${MAC_ADDR} ]]; then
        echo "MAC Address       : ${MAC_ADDR}"
    fi
    if [[ ${USE_SERIAL_CONSOLE} == true ]]; then
        QEMU_CMD+=" ${SERIAL_CONSOLE} "
        echo "Console           : Serial"
    else
        QEMU_CMD+=" ${HVC_CONSOLE} "
        echo "Console           : HVC"
    fi
    echo "========================================="
}

launch_vm() {
    echo "Launch VM:"
    # shellcheck disable=SC2086,SC2090
    echo ${QEMU_CMD}
    # shellcheck disable=SC2086
    eval ${QEMU_CMD}
}

process_args "$@"
launch_vm

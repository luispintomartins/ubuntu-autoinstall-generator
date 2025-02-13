#!/bin/bash
set -Eeuo pipefail

function log() {
    echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
    local msg=$1
    local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
    log "$msg"
    exit "$code"
}

function check_dependencies() {
    log "🔎 Checking for required utilities..."
    [[ ! -x "$(command -v date)" ]] && echo "💥 date command not found." && exit 1
    [[ ! -x "$(command -v xorriso)" ]] && die "💥 xorriso is not installed. On Ubuntu, install  the 'xorriso' package."
    [[ ! -x "$(command -v sed)" ]] && die "💥 sed is not installed. On Ubuntu, install the 'sed' package."
    [[ ! -x "$(command -v curl)" ]] && die "💥 curl is not installed. On Ubuntu, install the 'curl' package."
    [[ ! -x "$(command -v gpg)" ]] && die "💥 gpg is not installed. On Ubuntu, install the 'gpg' package."
    [[ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]] && die "💥 isolinux is not installed. On Ubuntu, install the 'isolinux' package."
    [[ ! -x "$(command -v fdisk)" ]] && die "💥 fdisk is not installed. On Ubuntu, install the 'fdisk' package."
    log "👍 All required utilities are installed."
}

function usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-a] [-e] [-u user-data-file] [-m meta-data-file] [-k] [-c] [-r] [-s source-iso-file] [-d destination-iso-file]

💁 This script will create fully-automated Ubuntu installation media using autoinstall.

Available options:

-h, --help              Print this help and exit
-v, --verbose           Print script debug info
-a, --all-in-one        Bake user-data and meta-data into the generated ISO. By default you will
                        need to boot systems with a CIDATA volume attached containing your
                        autoinstall user-data and meta-data files.
                        For more information see: https://ubuntu.com/server/docs/install/autoinstall-quickstart
-e, --use-hwe-kernel    Force the generated ISO to boot using the hardware enablement (HWE) kernel. Not supported
                        by early Ubuntu 20.04 release ISOs.
-u, --user-data         Path to user-data file. Required if using -a
-m, --meta-data         Path to meta-data file. Will be an empty file if not specified and using -a
-k, --no-verify         Disable GPG verification of the source ISO file. By default SHA256SUMS-$today and
                        SHA256SUMS-$today.gpg in ${script_dir} will be used to verify the authenticity and integrity
                        of the source ISO file. If they are not present the latest daily SHA256SUMS will be
                        downloaded and saved in ${script_dir}. The Ubuntu signing key will be downloaded and
                        saved in a new keyring in ${script_dir}
-c, --no-md5            Disable MD5 checksum on boot
-V, --version           Select the Ubuntu version to choose from (default: ${ubuntu_version}).
-r, --use-release-iso   Use the current release ISO instead of the daily ISO. The file will be used if it already
                        exists.
-s, --source            Source ISO file. By default the latest daily ISO for Ubuntu ${ubuntu_version^} will be downloaded
                        and saved as ${script_dir}/ubuntu-original-$today.iso
                        That file will be used by default if it already exists.
-d, --destination       Destination ISO file. By default ${script_dir}/ubuntu-autoinstall-$today.iso will be
                        created, overwriting any existing file.
EOF
    exit
}

function parse_params() {
    # default values of variables set from params
    ubuntu_version="jammy"
    today=$(date +"%Y-%m-%d")
    user_data_file=''
    meta_data_file=''
    download_url="https://cdimage.ubuntu.com/ubuntu-server/${ubuntu_version}/daily-live/current"
    download_iso="${ubuntu_version}-live-server-amd64.iso"
    original_iso="ubuntu-original-$today.iso"
    source_iso="${script_dir}/${original_iso}"
    additional_files_folder=""
    destination_iso="${script_dir}/ubuntu-autoinstall-$today.iso"
    sha_suffix="${today}"
    gpg_verify=1
    all_in_one=0
    use_hwe_kernel=0
    md5_checksum=1
    use_release_iso=0
    release_type="server"

    while :; do
        case "${1-}" in
        -h | --help) usage ;;
        -v | --verbose) set -x ;;
        -a | --all-in-one) all_in_one=1 ;;
        -e | --use-hwe-kernel) use_hwe_kernel=1 ;;
        -c | --no-md5) md5_checksum=0 ;;
        -k | --no-verify) gpg_verify=0 ;;
        -r | --use-release-iso)
            use_release_iso=1
            release_type="${2-}"
            shift
            ;;
        -V | --version)
            ubuntu_version="${2-}"
            shift
            ;;
        -u | --user-data)
            user_data_file="${2-}"
            shift
            ;;
        -A | --additional-files)
            additional_files_folder="${2-}"
            shift
            ;;
        -s | --source)
            source_iso="${2-}"
            shift
            ;;
        -d | --destination)
            destination_iso="${2-}"
            shift
            ;;
        -m | --meta-data)
            meta_data_file="${2-}"
            shift
            ;;
        -?*) die "Unknown option: $1" ;;
        *) break ;;
        esac
        shift
    done
    log "👶 Starting up..."
}

function validate_params() {
    # check required params and arguments
    if [ ${all_in_one} -ne 0 ]; then
        [[ -z "${user_data_file}" ]] && die "💥 user-data file was not specified."
        [[ ! -f "$user_data_file" ]] && die "💥 user-data file could not be found."
        [[ -n "${meta_data_file}" ]] && [[ ! -f "$meta_data_file" ]] && die "💥 meta-data file could not be found."
    fi

    if [ "${source_iso}" != "${script_dir}/${original_iso}" ]; then
        [[ ! -f "${source_iso}" ]] && die "💥 Source ISO file could not be found."
    fi

    if [ "${use_release_iso}" -eq 1 ]; then
        download_url="https://releases.ubuntu.com/${ubuntu_version}"
        log "🔎 Checking for current release..."
        download_iso=$(curl -sSL "${download_url}" | grep -oP "ubuntu-\d+\.\d+\.\d*.*-${release_type}-amd64\.iso" | head -n 1)
        original_iso="${download_iso}"
        source_iso="${script_dir}/${download_iso}"
        current_release=$(echo "${download_iso}" | cut -f2 -d-)
        sha_suffix="${current_release}"
        log "💿 Current release is ${current_release}"
    fi

    destination_iso=$(realpath "${destination_iso}")
    source_iso=$(realpath "${source_iso}")
}

function create_tmp_dir() {
    tmpdir=$(mktemp -d)

    if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
        die "💥 Could not create temporary working directory."
    else
        log "📁 Created temporary working directory $tmpdir"
    fi
}

function fetch_iso() {
    if [ ! -f "${source_iso}" ]; then
        log "🌎 Downloading ISO image ${download_iso} for Ubuntu ${ubuntu_version^}..."
        curl -fNsSL "${download_url}/${download_iso}" -o "${source_iso}" ||
            die "👿 The download of the ISO ${download_iso} failed."
        log "👍 Downloaded and saved to ${source_iso}"
    else
        log "☑️ Using existing ${source_iso} file."
        if [ ${gpg_verify} -eq 1 ]; then
            if [ "${source_iso}" != "${script_dir}/${original_iso}" ]; then
                log "⚠️ Automatic GPG verification is enabled. If the source ISO file is not the latest daily or release image, verification will fail!"
            fi
        fi
    fi
}

function verify_iso() {
    if [ ${gpg_verify} -eq 1 ]; then
        install -d -m 0700 "$tmpdir/.gnupg"

        if [ ! -f "${script_dir}/SHA256SUMS-${sha_suffix}" ]; then
            log "🌎 Downloading SHA256SUMS & SHA256SUMS.gpg files..."
            curl -fNsSL "${download_url}/SHA256SUMS" -o "${script_dir}/SHA256SUMS-${sha_suffix}" ||
                die "👿 The download of the SHA256SUMS failed."
            curl -fNsSL "${download_url}/SHA256SUMS.gpg" -o "${script_dir}/SHA256SUMS-${sha_suffix}.gpg" ||
                die "👿 The download of the SHA256SUMS.gpg failed."
        else
            log "☑️ Using existing SHA256SUMS-${sha_suffix} & SHA256SUMS-${sha_suffix}.gpg files."
        fi

        if [ ! -f "${script_dir}/${ubuntu_gpg_key_id}.keyring" ]; then
            log "🌎 Downloading and saving Ubuntu signing key..."
            gpg -q \
                --homedir "$tmpdir" \
                --no-default-keyring \
                --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" \
                --keyserver "hkp://keyserver.ubuntu.com" \
                --recv-keys "${ubuntu_gpg_key_id}"
            log "👍 Downloaded and saved to ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        else
            log "☑️ Using existing Ubuntu signing key saved in ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        fi

        log "🔐 Verifying ${source_iso} integrity and authenticity..."
        gpg -q \
            --homedir "$tmpdir" \
            --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" \
            --verify "${script_dir}/SHA256SUMS-${sha_suffix}.gpg" \
            "${script_dir}/SHA256SUMS-${sha_suffix}" \
            2>/dev/null
        if [ $? -ne 0 ]; then
            rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
            die "👿 Verification of SHA256SUMS signature failed."
        fi

        rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
        rm -rf "$tmpdir/.gnupg"
        digest=$(sha256sum "${source_iso}" | cut -f1 -d ' ')
        set +e
        grep -Fq "$digest" "${script_dir}/SHA256SUMS-${sha_suffix}"
        if [ $? -eq 0 ]; then
            log "👍 Verification succeeded."
            set -e
        else
            die "👿 Verification of ISO digest failed."
        fi
    else
        log "🤞 Skipping verification of source ISO."
    fi
}

function extract_iso() {
    log "🔧 Extracting ISO image..."
    ls -lad "${source_iso}" "$tmpdir"
    xorriso \
        -uid "$(id -u)" \
        -gid "$(id -g)" \
        -osirrox on \
        -indev "${source_iso}" \
        -extract / "$tmpdir"
    chmod -R u+w "$tmpdir"
    rm -rf "$tmpdir/"'[BOOT]'
    log "👍 Extracted to $tmpdir"
}

function patch_iso() {
    if [[ "${ubuntu_version}" =~ ^(jammy)$ ]]; then
        log "🔧 Extracting EFI images from image..."
        efi_start=$(fdisk -o Start,Type -l "${source_iso}" | grep -oP '\d+(?=\s+EFI.System)')
        efi_length=$(fdisk -o Sectors,Type -l "${source_iso}" | grep -oP '\d+(?=\s+EFI.System)')
        dd if="${source_iso}" bs=512 skip=${efi_start} count=${efi_length} of="${source_iso}-efi.img" status=none
        dd if="${source_iso}" bs=1 count=432 of="${source_iso}-hybrid.img" status=none
        log "👍 Extracted EFI images"
    fi

    if [ ${use_hwe_kernel} -eq 1 ]; then
        if grep -q "hwe-vmlinuz" "$tmpdir/boot/grub/grub.cfg"; then
            log "☑️ Destination ISO will use HWE kernel."
            if [[ "${ubuntu_version}" =~ ^(bionic|focal|groovy|hirsute|impish)$ ]]; then
                sed -i -e 's|/casper/vmlinuz|/casper/hwe-vmlinuz|g' "$tmpdir/isolinux/txt.cfg"
                sed -i -e 's|/casper/initrd|/casper/hwe-initrd|g' "$tmpdir/isolinux/txt.cfg"
            fi
            sed -i -e 's|/casper/vmlinuz|/casper/hwe-vmlinuz|g' "$tmpdir/boot/grub/grub.cfg"
            sed -i -e 's|/casper/initrd|/casper/hwe-initrd|g' "$tmpdir/boot/grub/grub.cfg"
            sed -i -e 's|/casper/vmlinuz|/casper/hwe-vmlinuz|g' "$tmpdir/boot/grub/loopback.cfg"
            sed -i -e 's|/casper/initrd|/casper/hwe-initrd|g' "$tmpdir/boot/grub/loopback.cfg"
        else
            log "⚠️ This source ISO does not support the HWE kernel. Proceeding with the regular kernel."
        fi
    fi

    log "🧩 Adding autoinstall parameter to kernel command line..."
    if [[ "${ubuntu_version}" =~ ^(bionic|focal|groovy|hirsute|impish)$ ]]; then
        sed -i -r 's/timeout\s+[0-9]+/timeout 1/g' "$tmpdir/isolinux/isolinux.cfg"
        sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/isolinux/txt.cfg"
    fi
    sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/boot/grub/grub.cfg"
    sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/boot/grub/loopback.cfg"
    # reduce grub timeout to 1s
    if grep -q "set timeout" "$tmpdir/boot/grub/grub.cfg"; then
        sed -i -e 's/set timeout=.*/set timeout=1/g' "$tmpdir/boot/grub/grub.cfg"
    else
        echo "set timeout=1" >> "$tmpdir/boot/grub/grub.cfg"
    fi
    log "👍 Added parameter to UEFI and BIOS kernel command lines."

    if [ ${all_in_one} -eq 1 ]; then
        log "🧩 Adding user-data and meta-data files..."
        mkdir "$tmpdir/nocloud"
        cp "$user_data_file" "$tmpdir/nocloud/user-data"
        if [ -n "${meta_data_file}" ]; then
            cp "$meta_data_file" "$tmpdir/nocloud/meta-data"
        else
            touch "$tmpdir/nocloud/meta-data"
        fi
        if [[ "${ubuntu_version}" =~ ^(bionic|focal|groovy|hirsute|impish)$ ]]; then
            sed -i -e 's,---, ds=nocloud;s=/cdrom/nocloud/  ---,g' "$tmpdir/isolinux/txt.cfg"
        fi
        sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/boot/grub/grub.cfg"
        sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/boot/grub/loopback.cfg"
        log "👍 Added data and configured kernel command line."
    fi
}

function add_files_to_iso() {
    if [[ -n "$additional_files_folder" ]]; then
        log "➕ Adding additional files to the iso image..."
        cp -R "$additional_files_folder/." "$tmpdir/"
        log "👍 Added additional files"
    fi
}

function create_iso_checksums() {
    if [ ${md5_checksum} -eq 1 ]; then
        log "👷 Updating $tmpdir/md5sum.txt with hashes of modified files..."
        md5=$(md5sum "$tmpdir/boot/grub/grub.cfg" | cut -f1 -d ' ')
        sed -i -e 's,^.*[[:space:]] ./boot/grub/grub.cfg,'"$md5"'  ./boot/grub/grub.cfg,' "$tmpdir/md5sum.txt"
        md5=$(md5sum "$tmpdir/boot/grub/loopback.cfg" | cut -f1 -d ' ')
        sed -i -e 's,^.*[[:space:]] ./boot/grub/loopback.cfg,'"$md5"'  ./boot/grub/loopback.cfg,' "$tmpdir/md5sum.txt"
        log "👍 Updated hashes."
    else
        log "🗑️ Clearing MD5 hashes..."
        echo > "$tmpdir/md5sum.txt"
        log "👍 Cleared hashes."
    fi
}

function repackage_iso() {
    log "📦 Repackaging extracted files into an ISO image..."
    pushd "$tmpdir" &>/dev/null
    if [[ "${ubuntu_version}" =~ ^(bionic|focal|groovy|hirsute|impish)$ ]]; then
        xorriso \
            -as mkisofs \
                -r \
                -V "ubuntu-autoinstall-$today" \
                -J \
                -b isolinux/isolinux.bin \
                -c isolinux/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
                -boot-info-table \
                -input-charset utf-8 \
                -eltorito-alt-boot \
                -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
                -o "${destination_iso}" \
                . \
        &>/dev/null
    elif [[ "${ubuntu_version}" =~ ^(jammy)$ ]]; then
        xorriso \
            -as mkisofs \
                -r \
                -V "ubuntu-autoinstall-$today" \
                --grub2-mbr "${source_iso}-hybrid.img" \
                -partition_offset 16 --mbr-force-bootable \
                -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${source_iso}-efi.img" \
                -appended_part_as_gpt \
                -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
                -c '/boot.catalog' \
                -b '/boot/grub/i386-pc/eltorito.img' \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                --grub2-boot-info \
                -eltorito-alt-boot \
                -e '--interval:appended_partition_2:::' -no-emul-boot \
                -o "${destination_iso}" \
                . \
        &>/dev/null
    fi
    popd &>/dev/null
    log "👍 Repackaged into ${destination_iso}"
}

function cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    if [ -n "${tmpdir+x}" ]; then
        rm -rf "$tmpdir"
        log "🚽 Deleted temporary working directory $tmpdir"
    fi
}

trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
ubuntu_gpg_key_id="843938DF228D22F7B3742BC0D94AA3F0EFE21092"

# 1. check host for script dependencies
check_dependencies
# 2. parse user script parameters
parse_params "$@"
# 3. validate received user script parameters
validate_params
# 4. create script temporary directory
create_tmp_dir
# 5. download iso or find local source
fetch_iso
# 6. confirm iso gpg checksum if necessary
verify_iso
# 7. extract iso contents to temporary directory
extract_iso
# 8. patch iso contents
patch_iso
# 9. add user-defined files inside iso
add_files_to_iso
# 10. create checksum filelist inside iso
create_iso_checksums
# 11. repack iso contents into a new iso
repackage_iso
# 12. exit script sucessfully
die "✅ Completed." 0

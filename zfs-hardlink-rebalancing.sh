#!/usr/bin/env bash

# exit script on error
set -e
# exit on undeclared variable
set -u

# file used to track processed files
rebalance_db_file_name="rebalance_db.txt"

# index used for progress
current_index=0

## Color Constants

# Reset
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Cyan='\033[0;36m'         # Cyan

## Functions

# print a help message
function print_usage() {
  echo "Usage: zfs-inplace-rebalancing --checksum true --passes 1 source dest"
  echo "Note: hardlinks in the 'dest' path will be temporarily deleted during the rebalance."
}

# print a given text entirely in a given color
function color_echo () {
    color=$1
    text=$2
    echo -e "${color}${text}${Color_Off}"
}


function get_rebalance_count () {
    file_path=$1

    line_nr=$(grep -xF -n "${file_path}" "./${rebalance_db_file_name}" | head -n 1 | cut -d: -f1)
    if [ -z "${line_nr}" ]; then
        echo "0"
        return
    else
        rebalance_count_line_nr="$((line_nr + 1))"
        rebalance_count=$(awk "NR == ${rebalance_count_line_nr}" "./${rebalance_db_file_name}")
        echo "${rebalance_count}"
        return
    fi
}

# rebalance a specific file
function rebalance () {
    file_path=$1
    hardlink_dir=$2

    # check if file has exactly 2 links
    # this shouldn't be needed in the typical case of `find` only finding files with links == 2
    # but this can run for a long time, so it's good to double check if something changed
    if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
        # Linux
        #
        #  -c  --format=FORMAT
        #      use the specified FORMAT instead of the default; output a
        #      newline after each use of FORMAT
        #  %h     number of hard links
    
        hardlink_count=$(stat -c "%h" "${file_path}")
    elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
        # Mac OS
        # FreeBSD
        #  -f format
        #  Display information using the specified format
        #   l       Number of hard links to file (st_nlink)
    
        hardlink_count=$(stat -f %l "${file_path}")
    else
    	echo "Unsupported OS type: $OSTYPE"
    	exit 1
    fi

    if [ "${hardlink_count}" -ne 2 ]; then
        echo "Skipping non hard-linked file: ${file_path}"
        return
    fi

    current_index="$((current_index + 1))"
    progress_percent=$(printf '%0.2f' "$((current_index*10000/file_count))e-2")
    color_echo "${Cyan}" "Progress -- Files: ${current_index}/${file_count} (${progress_percent}%)" 

    # skip if the source file is no longer there
    if [[ ! -f "${file_path}" ]]; then
        color_echo "${Yellow}" "File is missing, skipping: ${file_path}" 
	return
    fi

    # skip if hardlink file is not found
    inode_val=$(ls -i "${file_path}" | awk '{print $1}')
    hardlink_path=$(find "${hardlink_dir}" -inum ${inode_val})
    if [[ ! -f "${hardlink_path}" ]]; then
        color_echo "${Yellow}" "Hardlink is missing, skipping: ${file_path}"
	return
    fi

    # skip if target number of passes is reached
    if [ "${passes_flag}" -ge 1 ]; then
        # check if target rebalance count is reached
        rebalance_count=$(get_rebalance_count "${file_path}")
        if [ "${rebalance_count}" -ge "${passes_flag}" ]; then
        color_echo "${Yellow}" "Rebalance count (${passes_flag}) reached, skipping: ${file_path}"
        return
        fi
    fi
   
    tmp_extension=".balance"
    tmp_file_path="${file_path}${tmp_extension}"

    # create copy of file with .balance suffix
    echo "Copying '${file_path}' to '${tmp_file_path}'..."
    if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
        # Linux

        # --reflink=never -- force standard copy (see ZFS Block Cloning)
        # -a -- keep attributes, includes -d -- keep symlinks (dont copy target) and 
        #       -p -- preserve ACLs to
        # -x -- stay on one system
        cp --reflink=never -ax "${file_path}" "${tmp_file_path}"
    elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
        # Mac OS
        # FreeBSD

        # -a -- Archive mode.  Same as -RpP. Includes preservation of modification 
        #       time, access time, file flags, file mode, ACL, user ID, and group 
        #       ID, as allowed by permissions.
        # -x -- File system mount points are not traversed.
        cp -ax "${file_path}" "${tmp_file_path}"
    else
        echo "Unsupported OS type: $OSTYPE"
        exit 1
    fi

    # compare copy against original to make sure nothing went wrong
    if [[ "${checksum_flag,,}" == "true"* ]]; then
        echo "Comparing copy against original..."
        if [[ "${OSTYPE,,}" == "linux-gnu"* ]]; then
            # Linux

            # file attributes
            original_md5=$(lsattr "${file_path}" | awk '{print $1}')
            # file permissions, owner, group
            # shellcheck disable=SC2012
            original_md5="${original_md5} $(ls -lha "${file_path}" | awk '{print $1 " " $3 " " $4}')"
            # file content
            original_md5="${original_md5} $(md5sum -b "${file_path}" | awk '{print $1}')"

            # file attributes
            copy_md5=$(lsattr "${tmp_file_path}" | awk '{print $1}')
            # file permissions, owner, group
            # shellcheck disable=SC2012
            copy_md5="${copy_md5} $(ls -lha "${tmp_file_path}" | awk '{print $1 " " $3 " " $4}')"
            # file content
            copy_md5="${copy_md5} $(md5sum -b "${tmp_file_path}" | awk '{print $1}')"
        elif [[ "${OSTYPE,,}" == "darwin"* ]] || [[ "${OSTYPE,,}" == "freebsd"* ]]; then
            # Mac OS
            # FreeBSD

            # file attributes
            original_md5=$(lsattr "${file_path}" | awk '{print $1}')
            # file permissions, owner, group
            # shellcheck disable=SC2012
            original_md5="${original_md5} $(ls -lha "${file_path}" | awk '{print $1 " " $3 " " $4}')"
            # file content
            original_md5="${original_md5} $(md5 -q "${file_path}")"

            # file attributes
            copy_md5=$(lsattr "${tmp_file_path}" | awk '{print $1}')
            # file permissions, owner, group
            # shellcheck disable=SC2012
            copy_md5="${copy_md5} $(ls -lha "${tmp_file_path}" | awk '{print $1 " " $3 " " $4}')"
            # file content
            copy_md5="${copy_md5} $(md5 -q "${tmp_file_path}")"
        else
            echo "Unsupported OS type: $OSTYPE"
            exit 1
        fi

        if [[ "${original_md5}" == "${copy_md5}"* ]]; then
            color_echo "${Green}" "MD5 OK"
        else
            color_echo "${Red}" "MD5 FAILED: ${original_md5} != ${copy_md5}"
            exit 1
        fi
    fi

    echo "Removing hardlink '${hardlink_path}'..."
    rm "${hardlink_path}"

    echo "Removing original '${file_path}'..."
    rm "${file_path}"

    echo "Renaming temporary copy to original '${file_path}'..."
    mv "${tmp_file_path}" "${file_path}"

    echo "Recreating deleted hardlink '${hardlink_path}'..."
    ln "$file_path" "$hardlink_path"

    if [ "${passes_flag}" -ge 1 ]; then
        # update rebalance "database"
        line_nr=$(grep -xF -n "${file_path}" "./${rebalance_db_file_name}" | head -n 1 | cut -d: -f1)
        if [ -z "${line_nr}" ]; then
            rebalance_count=1
            echo "${file_path}" >> "./${rebalance_db_file_name}"
            echo "${rebalance_count}" >> "./${rebalance_db_file_name}"
        else
            rebalance_count_line_nr="$((line_nr + 1))"
            rebalance_count="$((rebalance_count + 1))"
            sed -i "${rebalance_count_line_nr}s/.*/${rebalance_count}/" "./${rebalance_db_file_name}"
        fi
    fi
}

checksum_flag='true'
passes_flag='1'

if [[ "$#" -eq 0 ]]; then
    print_usage
    exit 0
fi

while true ; do
    case "$1" in
        -h | --help )
            print_usage
            exit 0
        ;;
        -c | --checksum )
            if [[ "$2" == 1 || "$2" =~ (on|true|yes) ]]; then
                checksum_flag="true"
            else
                checksum_flag="false"
            fi
            shift 2
        ;;
        -p | --passes )
            passes_flag=$2
            shift 2
        ;;
        *)
            break
        ;;
    esac 
done;

source_path=$1
dest_path=$2

color_echo "$Cyan" "Start rebalancing $(date):"
color_echo "$Cyan" "  Rebalance Path: ${source_path}"
color_echo "$Cyan" "  Hardlink Path: ${dest_path}"
color_echo "$Cyan" "  Rebalancing Passes: ${passes_flag}"
color_echo "$Cyan" "  Use Checksum: ${checksum_flag}"

# count number of hardlinked files
file_count=$(find "${source_path}" -type f -links 2 | wc -l)

color_echo "$Cyan" "  File count: ${file_count}"

# create db file
if [ "${passes_flag}" -ge 1 ]; then
    touch "./${rebalance_db_file_name}"
fi

# recursively scan through files and execute "rebalance" procedure if the file is a hardlink
find "${source_path}" -type f -links 2 -print0 | while IFS= read -r -d '' file; do rebalance "${file}" "${dest_path}"; done

echo ""
echo ""
color_echo "$Green" "Done!"

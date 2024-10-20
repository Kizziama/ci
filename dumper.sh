#!/usr/bin/env bash

[[ -z ${BOT_TOKEN} ]] && echo "BOT_TOKEN not defined, exiting!" && exit 1
[[ -z ${GITLAB_SERVER} ]] && GITLAB_SERVER="gitlab.com"
[[ -z $ORG ]] && ORG="hopireika-dumps"
[[ -z ${USE_ALT_DUMPER} ]] && USE_ALT_DUMPER="false"

# Inform the user about final status of build
terminate() {
	case ${1:?} in
	## Success
	0)
		echo "done"
		;;
	## Failure
	1)
		echo "failed"
		exit 1
		;;
	## Aborted
	2)
		echo "aborted! Branch already exists."
		exit 1
		;;
	*)
		echo "Unknown exit code: ${1}"
		exit 1
		;;
	esac
	exit 0
}

if echo "$1" | grep -E '^(https?|ftp)://.*$' >/dev/null; then
	if echo "$1" | grep -q '1drv.ms'; then
		URL=$(curl -I "$1" -s | grep -i location | sed -e "s/redir/download/g" -e "s/location: //g")
	else
		URL=$1
	fi

	if type aria2c >/dev/null 2>&1; then
		echo "[INFO] Started downloading... ($(date +%R:%S))"
		aria2c -x16 -j"$(nproc)" "${URL}"
	else
		echo "[INFO] Started downloading... ($(date +%R:%S))"
		wget -q --content-disposition --show-progress --progress=bar:force "${URL}" || exit 1
	fi

	if [[ ! -f "$(echo "${URL##*/}" | inline-detox)" ]]; then
		URL=$(wget --server-response --spider "${URL}" 2>&1 | awk -F"filename=" '{print $2}')
	fi

	detox "${URL##*/}"
	echo "[INFO] Finished downloading the file. ($(date +%R:%S))"
else
	URL=$(echo "$1")
	if [[ ! -e "$URL" ]]; then
		echo "Invalid Input"
		exit 1
	fi
fi

# Clean query strings if any from URL
oldifs=$IFS
IFS="?"
read -ra CLEANED <<<"${URL}"
URL=${CLEANED[0]}
IFS=$oldifs

FILE=${URL##*/}
EXTENSION=${URL##*.}
UNZIP_DIR=${FILE/.$EXTENSION/}
export UNZIP_DIR

if [[ ! -f ${FILE} ]]; then
	FILE="$(find . -type f)"
	if [[ "$(wc -l <<<"${FILE}")" != 1 ]]; then
		echo "Can't seem to find downloaded file!"
		terminate 1
	fi
fi

if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
	echo "Extracting firmware with Python dumper..."
	python3 -m dumpyara "${FILE}" -o "${PWD}" || {
		echo "Extraction failed!"
		terminate 1
	}
else
	# Try to minimize these, atleast "third-party" tools
	EXTERNAL_TOOLS=(
		https://github.com/AndroidDumps/Firmware_extractor
		https://github.com/marin-m/vmlinux-to-elf
	)

	for tool_url in "${EXTERNAL_TOOLS[@]}"; do
		tool_path="${HOME}/${tool_url##*/}"
		if ! [[ -d ${tool_path} ]]; then
			git clone -q "${tool_url}" "${tool_path}" >>/dev/null 2>&1
		else
			git -C "${tool_path}" pull >>/dev/null 2>&1
		fi
	done

	echo "Extracting firmware with alternative dumper..."
	bash "${HOME}"/Firmware_extractor/extractor.sh "${FILE}" "${PWD}" || {
		echo "Extraction failed!"
		terminate 1
	}

	PARTITIONS=(system systemex system_ext system_other
		vendor cust odm odm_ext oem factory product modem
		xrom oppo_product opproduct reserve india
		my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap
		my_custom my_manifest my_carrier my_region my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm mi_ext radio
	)

	echo "Extracting partitions..."

	# Set commonly used binary names
	FSCK_EROFS="${HOME}/Firmware_extractor/tools/fsck.erofs"
	EXT2RD="${HOME}/Firmware_extractor/tools/ext2rd"

	# Extract the images
	for p in "${PARTITIONS[@]}"; do
		if [[ -f $p.img ]]; then
			# Create a folder for each partition
			mkdir "$p" || rm -rf "${p:?}"/*

			# Try to extract images via 'fsck.erofs'
			echo "[INFO] Extracting '$p' via 'fsck.erofs'..."
			${FSCK_EROFS} --extract="$p" "$p".img >>/dev/null 2>&1 || {
				echo "[WARN] Extraction via 'fsck.erofs' failed."

				# Uses 'ext2rd' if images could not be extracted via 'fsck.erofs'
				echo "[INFO] Extracting '$p' via 'ext2rd'..."
				${EXT2RD} "$p".img ./:"${p}" >/dev/null || {
					echo "[WARN] Extraction via 'ext2rd' failed."

					# Uses '7zz' if images could not be extracted via 'ext2rd'
					echo "[INFO] Extracting '$p' via '7zz'..."
					7zz -snld x "$p".img -y -o"$p"/ >/dev/null || {
						echo "[ERROR] Extraction via '7zz' failed."

						# Only abort if we're at the first occourence
						if [[ "${p}" == "${PARTITIONS[0]}" ]]; then
							# In case of failure, bail out and abort dumping altogether
							echo "Extraction failed!"
							terminate 1
						fi
					}
				}
			}

			# Clean-up
			rm -f "$p".img
		fi
	done

	# Also extract 'fsg.mbn' from 'radio.img'
	if [ -f "${PWD}/fsg.mbn" ]; then
		echo "[INFO] Extracting 'fsg.mbn' via '7zz'..."

		# Create '${PWD}/radio/fsg'
		mkdir "${PWD}"/radio/fsg

		# Thankfully, 'fsg.mbn' is a simple EXT2 partition
		7zz -snld x "${PWD}/fsg.mbn" -o"${PWD}/radio/fsg" >/dev/null

		# Remove 'fsg.mbn'
		rm -rf "${PWD}/fsg.mbn"
	fi
fi

rm -f "$FILE"

for image in init_boot.img vendor_kernel_boot.img vendor_boot.img boot.img dtbo.img; do
	if [[ ! -f ${image} ]]; then
		x=$(find . -type f -name "${image}")
		if [[ -n $x ]]; then
			mv -v "$x" "${image}"
		fi
	fi
done

# Extract kernel, device-tree blobs [...]
## Set commonly used tools
UNPACKBOOTIMG="${HOME}/Firmware_extractor/tools/unpackbootimg"
KALLSYMS_FINDER="${HOME}/vmlinux-to-elf/vmlinux_to_elf/kallsyms_finder.py"
VMLINUX_TO_ELF="${HOME}/vmlinux-to-elf/vmlinux_to_elf/main.py"

# Extract 'boot.img'
if [[ -f "${PWD}/boot.img" ]]; then
	echo "[INFO] Extracting 'boot.img' content"
	# Set a variable for each path
	## Image
	IMAGE=${PWD}/boot.img

	## Output
	OUTPUT=${PWD}/boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"
	mkdir -p "${OUTPUT}/dtb"

	# Extract device-tree blobs from 'boot.img'
	echo "[INFO] Extracting device-tree blobs..."
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null || echo "[INFO] No device-tree blobs found."
	rm -rf "${OUTPUT}/dtb/00_kernel"

	# Do not run 'dtc' if no DTB was found
	if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
		echo "[INFO] Decompiling device-tree blobs..."
		# Decompile '.dtb' to '.dts'
		for dtb in $(find "${PWD}/boot/dtb" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || echo "[ERROR] Failed to decompile."
		done
	fi

	# Extract 'ikconfig'
	echo "[INFO] Extract 'ikconfig'..."
	if command -v extract-ikconfig >/dev/null; then
		extract-ikconfig "${PWD}"/boot.img >"${PWD}"/ikconfig || {
			echo "[ERROR] Failed to generate 'ikconfig'"
		}
	fi

	# Kallsyms
	echo "[INFO] Generating 'kallsyms.txt'..."
	python3 "${KALLSYMS_FINDER}" "${IMAGE}" >kallsyms.txt || {
		echo "[ERROR] Failed to generate 'kallsyms.txt'"
	}

	# ELF
	echo "[INFO] Extracting 'boot.elf'..."
	python3 "${VMLINUX_TO_ELF}" "${IMAGE}" boot.elf >/dev/null || {
		echo "[ERROR] Failed to generate 'boot.elf'"
	}

	# Python rewrite automatically extracts such partitions
	if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
		mkdir -p "${OUTPUT}/ramdisk"

		# Unpack 'boot.img' through 'unpackbootimg'
		echo "[INFO] Extracting 'boot.img' to 'boot/'..."
		${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}" >/dev/null || echo "[ERROR] Extraction unsuccessful."

		# Decrompress 'boot.img-ramdisk'
		## Run only if 'boot.img-ramdisk' is not empty
		if file boot.img-ramdisk | grep -q LZ4 || file boot.img-ramdisk | grep -q gzip; then
			echo "[INFO] Extracting ramdisk..."
			unlz4 "${OUTPUT}/boot.img-ramdisk" "${OUTPUT}/ramdisk.lz4" >/dev/null
			7zz -snld x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk" >/dev/null || echo "[ERROR] Failed to extract ramdisk."

			## Clean-up
			rm -rf "${OUTPUT}/ramdisk.lz4"
		fi
	fi
fi

# Extract 'vendor_boot.img'
if [[ -f "${PWD}/vendor_boot.img" ]]; then
	echo "[INFO] Extracting 'vendor_boot.img' content"
	# Set a variable for each path
	## Image
	IMAGE=${PWD}/vendor_boot.img

	## Output
	OUTPUT=${PWD}/vendor_boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"
	mkdir -p "${OUTPUT}/dtb"
	mkdir -p "${OUTPUT}/ramdisk"

	# Extract device-tree blobs from 'vendor_boot.img'
	echo "[INFO] Extracting device-tree blobs..."
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null || echo "[INFO] No device-tree blobs found."
	rm -rf "${OUTPUT}/dtb/00_kernel"

	# Decompile '.dtb' to '.dts'
	if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
		echo "[INFO] Decompiling device-tree blobs..."
		# Decompile '.dtb' to '.dts'
		for dtb in $(find "${OUTPUT}/dtb" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || echo "[ERROR] Failed to decompile."
		done
	fi

	# Python rewrite automatically extracts such partitions
	if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
		mkdir -p "${OUTPUT}/ramdisk"

		## Unpack 'vendor_boot.img' through 'unpackbootimg'
		echo "[INFO] Extracting 'vendor_boot.img' to 'vendor_boot/'..."
		${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}" >/dev/null || echo "[ERROR] Extraction unsuccessful."

		# Decrompress 'vendor_boot.img-vendor_ramdisk'
		echo "[INFO] Extracting ramdisk..."
		unlz4 "${OUTPUT}/vendor_boot.img-vendor_ramdisk" "${OUTPUT}/ramdisk.lz4" >/dev/null
		7zz -snld x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk" >/dev/null || echo "[ERROR] Failed to extract ramdisk."

		## Clean-up
		rm -rf "${OUTPUT}/ramdisk.lz4"
	fi
fi

# Extract 'vendor_kernel_boot.img'
if [[ -f "${PWD}/vendor_kernel_boot.img" ]]; then
	echo "[INFO] Extracting 'vendor_kernel_boot.img' content"

	# Set a variable for each path
	## Image
	IMAGE=${PWD}/vendor_kernel_boot.img

	## Output
	OUTPUT=${PWD}/vendor_kernel_boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"
	mkdir -p "${OUTPUT}/dtb"

	# Extract device-tree blobs from 'vendor_kernel_boot.img'
	echo "[INFO] Extracting device-tree blobs..."
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null || echo "[INFO] No device-tree blobs found."
	rm -rf "${OUTPUT}/dtb/00_kernel"

	# Decompile '.dtb' to '.dts'
	if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
		echo "[INFO] Decompiling device-tree blobs..."
		# Decompile '.dtb' to '.dts'
		for dtb in $(find "${OUTPUT}/dtb" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || echo "[ERROR] Failed to decompile."
		done
	fi

	# Python rewrite automatically extracts such partitions
	if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
		mkdir -p "${OUTPUT}/ramdisk"

		# Unpack 'vendor_kernel_boot.img' through 'unpackbootimg'
		echo "[INFO] Extracting 'vendor_kernel_boot.img' to 'vendor_kernel_boot/'..."
		${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}" >/dev/null || echo "[ERROR] Extraction unsuccessful."

		# Decrompress 'vendor_kernel_boot.img-vendor_ramdisk'
		echo "[INFO] Extracting ramdisk..."
		unlz4 "${OUTPUT}/vendor_kernel_boot.img-vendor_ramdisk" "${OUTPUT}/ramdisk.lz4" >/dev/null
		7zz -snld x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk" >/dev/null || echo "[ERROR] Failed to extract ramdisk."

		## Clean-up
		rm -rf "${OUTPUT}/ramdisk.lz4"
	fi
fi

# Extract 'init_boot.img'
if [[ -f "${PWD}/init_boot.img" ]]; then
	echo "[INFO] Extracting 'init_boot.img' content"

	# Set a variable for each path
	## Image
	IMAGE=${PWD}/init_boot.img

	## Output
	OUTPUT=${PWD}/init_boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"
	mkdir -p "${OUTPUT}/dtb"

	# Python rewrite automatically extracts such partitions
	if [[ "${USE_ALT_DUMPER}" == "false" ]]; then
		mkdir -p "${OUTPUT}/ramdisk"

		# Unpack 'init_boot.img' through 'unpackbootimg'
		echo "[INFO] Extracting 'init_boot.img' to 'init_boot/'..."
		${UNPACKBOOTIMG} -i "${IMAGE}" -o "${OUTPUT}" >/dev/null || echo "[ERROR] Extraction unsuccessful."

		# Decrompress 'init_boot.img-ramdisk'
		echo "[INFO] Extracting ramdisk..."
		unlz4 "${OUTPUT}/init_boot.img-ramdisk" "${OUTPUT}/ramdisk.lz4" >/dev/null
		7zz -snld x "${OUTPUT}/ramdisk.lz4" -o"${OUTPUT}/ramdisk" >/dev/null || echo "[ERROR] Failed to extract ramdisk."

		## Clean-up
		rm -rf "${OUTPUT}/ramdisk.lz4"
	fi
fi

# Extract 'dtbo.img'
if [[ -f "${PWD}/dtbo.img" ]]; then
	echo "[INFO] Extracting 'dtbo.img' content"

	# Set a variable for each path
	## Image
	IMAGE=${PWD}/dtbo.img

	## Output
	OUTPUT=${PWD}/dtbo

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"

	# Extract device-tree blobs from 'dtbo.img'
	echo "[INFO] Extracting device-tree blobs..."
	extract-dtb "${IMAGE}" -o "${OUTPUT}" >/dev/null || echo "[INFO] No device-tree blobs found."
	rm -rf "${OUTPUT}/00_kernel"

	# Decompile '.dtb' to '.dts'
	echo "[INFO] Decompiling device-tree blobs..."
	for dtb in $(find "${OUTPUT}" -type f); do
		dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || echo "[ERROR] Failed to decompile."
	done
fi

# Oppo/Realme/OnePlus devices have some images in folders, extract those
for dir in "vendor/euclid" "system/system/euclid" "reserve/reserve"; do
	[[ -d ${dir} ]] && {
		pushd "${dir}" || terminate 1
		for f in *.img; do
			[[ -f $f ]] || continue
			echo "Partition Name: ${p}"
			7zz -snld x "$f" -o"${f/.img/}" >/dev/null
			rm -fv "$f"
		done
		popd || terminate 1
	}
done

echo "All partitions extracted."

# Generate 'board-info.txt'
echo "[INFO] Generating 'board-info.txt'..."

## Generic
if [ -f ./vendor/build.prop ]; then
	strings ./vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >>./board-info.txt
fi

## Qualcomm-specific
if [[ $(find . -name "modem") ]] && [[ $(find . -name "*./tz*") ]]; then
	find ./modem -type f -exec strings {} \; | rg "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >>"${PWD}"/board-info.txt
	find ./tz* -type f -exec strings {} \; | rg "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >>"${PWD}"/board-info.txt
fi

## Sort 'board-info.txt' content
if [ -f "${PWD}"/board-info.txt ]; then
	sort -u -o ./board-info.txt ./board-info.txt
fi

# Prop extraction
echo "[INFO] Extracting properties..."

oplus_pipeline_key=$(rg -m1 -INoP --no-messages "(?<=^ro.oplus.pipeline_key=).*" my_manifest/build*.prop)

flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.flavor=).*" {vendor,system,system/system}/build.prop)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.flavor=).*" vendor/build*.prop)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.flavor=).*" {vendor,system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.flavor=).*" {system,system/system}/build*.prop)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.type=).*" {system,system/system}/build*.prop)

release=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.release=).*" {my_manifest,vendor,system,system/system}/build*.prop)
[[ -z ${release} ]] && release=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.release=).*" vendor/build*.prop)
[[ -z ${release} ]] && release=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.release=).*" {system,system/system}/build*.prop)
release=$(echo "$release" | head -1)

id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" my_manifest/build*.prop)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" system/system/build_default.prop)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" {vendor,system,system/system}/build*.prop)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.id=).*" vendor/build*.prop)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.id=).*" {system,system/system}/build*.prop)
id=$(echo "$id" | head -1)

incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" my_manifest/build*.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" system/system/build_default.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" my_manifest/build*.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" vendor/build*.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.incremental=).*" {system,system/system}/build*.prop | head -1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.incremental=).*" my_product/build*.prop)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" my_product/build*.prop)
incremental=$(echo "$incremental" | head -1)

tags=$(rg -m1 -INoP --no-messages "(?<=^ro.build.tags=).*" {vendor,system,system/system}/build*.prop)
[[ -z ${tags} ]] && tags=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.tags=).*" vendor/build*.prop)
[[ -z ${tags} ]] && tags=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.tags=).*" {system,system/system}/build*.prop)
tags=$(echo "$tags" | head -1)

platform=$(rg -m1 -INoP --no-messages "(?<=^ro.board.platform=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${platform} ]] && platform=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.board.platform=).*" vendor/build*.prop)
[[ -z ${platform} ]] && platform=$(rg -m1 -INoP --no-messages rg"(?<=^ro.system.board.platform=).*" {system,system/system}/build*.prop)
platform=$(echo "$platform" | head -1)

manufacturer=$(grep -oP "(?<=^ro.product.odm.manufacturer=).*" odm/etc/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" odm/etc/fingerprint/build.default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" system/system/euclid/my_product/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.manufacturer=).*" vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" vendor/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.system.product.manufacturer=).*" {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.manufacturer=).*" {system,system/system}/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" my_manifest/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" system/system/build_default.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" vendor/odm/etc/build*.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.system.product.manufacturer=).*" vendor/euclid/*/build.prop)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.manufacturer=).*" vendor/euclid/product/build*.prop)
manufacturer=$(echo "$manufacturer" | head -1)

fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.odm.build.fingerprint=).*" odm/etc/*build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" my_manifest/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" system/system/build_default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" odm/etc/fingerprint/build.default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" vendor/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" my_manifest/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" system/system/build_default.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.fingerprint=).*" product/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.fingerprint=).*" {system,system/system}/build*.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.fingerprint=).*" my_product/build.prop)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" my_product/build.prop)
fingerprint=$(echo "$fingerprint" | head -1)

codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.device=).*" odm/etc/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.device=).*" system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" odm/etc/fingerprint/build.default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" my_manifest/build*.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device=).*" system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device=).*" vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" vendor/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device.oem=).*" odm/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device.oem=).*" vendor/euclid/odm/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" my_manifest/build*.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" {system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" system/system/build_default.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.model=).*" vendor/euclid/*/build.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" oppo_product/build*.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" my_product/build*.prop)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fota.version=).*" {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.build.product=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${codename} ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)
[[ -z $codename ]] && {
	echo "Codename not detected! Aborting!"
	terminate 1
}

brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" odm/etc/"${codename}"_build.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" odm/etc/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" odm/etc/fingerprint/build.default.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" {vendor,system,system/system}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" system/system/euclid/my_product/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" my_manifest/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" system/system/build_default.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.brand=).*" vendor/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.brand=).*" {system,system/system}/build*.prop | head -1)
[[ -z ${brand} || ${brand} == "OPPO" ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.brand=).*" vendor/euclid/*/build.prop | head -1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.brand=).*" vendor/euclid/product/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" my_manifest/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" vendor/euclid/my_manifest/build.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" vendor/odm/etc/build*.prop)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" {oppo_product,my_product}/build*.prop | head -1)
[[ -z ${brand} ]] && brand=$(echo "$fingerprint" | cut -d / -f1)
[[ -z ${brand} ]] && brand="$manufacturer"

description=$(rg -m1 -INoP --no-messages "(?<=^ro.build.description=).*" {system,system/system}/build.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.build.description=).*" {system,system/system}/build*.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.description=).*" vendor/build.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.description=).*" vendor/build*.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.description=).*" product/build.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.description=).*" product/build*.prop)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.description=).*" {system,system/system}/build*.prop)
[[ -z ${description} ]] && description="$flavor $release $id $incremental $tags"

is_ab=$(rg -m1 -INoP --no-messages "(?<=^ro.build.ab_update=).*" {system,system/system,vendor}/build*.prop)
is_ab=$(echo "$is_ab" | head -1)
[[ -z ${is_ab} ]] && is_ab="false"

codename=$(echo "$codename" | tr ' ' '_')

if [ -z "$oplus_pipeline_key" ]; then
	branch=$(echo "$description" | head -1 | tr ' ' '-')
else
	branch=$(echo "$description"--"$oplus_pipeline_key" | head -1 | tr ' ' '-')
fi

repo_subgroup=$(echo "$brand" | tr '[:upper:]' '[:lower:]')
[[ -z $repo_subgroup ]] && repo_subgroup=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]')
repo_name=$(echo "$codename" | tr '[:upper:]' '[:lower:]')
repo="$repo_subgroup/$repo_name"
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)

echo "All props extracted."

printf "%s\n" "flavor: ${flavor}
release: ${release}
id: ${id}
incremental: ${incremental}
tags: ${tags}
oplus_pipeline_key: ${oplus_pipeline_key}
fingerprint: ${fingerprint}
brand: ${brand}
codename: ${codename}
description: ${description}
branch: ${branch}
repo: ${repo}
manufacturer: ${manufacturer}
platform: ${platform}
top_codename: ${top_codename}
is_ab: ${is_ab}"

# Generate device tree ('aospdtgen')
mkdir -p aosp-device-tree

echo "[INFO] Generating device tree..."
if python3 -m aospdtgen . --output ./aosp-device-tree >/dev/null; then
	echo "Device tree successfully generated."
else
	echo "[ERROR] Failed to generate device tree."
fi

# Generate 'all_files.txt'
echo "[INFO] Generating 'all_files.txt'..."
find . -type f ! -name all_files.txt -and ! -path "*/aosp-device-tree/*" -printf '%P\n' | sort | grep -v ".git/" >./all_files.txt

# Check whether the subgroup exists or not
if ! group_id_json="$(curl --compressed -sH --fail-with-body "Authorization: Bearer $DUMPER_TOKEN" "https://$GITLAB_SERVER/api/v4/groups/$ORG%2f$repo_subgroup")"; then
	echo "Response: $group_id_json"
	if ! group_id_json="$(curl --compressed -sH --fail-with-body "Authorization: Bearer $DUMPER_TOKEN" "https://$GITLAB_SERVER/api/v4/groups" -X POST -F name="${repo_subgroup^}" -F parent_id=64 -F path="${repo_subgroup}" -F visibility=public)"; then
		echo "Creating subgroup for $repo_subgroup failed"
		echo "Response: $group_id_json"
	fi
fi

if ! group_id="$(jq '.id' -e <<<"${group_id_json}")"; then
	echo "Unable to get gitlab group id"
	terminate 1
fi

# Create the repo if it doesn't exist
project_id_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$ORG%2f$repo_subgroup%2f$repo_name")"
if ! project_id="$(jq .id -e <<<"${project_id_json}")"; then
	project_id_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects" -X POST -F namespace_id="$group_id" -F name="$repo_name" -F visibility=public)"
	if ! project_id="$(jq .id -e <<<"${project_id_json}")"; then
		echo "Could get get project id"
		terminate 1
	fi
fi

branch_json="$(curl --compressed -sH "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$project_id/repository/branches/$branch")"
[[ "$(jq -r '.name' -e <<<"${branch_json}")" == "$branch" ]] && {
	echo "$branch already exists in $repo"
	terminate 2
}

# Add, commit, and push after filtering out certain files
git init --initial-branch "$branch"
git config user.name "Kizziama"
git config user.email "kizziama@proton"

## Committing
echo "[INFO] Adding files and committing..."
git add --ignore-errors -A >>/dev/null 2>&1
git commit --quiet --signoff --message="$description" || {
	echo "[ERROR] Committing failed!"
	terminate 1
}

## Pushing
echo "[INFO] Pushing..."
git push "git@$GITLAB_SERVER:$ORG/$repo.git" HEAD:refs/heads/"$branch" || {
	echo "[ERROR] Pushing failed!"
	terminate 1
}

# Set default branch to the newly pushed branch
curl --compressed -s -H "Authorization: bearer ${DUMPER_TOKEN}" "https://$GITLAB_SERVER/api/v4/projects/$project_id" -X PUT -F default_branch="$branch" >/dev/null

echo -e "[INFO] Sending Telegram notification"
tg_html_text="<b>Brand</b>: <code>$brand</code>
<b>Device</b>: <code>$codename</code>
<b>Version</b>: <code>$release</code>
<b>Fingerprint</b>: <code>$fingerprint</code>
<b>Platform</b>: <code>$platform</code>
[<a href=\"https://$GITLAB_SERVER/$ORG/$repo/tree/$branch/\">repo</a>] $link"

# Send message to Telegram channel
curl --compressed -s "https://api.telegram.org/bot${BOT_TOKEN}/sendmessage" --data "text=${tg_html_text}&chat_id=@hopireika_dump&parse_mode=HTML&disable_web_page_preview=True" >/dev/null

terminate 0

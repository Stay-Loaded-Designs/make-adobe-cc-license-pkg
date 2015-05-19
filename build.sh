#!/bin/bash -e
#
# Adobe Creative Cloud Packager offers an option: "Create License File", but does not make
# it obvious about how to deploy the license activation, and no support for deactivating the
# license (the RemoveVolumeLicense tool output by CCP is useful only for Enterprise agreements).
#
# This script builds an installer package given only the 'prov.xml' file output by CCP, packaging
# the 'adobe_prtk' executable and adding a postinstall script to perform the activation. The
# package is then imported using Munki. An uninstall script is also generated to do the
# deactivation (also using adobe_prtk), and the resultant Munki pkginfo uses this script for the
# uninstall.
#
# Requirements:
# 1) A copy of the adobe_prtk executable, which is installed as part of Adobe's
#    Creative Cloud Packager. adobe_prtk will be searched in this directory,
#    or if not found, its installation path (alongside CCP) will be searched:
#    /Applications/Utilities/Adobe Application Manager/CCP/utilities/APTEE/adobe_prtk
# 2) A prov.xml file, output from the "Create License File" task in CCP.
#
# Usage:
# Run the command with a single argument: path to a prov.xml file, and several configuration
# variables given as environment variables: PKGNAME, MUNKI_REPO_SUBDIR, REVERSE_DOMAIN
#
# One additional optional variable: VERSION, which if not set will be: YYYY.MM.DD
#
# PKGNAME=MyAdobeLicensePkgName \
# MUNKI_REPO_SUBDIR=apps/AdobeCC \
# REVERSE_DOMAIN=org.my \
# ./build.sh path/to/prov.xml

missing_env_msg="This environment variable must be set!"
PKGNAME=${PKGNAME:?$missing_env_msg}
VERSION=${VERSION:-$(date "+%Y.%m.%d")}
MUNKI_REPO_SUBDIR=${MUNKI_REPO_SUBDIR:?$missing_env_msg}
REVERSE_DOMAIN=${REVERSE_DOMAIN:?$missing_env_msg}

if [ -z $1 ]; then
	>&2 echo "This script takes a single argument: path to a prov.xml file generated by CCP."
	exit 1
fi

CCP_PRTK="/Applications/Utilities/Adobe Application Manager/CCP/utilities/APTEE/adobe_prtk"
prov_path="${1}"
if [ ! -e "${prov_path}" ]; then
	>&2 echo "Couldn't find prov file at ${prov_path}!"
	exit 1
fi

prtk_path=adobe_prtk
if [ ! -x "${prtk_path}" ]; then
	echo "adobe_prtk not found in current directory, trying CCP installation path.."
	if [ ! -x "${CCP_PRTK}" ]; then
		>&2 echo "No adobe_prtk found! Either install CCP or copy adobe_prtk to this script's directory."
		exit 1
	fi
	prtk_path="${CCP_PRTK}"
fi

leid=$(xpath "${prov_path}" 'string(/Provisioning/CustomOverrides/@leid)' 2> /dev/null)
if [ -z "${leid}" ]; then
	>&2 "Error reading LEID from ${prov_path}."
	exit 1
fi
echo "Found LEID "${leid}" from ${prov_path}"

# print out adobe_prtk's Info.plist and try to read the version
prtk_info=$(mktemp /tmp/prtkXXXX)
otool -P -X "${prtk_path}" > "${prtk_info}"
prtk_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${prtk_info}")


# Setup pkg working dirs
rm -rf root
rm -rf Scripts && mkdir Scripts
rm -f *.pkg
mkdir -p "root/usr/local/bin/adobe_prtk_${prtk_version}"
mkdir -p "root/private/tmp"

# Copy adobe_prtk and the prov file to the pkg payload
cp adobe_prtk "root/usr/local/bin/adobe_prtk_${prtk_version}"
cp "${prov_path}" root/private/tmp/

# Make an installer script to be run as part of the pkg install
cat > Scripts/postinstall << EOF
#!/bin/sh

"/usr/local/bin/adobe_prtk_${prtk_version}/adobe_prtk" \
	--tool=GetPackagePools \
	--tool=VolumeSerialize \
	--stream \
	--provfile=/private/tmp/prov.xml
rm /private/tmp/prov.xml
EOF
chmod a+x Scripts/postinstall

# Build the pkg
identifier="${REVERSE_DOMAIN}.${PKGNAME}"
pkgbuild --root root \
	--identifier "${identifier}" \
	--version "${VERSION}" \
	--scripts Scripts \
	"${PKGNAME}-${VERSION}.pkg"
rm -rf root Scripts


# Make an uninstaller script to handle deactivation
# another option to consider for adobe_prtk here: --removeSWTag
# the swid tags should be installed by the actual CC product installer
# so we probably don't want the licensing tool handling this part
#
# Uninstaller script only runs the deactivation and forgets the pkg,
# but leaves the versioned adobe_prtk tool, in case of errors and further
# diagnosis is required on the machine. The prov.xml file was already
# removed by the postinstall script.
uninstall_script_path=$(mktemp /tmp/CCXXXX)
cat > "${uninstall_script_path}" << EOF
#!/bin/sh
"/usr/local/bin/adobe_prtk_${prtk_version}/adobe_prtk" \\
	--tool=UnSerialize \\
	--leid="${leid}" \\
	--deactivate
	/usr/sbin/pkgutil --forget "${identifier}"
EOF


# Import it to MUNKI_REPO_SUBDIR, also passing our uninstall_script
pkg_path=$(find . -name '*.pkg')
munkiimport --nointeractive \
	--subdirectory "${MUNKI_REPO_SUBDIR}" \
	--uninstall-method uninstall_script \
	--uninstall-script "${uninstall_script_path}" \
	"${pkg_path}"

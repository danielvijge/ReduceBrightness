#!/bin/sh

# Build screensaverfix patch for a specific Logitech Media Server (Squeezebox) version.

# LMS version to build for
VERSION="7.8"
# Patch version
PATCH_VERSION="1.1"

mkdir -p screensaverfix-$PATCH_VERSION
echo '*' > screensaverfix-$PATCH_VERSION/.gitignore

echo 'Building patch...'

git diff public/$VERSION ../src/squeezeplay/share/applets/ScreenSavers/* > screensaverfix-$PATCH_VERSION/screensaverfix-$PATCH_VERSION.patch

cd screensaverfix-$PATCH_VERSION
sed 's/--- a\/src\/squeezeplay\/share\//--- share\/jive\//g' screensaverfix-$PATCH_VERSION.patch > screensaverfix.patch.tmp
mv screensaverfix.patch.tmp screensaverfix-$PATCH_VERSION.patch
sed 's/+++ b\/src\/squeezeplay\/share\//+++ share\/jive\//g' screensaverfix-$PATCH_VERSION.patch > screensaverfix.patch.tmp
mv screensaverfix.patch.tmp screensaverfix-$PATCH_VERSION.patch

CHECKSUM=`shasum screensaverfix-$PATCH_VERSION.patch | awk '{print $1}'`

# Copy base XML file to output directory
cp ../repo-beta.xml repo-beta.xml

# Replace placeholder with proper checksum
sed 's/%CHECKSUM%/'${CHECKSUM}'/g' repo-beta.xml > repo-beta.xml.tmp
mv repo-beta.xml.tmp repo-beta.xml

# Replace placeholder with proper file name
sed 's/%PATCH%/screensaverfix-'${PATCH_VERSION}'.patch/g' repo-beta.xml > repo-beta.xml.tmp
mv repo-beta.xml.tmp repo-beta.xml

# Replace version info
sed 's/%VERSION%/'${VERSION}'/g' repo-beta.xml > repo-beta.xml.tmp
mv repo-beta.xml.tmp repo-beta.xml
sed 's/%PATCH_VERSION%/'${PATCH_VERSION}'/g' repo-beta.xml > repo-beta.xml.tmp
mv repo-beta.xml.tmp repo-beta.xml
cd ..

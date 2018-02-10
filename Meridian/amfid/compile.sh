#!/bin/sh

export PATH="$PATH:$HOME/bin"

currDir=$(dirname $0)

cd $currDir

xcrun -sdk iphoneos gcc -dynamiclib -arch arm64 -framework Foundation -o $currDir/amfid_payload.dylib $currDir/amfid_payload.m
jtool --sign sha1 --inplace $currDir/amfid_payload.dylib
chmod 0755 $currDir/amfid_payload.dylib

xcrun -sdk iphoneos gcc -arch arm64 -framework Foundation -o $currDir/amfid_fucker $currDir/amfid_fucker.m
jtool --sign sha1 --inplace --ent $currDir/ent.plist $currDir/amfid_fucker
chmod 0755 $currDir/amfid_fucker
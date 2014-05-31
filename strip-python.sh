#!/bin/sh
# Copies the Python Lib directory and strips it down to a reasonable size.
# FontForge essentially ships with its own version of Python

PYVER=python3.4
PYDIR=/$MSYSTEM/lib/$PYVER

cd original-archives/binaries

if [ ! -d $PYVER ]; then
	cp -r $PYDIR .
fi

cd $PYVER
rm -rfv config-3.4m idlelib test turtledemo 
find . -name __pycache__ | xargs rm -rfv
find . -name test | xargs rm -rfv
find . -name tests | xargs rm -rfv
cd ..

cd ../..

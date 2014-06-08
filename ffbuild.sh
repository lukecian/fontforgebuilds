#!/bin/sh
# FontForge build script.
# Uses MSYS2/MinGW-w64
# Author: Jeremy Tan
# Usage: ffbuild.sh [--reconfigure]
# --reconfigure     Forces the configure script to be rerun for the currently 
#                   worked-on package.
#
# This script retrieves and installs all libraries required to build FontForge.
# It then attempts to compile the latest version of FontForge, and to 
# subsequently make a redistributable package.

# Retrieve input arguments to script
reconfigure="$1"

# Colourful text
# Red text
function log_error() {
    echo -e "\e[31m$@\e[0m"
}

# Yellow text
function log_status() {
    echo -e "\e[33m$@\e[0m"
}

# Green text
function log_note() {
    echo -e "\e[32m$@\e[0m"
}

function bail () {
    echo -e "\e[31m\e[1m!!! Build failed at: ${@}\e[0m"
    exit 1
}

# Preamble
log_note "MSYS2 FontForge build script..."

# Set working folders
BASE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PATCH=$BASE/patches
WORK=$BASE/work
UIFONTS=$BASE/ui-fonts
SOURCE=$BASE/original-archives/sources/
BINARY=$BASE/original-archives/binaries/
RELEASE=$BASE/ReleasePackage/
DBSYMBOLS=$BASE/debugging-symbols/.debug/

# Determine if we're building 32 or 64 bit.
if [ "$MSYSTEM" = "MINGW32" ]; then
	log_note "Building 32-bit version!"
	MINGVER=mingw32
	HOST="--build=i686-w64-mingw32 --host=i686-w64-mingw32 --target=i686-w64-mingw32"
	PMPREFIX="mingw-w64-i686"
	PYINST=python2
	PYVER=python2.7
	VCXSRV="VcXsrv-1.14.2-minimal.tar.bz2"
	POTRACE_DIR="potrace-1.11.win32"
	POTRACE_ARC="$POTRACE_DIR.tar.gz"
	
	#Patches
	PATCH_LIBX11="libx11.patch"
elif [ "$MSYSTEM" = "MINGW64" ]; then
	log_note "Building 64-bit version!"
	MINGVER=mingw64
	HOST="--build=x86_64-w64-mingw32 --host=x86_64-w64-mingw32 --target=x86_64-w64-mingw32"
	PMPREFIX="mingw-w64-x86_64"
	PYINST=python3
	PYVER=python3.4
	VCXSRV="VcXsrv-1.15.0.2-x86_64-minimal.tar.bz2"
	POTRACE_DIR="potrace-1.11.win64"
	POTRACE_ARC="$PORTACE_DIR.tar.gz"
	
	#Patches
	PATCH_XPROTO="64bit-xproto.patch"
	PATCH_LIBX11="64bit-libx11.patch"
else 
	bail "Unknown build system!"
fi

#Common options
INSPREFIX="--prefix /$MINGVER"
AMPREFIX="-I /$MINGVER/share/aclocal"
HOST="$HOST $INSPREFIX"


# Set pkg-config path to also search mingw libs
export PKG_CONFIG_PATH=/$MINGVER/share/pkgconfig:/$MINGVER/lib/pkgconfig:/usr/local/lib/pkgconfig:/lib/pkgconfig:/usr/local/share/pkgconfig
# Compiler flags
export LDFLAGS="-L/$MINGVER/lib -L/usr/local/lib -L/lib" 
export CFLAGS="-DWIN32 -I/$MINGVER/include -I/usr/local/include -I/include -g"
export CPPFLAGS="${CFLAGS}"
export LIBS=""

# Make the output directories
mkdir -p "$WORK"
mkdir -p "$RELEASE/bin"
mkdir -p "$RELEASE/lib"
mkdir -p "$RELEASE/share"
mkdir -p "$DBSYMBOLS"

# Install all the available precompiled binaries
if [ ! -f $BASE/.pacman-installed ]; then
    log_status "First time run; installing MSYS and MinGW libraries..."

    # Add the mingw repository and update pacman.
    # Also updates all packages to the latest.
    # Not needed anymore with latest version of MSYS2
    # cp -f $PATCH/pacman.conf /etc/
    pacman -Sy --noconfirm

    IOPTS="-S --noconfirm --needed"
    # Install the base MSYS packages needed
    pacman $IOPTS diffutils findutils gawk liblzma m4 make patch tar xz git binutils

    ## Automake stuff
    pacman $IOPTS automake autoconf pkg-config

    ## Other libs
    pacman $IOPTS $PMPREFIX-$PYINST $PMPREFIX-openssl # libxslt docbook-xml docbook-xsl

    # Install MinGW related stuff
    pacman $IOPTS $PMPREFIX-gcc $PMPREFIX-gcc-fortran $PMPREFIX-gmp
    pacman $IOPTS $PMPREFIX-gettext $PMPREFIX-libiconv $PMPREFIX-libtool

    log_status "Installing precompiled devel libraries..."

    # Libraries
    pacman $IOPTS $PMPREFIX-zlib $PMPREFIX-libpng $PMPREFIX-giflib $PMPREFIX-libtiff
    pacman $IOPTS $PMPREFIX-libjpeg-turbo $PMPREFIX-libxml2 $PMPREFIX-freetype
    pacman $IOPTS $PMPREFIX-fontconfig $PMPREFIX-glib2
    pacman $IOPTS $PMPREFIX-harfbuzz $PMPREFIX-gc #BDW Garbage collector

    touch $BASE/.pacman-installed
    log_note "Finished installing precompiled libraries!"
else
    log_note "Detected that precompiled libraries are already installed."
    log_note "  Delete '$BASE/.pacman-installed' and run this script again if"
    log_note "  this is not the case."
fi # pacman installed

# Install from tarball
# install_source_raw(file, folder_name, patch, configflags, premakeflags, postmakeflags)
function install_source_patch () {
    local file=$1
    local folder=$2
    local patch=$3
    local configflags=$4
    local premakeflags=$5
    local postmakeflags=$6
    
    # Default to the name of the archive, if folder name is not given
    if [ -z "$folder" ]; then
        local filename="$(basename $1)"
        folder="${filename%.tar*}"
    fi
    
    cd $WORK
    if [ ! -f "$folder/$folder.complete"  ]; then
        log_status "Installing $folder..."
        if [ ! -d "$folder" ]; then
            tar axvf $SOURCE$file || bail "$folder"
        else
            log_note "Sensing incomplete build, re-attempting the build..."
        fi
        
        cd $folder || bail "$folder"
        if [ ! -z $patch ]; then
            log_status "Patching $folder with $patch..."
            # Check if it's already been applied or not
            patch -p1 -N --dry-run --silent < $PATCH/$patch 2>/dev/null
            if [ $? -eq 0 ]; then
                patch -p1 < $PATCH/$patch || bail "$folder"
            else
                log_note "Sensed that patch has already been applied; skipping"
            fi
        fi
        
        if [ ! -f "$folder.configure-complete" ] || [ "$reconfigure" = "--reconfigure" ]; then
            log_status "Running the configure script..."
            ./configure $HOST $configflags || bail "$folder"
            touch "$folder.configure-complete"
        else
            log_note "Sensed that the configure script has already run; delete $folder.configure-complete to rerun configure"
        fi
        cmd="$premakeflags make -j4 $postmakeflags || bail '$folder'"
        log_note "$cmd"
        eval "$cmd"
        make install || bail "$folder"
        log_status "Installation complete!"
        
        touch "$folder.complete"
        cd ..
    fi
}

# install_source(file, folder_name, configflags, premakeflags, postmakeflags)
function install_source () {
    install_source_patch "$1" "$2" "" "${@:3}"
}

# install_source(git_link, folder_name, custom_configgen, patchfile, configflags, premakeflags, postmakeflags)
function install_git_source () {
    cd $WORK
    
    log_status "Attempting git install of $2..."
    if [ ! -d "$2" ]; then
        log_status "Cloning git repository from $1..."
        git clone "$1" "$2" || bail "Git clone of $1"
        cd "$2"
		
		if [ ! -z "$4" ]; then
			log_status "Patching the repository..."
			git apply "$PATCH/$4"
		fi
    else
        cd "$2"
        #log_status "Attempting update of git repository..."
        #git pull --rebase || log_note "Failed to update. Unstaged changes?"
    fi
    
    if [ ! -f .gen-configure-complete ]; then
        log_status "Generating configure files..."
		libtoolize -i || bail "Failed to run libtoolize"
		
        if [ ! -z "$3" ]; then
			#X11 ignores the --prefix option, so...
			if [ "$3" = "--x11" ]; then
				autoreconf -fiv $AMPREFIX
			else
				eval "$3" || bail "Failed to generate makefiles"
			fi
        else
            ./autogen.sh $INSPREFIX || bail "Failed to autogen"
        fi
        touch .gen-configure-complete
    fi
    
    cd ..
    install_source "" "$2" "${@:5}"
    
}

log_status "Installing custom libraries..."
install_git_source "http://github.com/fontforge/libspiro" "libspiro" "autoreconf -i && automake --foreign -Wall"
install_git_source "http://github.com/fontforge/libuninameslist" "libuninameslist" "autoreconf -i && automake --foreign"

# X11 libraries
log_status "Installing X11 libraries..."

xproto=X.Org/proto
xlib=X.Org/lib
xcb=X.Org/xcb

install_git_source "git://anongit.freedesktop.org/xorg/util/macros" "util-macros" 
install_git_source "git://anongit.freedesktop.org/xorg/proto/x11proto" "x11proto" "--x11" "$PATCH_XPROTO"
install_git_source "git://anongit.freedesktop.org/xorg/proto/renderproto" "renderproto" "--x11"
#install_git_source "git://anongit.freedesktop.org/xorg/doc/xorg-sgml-doctools" "xorg-sgml-doctools" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/proto/bigreqsproto" "bigreqsproto" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/proto/kbproto" "kbproto" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/proto/inputproto" "inputproto" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/proto/xextproto" "xextproto" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/proto/xf86bigfontproto" "xf86bigfontproto" "--x11"
install_git_source "git://anongit.freedesktop.org/xcb/proto" "xcb-proto" "--x11"
#install_git_source "git://anongit.freedesktop.org/xcb/pthread-stubs" "xcb-pthread-stubs" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/lib/libXau" "libXau" "--x11"
install_git_source "git://anongit.freedesktop.org/xcb/libxcb" "libxcb" "--x11" "" \
"
LIBS=-lws2_32
--disable-composite
--disable-damage
--disable-dpms
--disable-dri2
--disable-dri3
--disable-glx
--disable-present
--disable-randr
--disable-record
--disable-render
--disable-resource
--disable-screensaver
--disable-shape
--disable-shm
--disable-sync
--disable-xevie
--disable-xfixes
--disable-xfree86-dri
--disable-xinerama
--disable-xinput
--disable-xprint
--disable-selinux
--disable-xtest
--disable-xv
--disable-xvmc
"
install_git_source "git://anongit.freedesktop.org/xorg/lib/libxtrans" "libxtrans" "--x11" "xtrans.patch"
install_git_source "git://anongit.freedesktop.org/xorg/lib/libX11" "libX11" "--x11" "" 
install_git_source "git://anongit.freedesktop.org/xorg/lib/libXrender" "libXrender" "--x11"
install_git_source "git://anongit.freedesktop.org/xorg/lib/libXft" "libXft" "--x11"

# Download from http://ftp.gnome.org/pub/gnome/sources/pango
log_status "Installing Pango..."
install_source pango-1.36.3.tar.xz "" "--with-xft --without-cairo"
#install_git_source "https://git.gnome.org/browse/pango" "pango" "--x11" "" "--with-xft"

# ZMQ does not work for now
#install_git_source "https://github.com/jedisct1/libsodium" "libsodium" "libtoolize -i && ./autogen.sh"
#install_git_source "https://github.com/zeromq/libzmq" "libzmq" "libtoolize -i && ./autogen.sh"
#install_git_source "https://github.com/zeromq/czmq" "czmq" "libtoolize -i && ./autogen.sh"


# VcXsrv_util
if [ ! -f VcXsrv_util/VcXsrv_util.complete ]; then
    log_status "Building VcXsrv_util..."
    mkdir -p VcXsrv_util
    cd VcXsrv_util
    gcc -Wall -O2 -municode \
        -o VcXsrv_util.exe "$PATCH/VcXsrv_util.c" \
    || bail "VcXsrv_util"
    touch VcXsrv_util.complete
    cd ..
fi

# run_fontforge
if [ ! -f run_fontforge/run_fontforge.complete ]; then
    log_status "Installing run_fontforge..."
    mkdir -p run_fontforge
    cd run_fontforge
    windres "$PATCH/run_fontforge.rc" -O coff -o run_fontforge.res
    gcc -Wall -O2 -mwindows -o run_fontforge.exe "$PATCH/run_fontforge.c" run_fontforge.res \
    || bail "run_fontforge"
    touch run_fontforge.complete
    cd ..
fi

# For the source only; to enable the debugger in FontForge
if [ ! -d freetype-2.5.3 ]; then
    log_status "Extracting the FreeType 2.5.3 source..."
    tar axvf "$SOURCE/freetype-2.5.3.tar.bz2" || bail "FreeType2 extraction"
fi

log_status "Finished installing prerequisites, attempting to install FontForge!"
cd $WORK

# fontforge
if [ ! -d fontforge ]; then
    log_status "Cloning the fontforge repository"
    git clone https://github.com/jtanx/fontforge || bail "Cloning fontforge"
    cd fontforge 
    git checkout win32 || bail "Checking out win32 branch"
else
    cd fontforge
fi

if [ ! -f fontforge.configure-complete ] || [ "$reconfigure" = "--reconfigure" ]; then
    log_status "Running the configure script..."
    
    if [ ! -f configure ]; then
        log_note "No configure script detected; running ./boostrap..."
        #./autogen.sh || bail "FontForge autogen"
        ./bootstrap || bail "FontForge autogen"
        #log_note "Patching lib files to use <fontforge-config.h>..."
        #sed -bi "s/<config\.h>/<fontforge-config.h>/" lib/*.c
    fi

    # libreadline is disabled because it causes issues when used from the command line (e.g Ctrl+C doesn't work)
    # windows-cross-compile to disable check for libuuid
    
    # Crappy hack to get around forward slash in path issues 
    #am_cv_python_pythondir=/usr/lib/python2.7/site-packages \
    #am_cv_python_pyexecdir=/usr/lib/python2.7/site-packages \
	PYTHON=$PYINST \
    ./configure $HOST \
        --enable-shared \
        --disable-static \
        --enable-windows-cross-compile \
        --datarootdir=/usr/share/share_ff \
        --without-cairo \
        --without-libzmq \
        --with-freetype-source="$WORK/freetype-2.5.3" \
        --without-libreadline \
        || bail "FontForge configure"
    touch fontforge.configure-complete
fi

log_status "Compiling FontForge..."
make -j 4	|| bail "FontForge make"

log_status "Installing FontForge..."
make -j 4 install || bail "FontForge install"

log_status "Assembling the release package..."
ffex=`which fontforge.exe`
fflibs=`ldd "$ffex" \
| grep dll \
| sed -e '/^[^\t]/ d'  \
| sed -e 's/\t//'  \
| sed -e 's/.*=..//'  \
| sed -e 's/ (0.*)//'  \
| sed -e '/^\/c/d' \
| sort  \
| uniq \
`

log_status "Copying the FontForge executable..."
strip "$ffex" -so "$RELEASE/bin/fontforge.exe"
objcopy --only-keep-debug "$ffex" "$DBSYMBOLS/fontforge.debug"
objcopy --add-gnu-debuglink="$DBSYMBOLS/fontforge.debug" "$RELEASE/bin/fontforge.exe"
#cp "$ffex" "$RELEASE/bin/"
log_status "Copying the libraries required by FontForge..."
for f in $fflibs; do
    filename="$(basename $f)"
	filenoext="${filename%.*}"
    strip "$f" -so "$RELEASE/bin/$filename"
	objcopy --only-keep-debug "$f" "$DBSYMBOLS/$filenoext.debug"
	objcopy --add-gnu-debuglink="$DBSYMBOLS/$filenoext.debug" "$RELEASE/bin/$filename"
	#cp "$f" "$RELEASE/bin/"
done

log_status "Copying the shared folder of FontForge..."
cp -rf /usr/share/share_ff/fontforge "$RELEASE/share/"
cp -rf /usr/share/share_ff/locale "$RELEASE/share/"
rm -f "$RELEASE/share/prefs"

log_note "Installing custom binaries..."
cd $WORK
# potrace - http://potrace.sourceforge.net/#downloading
if [ ! -f $RELEASE/bin/potrace.exe ]; then
    log_status "Installing potrace..."
    mkdir -p potrace
    cd potrace
	
    if [ ! -d $POTRACE_DIR ]; then
        tar axvf $BINARY/$POTRACE_ARC || bail "Potrace not found!"
    fi
    strip $POTRACE_DIR/potrace.exe -so $RELEASE/bin/potrace.exe
    cd ..
fi

#VcXsrv - Xming replacement
if [ ! -d $RELEASE/bin/VcXsrv ]; then
    log_status "Installing VcXsrv..."
    if [ ! -d VcXsrv ]; then
        tar axvf $BINARY/$VCXSRV || bail "VcXsrv not found!"
    fi
    cp -rf VcXsrv $RELEASE/bin/
fi

log_status "Installing VcXsrv_util..."
strip $WORK/VcXsrv_util/VcXsrv_util.exe -so "$RELEASE/bin/VcxSrv_util.exe" \
    || bail "VcxSrv_util"
log_status "Installing run_fontforge..."
strip $WORK/run_fontforge/run_fontforge.exe -so "$RELEASE/run_fontforge.exe" \
    || bail "run_fontforge"

log_status "Copying the Pango modules..."
cp -rf /$MINGVER/lib/pango "$RELEASE/lib"

log_status "Copying UI fonts..."
mkdir -p "$RELEASE/share/fonts"
cp "$UIFONTS"/* "$RELEASE/share/fonts/"
cp /usr/share/share_ff/fontforge/pixmaps/Cantarell* "$RELEASE/share/fonts"

log_status "Copying sfd icon..."
cp "$PATCH/artwork/sfd-icon.ico" "$RELEASE/share/fontforge/"

log_status "Copying the Python libraries..."
if [ -d "$RELEASE/lib/$PYVER" ]; then
    log_note "Skipping python library copy because folder already exists, and copying is slow."
else  
    cp -r "$BINARY/$PYVER" "$RELEASE/lib"
fi

log_status "Stripping Python cache files (*.pyc,*.pyo,__pycache__)..."
find "$RELEASE/lib/$PYVER" -regextype sed -regex ".*\.py[co]" | xargs rm -rfv
find "$RELEASE/lib/$PYVER" -name "__pycache__" | xargs rm -rfv

if [ "$MSYSTEM" = "MINGW32" ]; then
	log_status "Copying OpenSSL libraries (for Python hashlib)..."
	strip /$MINGVER/bin/libeay32.dll -so "$RELEASE/bin/libeay32.dll"
fi

log_status "Setting the git version number..."
version_hash=`git -C $WORK/fontforge rev-parse master`
current_date=`date "+%c %z"`
if [ ! -f $RELEASE/VERSION.txt ]; then
	printf "FontForge Windows build\r\n\r\ngit " > $RELEASE/VERSION.txt
fi

sed -bi "s/^git .*$/git $version_hash ($current_date).\r/g" $RELEASE/VERSION.txt

log_note "Build complete."















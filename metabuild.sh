#!/bin/bash

# Script to build and install XLibre and all modules in an Arch Linux chroot
# Run as a non-root user (e.g., builder) in a clean chroot: mkdir ~/XLibre && cd ~/XLibre

set -e

# Base directory
BASE_DIR="$HOME/XLibre"

# Repository directory
REPO_DIR="$BASE_DIR/xlibre-repo/x86_64"
mkdir -p "$REPO_DIR"

# Log files
LOG_FILE="$BASE_DIR/build-xlibre.log"
FAILED_BUILDS_LOG="$BASE_DIR/failed-builds.log"
SUCCESSFUL_BUILDS_LOG="$BASE_DIR/successful-builds.log"
touch "$LOG_FILE" "$FAILED_BUILDS_LOG" "$SUCCESSFUL_BUILDS_LOG"

# Version for all packages (update as needed)
PKGVER="21.1.99.1"
PKGREL="1"

# Function to log messages with timestamp to both terminal and main log file
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to log failed builds
log_failed_build() {
    local pkgname="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $pkgname" >> "$FAILED_BUILDS_LOG"
}

# Function to log successful builds
log_successful_build() {
    local pkgname="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $pkgname" >> "$SUCCESSFUL_BUILDS_LOG"
}

# Function to check and install required tools and dependencies
check_requirements() {
    log_message "Checking for required tools"
    local tools=(git makepkg pacman repo-add meson ninja autoconf automake pkgconf sed)
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_message "ERROR: $tool is not installed. Please install it in the chroot."
            exit 1
        fi
    done

    log_message "Checking for sudo access"
    if ! sudo -n true 2>/dev/null; then
        log_message "ERROR: User $USER requires sudo access without password for pacman."
        log_message "Add to /etc/sudoers: $USER ALL=(ALL) NOPASSWD: /usr/bin/pacman"
        exit 1
    fi
}

# Function to install dependencies for a PKGBUILD
install_pkgbuild_deps() {
    local pkgdir="$1"
    local pkgbuild="$pkgdir/PKGBUILD"
    if [ ! -f "$pkgbuild" ]; then
        log_message "ERROR: PKGBUILD not found in $pkgdir"
        return 1
    fi

    log_message "Installing dependencies for $pkgbuild"
    # Extract depends and makedepends arrays
    local deps
    deps=$(grep -E '^(depends|makedepends)=.*' "$pkgbuild" | \
           sed "s#.*=('##;s#').*##;s#' '# #g" | tr ' ' '\n' | sort -u)
    
    if [ -z "$deps" ]; then
        log_message "No dependencies found in $pkgbuild"
        return 0
    fi

    # Install dependencies
    log_message "Installing dependencies: $deps"
    for dep in $deps; do
        if [ "$dep" = "xlibre-server" ]; then
            local subpkgs=("xlibre-server" "xlibre-server-common" "xlibre-server-xvfb" "xlibre-server-xwayland" "xlibre-server-xnest")
            for subpkg in "${subpkgs[@]}"; do
                local pkgfile="$REPO_DIR/$subpkg-$PKGVER-$PKGREL-x86_64.pkg.tar.zst"
                if [ -f "$pkgfile" ]; then
                    log_message "Installing $subpkg from local repository"
                    if ! sudo pacman -U --noconfirm "$pkgfile" >> "$LOG_FILE" 2>&1; then
                        log_message "ERROR: Failed to install $subpkg from $pkgfile. Check $LOG_FILE"
                        return 1
                    fi
                else
                    log_message "ERROR: $subpkg package not found in $REPO_DIR"
                    return 1
                fi
            done
        else
            if ! sudo pacman -S --needed --noconfirm "$dep" >> "$LOG_FILE" 2>&1; then
                log_message "ERROR: Failed to install dependency $dep for $pkgbuild. Check $LOG_FILE"
                return 1
            fi
        fi
    done
    log_message "Successfully installed dependencies for $pkgbuild"
    return 0
}

# Function to check if a package is already built and installed
check_package_built() {
    local pkgname="$1"
    local pkgfile
    if [ "$pkgname" = "xlibre-server" ]; then
        for subpkg in xlibre-server xlibre-server-common xlibre-server-xvfb xlibre-server-xwayland xlibre-server-xnest; do
            pkgfile="$REPO_DIR/$subpkg-$PKGVER-$PKGREL-x86_64.pkg.tar.zst"
            if [ ! -f "$pkgfile" ] || ! pacman -Q "$subpkg" >/dev/null 2>&1; then
                return 1
            fi
        done
        return 0
    else
        pkgfile="$REPO_DIR/$pkgname-$PKGVER-$PKGREL-x86_64.pkg.tar.zst"
        [ -f "$pkgfile" ] && pacman -Q "$pkgname" >/dev/null 2>&1
    fi
}

# Function to clean failed build artifacts
clean_failed_build() {
    local pkgdir="$1"
    log_message "Cleaning failed build artifacts in $pkgdir"
    rm -rf "$pkgdir/src" "$pkgdir/pkg" "$pkgdir"/*.tar.* "$pkgdir"/*.log
    log_message "Cleanup complete for $pkgdir"
}

# List of repositories (core server + drivers + meta-package)
declare -A REPOS=(
    ["xlibre-server"]="https://github.com/X11Libre/xserver"
    ["xlibre-base"]="meta"
    ["xlibre-input-elographics"]="https://github.com/X11Libre/xf86-input-elographics"
    ["xlibre-input-evdev"]="https://github.com/X11Libre/xf86-input-evdev"
    ["xlibre-input-joystick"]="https://github.com/X11Libre/xf86-input-joystick"
    ["xlibre-input-keyboard"]="https://github.com/X11Libre/xf86-input-keyboard"
    ["xlibre-input-libinput"]="https://github.com/X11Libre/xf86-input-libinput"
    ["xlibre-input-mouse"]="https://github.com/X11Libre/xf86-input-mouse"
    ["xlibre-input-synaptics"]="https://github.com/X11Libre/xf86-input-synaptics"
    ["xlibre-input-vmmouse"]="https://github.com/X11Libre/xf86-input-vmmouse"
    ["xlibre-video-amdgpu"]="https://github.com/X11Libre/xf86-video-amdgpu"
    ["xlibre-video-apm"]="https://github.com/X11Libre/xf86-video-apm"
    ["xlibre-video-ark"]="https://github.com/X11Libre/xf86-video-ark"
    ["xlibre-video-ast"]="https://github.com/X11Libre/xf86-video-ast"
    ["xlibre-video-ati"]="https://github.com/X11Libre/xf86-video-ati"
    ["xlibre-video-chips"]="https://github.com/X11Libre/xf86-video-chips"
    ["xlibre-video-cirrus"]="https://github.com/X11Libre/xf86-video-cirrus"
    ["xlibre-video-dummy"]="https://github.com/X11Libre/xf86-video-dummy"
    ["xlibre-video-fbdev"]="https://github.com/X11Libre/xf86-video-fbdev"
    ["xlibre-video-freedreno"]="https://github.com/X11Libre/xf86-video-freedreno"
    ["xlibre-video-geode"]="https://github.com/X11Libre/xf86-video-geode"
    ["xlibre-video-i128"]="https://github.com/X11Libre/xf86-video-i128"
    ["xlibre-video-i740"]="https://github.com/X11Libre/xf86-video-i740"
    ["xlibre-video-intel"]="https://github.com/X11Libre/xf86-video-intel"
    ["xlibre-video-mach64"]="https://github.com/X11Libre/xf86-video-mach64"
    ["xlibre-video-mga"]="https://github.com/X11Libre/xf86-video-mga"
    ["xlibre-video-neomagic"]="https://github.com/X11Libre/xf86-video-neomagic"
    ["xlibre-video-nested"]="https://github.com/X11Libre/xf86-video-nested"
    ["xlibre-video-nouveau"]="https://github.com/X11Libre/xf86-video-nouveau"
    ["xlibre-video-nv"]="https://github.com/X11Libre/xf86-video-nv"
    ["xlibre-video-omap"]="https://github.com/X11Libre/xf86-video-omap"
    ["xlibre-video-qxl"]="https://github.com/X11Libre/xf86-video-qxl"
    ["xlibre-video-r128"]="https://github.com/X11Libre/xf86-video-r128"
    ["xlibre-video-rendition"]="https://github.com/X11Libre/xf86-video-rendition"
    ["xlibre-video-s3virge"]="https://github.com/X11Libre/xf86-video-s3virge"
    ["xlibre-video-savage"]="https://github.com/X11Libre/xf86-video-savage"
    ["xlibre-video-siliconmotion"]="https://github.com/X11Libre/xf86-video-siliconmotion"
    ["xlibre-video-sis"]="https://github.com/X11Libre/xf86-video-sis"
    ["xlibre-video-sisusb"]="https://github.com/X11Libre/xf86-video-sisusb"
    ["xlibre-video-suncg14"]="https://github.com/X11Libre/xf86-video-suncg14"
    ["xlibre-video-suncg6"]="https://github.com/X11Libre/xf86-video-suncg6"
    ["xlibre-video-sunffb"]="https://github.com/X11Libre/xf86-video-sunffb"
    ["xlibre-video-sunleo"]="https://github.com/X11Libre/xf86-video-sunleo"
    ["xlibre-video-suntcx"]="https://github.com/X11Libre/xf86-video-suntcx"
    ["xlibre-video-tdfx"]="https://github.com/X11Libre/xf86-video-tdfx"
    ["xlibre-video-trident"]="https://github.com/X11Libre/xf86-video-trident"
    ["xlibre-video-v4l"]="https://github.com/X11Libre/xf86-video-v4l"
    ["xlibre-video-vesa"]="https://github.com/X11Libre/xf86-video-vesa"
    ["xlibre-video-vmware"]="https://github.com/X11Libre/xf86-video-vmware"
    ["xlibre-video-voodoo"]="https://github.com/X11Libre/xf86-video-voodoo"
    ["xlibre-video-wsfb"]="https://github.com/X11Libre/xf86-video-wsfb"
    ["xlibre-video-xgi"]="https://github.com/X11Libre/xf86-video-xgi"
)

# Function to create PKGBUILD for core server
create_server_pkgbuild() {
    local pkgdir="$1"
    mkdir -p "$pkgdir"
    log_message "Creating PKGBUILD for xlibre-server in $pkgdir"
    cat > "$pkgdir/PKGBUILD" << EOF
# Maintainer: Your Name <your.email@example.com>
pkgname=(xlibre-server xlibre-server-common xlibre-server-xvfb xlibre-server-xwayland xlibre-server-xnest)
pkgver=$PKGVER
pkgrel=$PKGREL
pkgdesc="XLibre X11 server (fork of Xorg)"
arch=('x86_64')
url="https://github.com/X11Libre/xserver"
license=('MIT')
options=('!debug')
depends=('libx11' 'xorgproto' 'libxkbfile' 'libxfont2' 'mesa' 'libxcvt' 'pixman' 'dbus' 'systemd-libs')
makedepends=('git' 'meson' 'ninja' 'autoconf' 'automake' 'pkgconf' 'xorgproto' 'libx11' 'libxkbfile' 'libxfont2' 'mesa' 'libxcvt' 'pixman' 'xtrans' 'xorg-font-util' 'wayland-protocols' 'libepoxy' 'nettle' 'libtirpc' 'libdrm' 'libpciaccess' 'python' 'wayland' 'libxshmfence' 'libunwind' 'libxau' 'libxdmcp' 'libxext' 'libxrender' 'libxrandr' 'libxfixes' 'libxdamage' 'libxcomposite' 'libxinerama' 'libxv' 'libxvmc' 'xcb-util' 'xcb-util-wm' 'xcb-util-keysyms')
source=("git+https://github.com/X11Libre/xserver.git")
sha256sums=('SKIP')

prepare() {
    cd xserver
    # Apply patches if needed
}

build() {
    cd xserver
    if [ -f meson.build ]; then
        echo "Using Meson build system" >&2
        meson setup build \
            --prefix=/usr \
            --libexecdir=/usr/lib \
            -Dxvfb=true \
            -Dxwayland=true \
            -Dxnest=true \
            -Dxdmcp=true
        ninja -C build
    else
        echo "Using Autotools build system" >&2
        ./autogen.sh
        ./configure --prefix=/usr --libexecdir=/usr/lib --enable-xvfb --enable-xwayland --enable-xnest --enable-xdmcp
        make -j$(nproc)
    fi
    # Log built binaries
    echo "Built binaries:" >&2
    find . -type f -executable >&2
}

package_xlibre-server() {
    depends=('libx11' 'xorgproto' 'libxkbfile' 'libxfont2' 'mesa' 'libxcvt' 'pixman' 'dbus' 'systemd-libs')
    provides=('xorg-server')
    conflicts=('xorg-server' 'xorg-server-devel')
    pkgdesc="XLibre X11 server core"
    
    cd xserver
    if [ -d build ]; then
        DESTDIR="\$pkgdir" ninja -C build install
    else
        make DESTDIR="\$pkgdir" install
    fi
    rm -rf "\$pkgdir"/usr/bin/{Xvfb,Xwayland,Xnest} 2>/dev/null || true
    rm -rf "\$pkgdir"/usr/share/X11/xorg.conf.d
}

package_xlibre-server-common() {
    pkgdesc="XLibre server common files"
    depends=('xlibre-server')
    conflicts=('xorg-server-devel')
    
    cd xserver
    install -Dm644 -t "\$pkgdir"/usr/share/X11/xorg.conf.d config/*.conf 2>/dev/null || true
}

package_xlibre-server-xvfb() {
    pkgdesc="XLibre virtual framebuffer server"
    depends=('xlibre-server')
    
    cd xserver
    if [ -f build/hw/vfb/Xvfb ]; then
        echo "Installing build/hw/vfb/Xvfb for xlibre-server-xvfb" >&2
        install -Dm755 build/hw/vfb/Xvfb "\$pkgdir"/usr/bin/Xvfb
    elif [ -f Xvfb ]; then
        echo "Installing Xvfb for xlibre-server-xvfb" >&2
        install -Dm755 Xvfb "\$pkgdir"/usr/bin/Xvfb
    else
        echo "Warning: Xvfb binary not found for xlibre-server-xvfb, skipping installation" >&2
    fi
}

package_xlibre-server-xwayland() {
    pkgdesc="XLibre Xwayland server"
    depends=('xlibre-server')
    
    cd xserver
    if [ -f build/hw/xwayland/Xwayland ]; then
        echo "Installing build/hw/xwayland/Xwayland for xlibre-server-xwayland" >&2
        install -Dm755 build/hw/xwayland/Xwayland "\$pkgdir"/usr/bin/Xwayland
    elif [ -f Xwayland ]; then
        echo "Installing Xwayland for xlibre-server-xwayland" >&2
        install -Dm755 Xwayland "\$pkgdir"/usr/bin/Xwayland
    else
        echo "Warning: Xwayland binary not found for xlibre-server-xwayland, skipping installation" >&2
    fi
}

package_xlibre-server-xnest() {
    pkgdesc="XLibre nested X server"
    depends=('xlibre-server')
    
    cd xserver
    if [ -f build/hw/xnest/Xnest ]; then
        echo "Installing build/hw/xnest/Xnest for xlibre-server-xnest" >&2
        install -Dm755 build/hw/xnest/Xnest "\$pkgdir"/usr/bin/Xnest
    elif [ -f Xnest ]; then
        echo "Installing Xnest for xlibre-server-xnest" >&2
        install -Dm755 Xnest "\$pkgdir"/usr/bin/Xnest
    else
        echo "Warning: Xnest binary not found for xlibre-server-xnest, skipping installation" >&2
    fi
}
EOF
}

# Function to create PKGBUILD for drivers
create_driver_pkgbuild() {
    local pkgname="$1"
    local repo_url="$2"
    local pkgdir="$3"
    local driver_type="${pkgname/xlibre-/}"
    local repo_dir="${repo_url##*/}"
    repo_dir="${repo_dir%.git}"
    
    mkdir -p "$pkgdir"
    log_message "Creating PKGBUILD for $pkgname in $pkgdir"
    cat > "$pkgdir/PKGBUILD" << EOF
# Maintainer: Your Name <your.email@example.com>
pkgname=$pkgname
pkgver=$PKGVER
pkgrel=$PKGREL
pkgdesc="XLibre $driver_type driver"
arch=('x86_64')
url="$repo_url"
license=('MIT')
options=('!debug')
depends=('xlibre-server')
makedepends=('git' 'meson' 'ninja' 'autoconf' 'automake' 'pkgconf' 'xorgproto' 'libx11' 'systemd-libs' 'libevdev' 'libinput' 'valgrind' 'libdrm' 'cmake' 'libxcursor' 'libxss' 'libxtst')
source=("git+$repo_url.git")
sha256sums=('SKIP')

prepare() {
    cd $repo_dir
    if [ "$pkgname" = "xlibre-video-intel" ]; then
        # Fix __container_of redefinition
        sed -i 's/__container_of/__intel_container_of/g' src/intel_list.h
        # Comment out FOURCC_RGB565 redefinition in sna_video.h
        sed -i 's/#define FOURCC_RGB565/\/\/#define FOURCC_RGB565/' src/sna/sna_video.h
        # Add include for server.h in sna_accel.c
        sed -i '/#include "sna.h"/a #include <xorg\/server.h>' src/sna/sna_accel.c
        # Comment out problematic stippling functions
        sed -i '/^static void *sna_poly_fill_rect_stippled_nxm_blt(/,/^}/ s/^/\/\/ /' src/sna/sna_accel.c
        sed -i '/^static void *sna_poly_fill_rect_stippled_n_box__imm(/,/^}/ s/^/\/\/ /' src/sna/sna_accel.c
        # Log changes for verification
        echo "Modified files for xlibre-video-intel:" >> "\$srcdir/modifications.log"
        grep -H "__intel_container_of" src/intel_list.h >> "\$srcdir/modifications.log" || echo "No __intel_container_of found" >> "\$srcdir/modifications.log"
        grep -H "FOURCC_RGB565" src/sna/sna_video.h >> "\$srcdir/modifications.log" || echo "No FOURCC_RGB565 found" >> "\$srcdir/modifications.log"
        grep -H "server.h" src/sna/sna_accel.c >> "\$srcdir/modifications.log" || echo "No server.h include found" >> "\$srcdir/modifications.log"
        grep -H -C 5 "sna_poly_fill_rect_stippled_nxm_blt" src/sna/sna_accel.c >> "\$srcdir/modifications.log" || echo "No sna_poly_fill_rect_stippled_nxm_blt found" >> "\$srcdir/modifications.log"
        grep -H -C 5 "sna_poly_fill_rect_stippled_n_box__imm" src/sna/sna_accel.c >> "\$srcdir/modifications.log" || echo "No sna_poly_fill_rect_stippled_n_box__imm found" >> "\$srcdir/modifications.log"
    fi
}

build() {
    cd $repo_dir
    if [ -f meson.build ]; then
        echo "Using Meson build system" >&2
        meson setup build --prefix=/usr
        ninja -C build
    else
        echo "Using Autotools build system" >&2
        ./autogen.sh
        ./configure --prefix=/usr
        make -j$(nproc)
    fi
}

package() {
    cd $repo_dir
    if [ -d build ]; then
        DESTDIR="\$pkgdir" ninja -C build install
    else
        make DESTDIR="\$pkgdir" install
    fi
}
EOF
}

# Function to create PKGBUILD for xlibre-base meta-package
create_base_pkgbuild() {
    local pkgdir="$1"
    mkdir -p "$pkgdir"
    log_message "Creating PKGBUILD for xlibre-base in $pkgdir"
    cat > "$pkgdir/PKGBUILD" << EOF
# Maintainer: Your Name <your.email@example.com>
pkgname=xlibre-base
pkgver=$PKGVER
pkgrel=$PKGREL
pkgdesc="XLibre base meta-package"
arch=('x86_64')
url="https://github.com/X11Libre/xserver"
license=('MIT')
depends=('xlibre-server' 'xlibre-input-libinput' 'xlibre-input-evdev' 'xlibre-video-vesa' 'xlibre-video-fbdev' 'libx11' 'libxext' 'libxrandr')

package() {
    # Meta-package, no files to install
    true
}
EOF
}

# Check requirements
check_requirements

# Ensure pacman is up to date
log_message "Updating pacman package database"
sudo pacman -Syu --noconfirm >> "$LOG_FILE" 2>&1 || {
    log_message "ERROR: Failed to update pacman database. Check $LOG_FILE"
    exit 1
}

# Build and install xlibre-server first
log_message "Checking if xlibre-server is already built and installed"
if check_package_built "xlibre-server"; then
    log_message "Skipping xlibre-server, already built and installed"
else
    log_message "Starting build process for xlibre-server"
    pkgdir="$BASE_DIR/xlibre-server"
    repo_url="${REPOS[xlibre-server]}"
    repo_dir="${repo_url##*/}"
    repo_dir="${repo_dir%.git}"

    # Remove conflicting packages
    log_message "Removing xorg-server and xorg-server-devel to avoid conflicts"
    sudo pacman -Rdd --noconfirm xorg-server xorg-server-devel >> "$LOG_FILE" 2>&1 || {
        log_message "Note: xorg-server or xorg-server-devel not installed, proceeding"
    }

    # Clone or update repository
    log_message "Cloning or updating repository $repo_url"
    if [ ! -d "$BASE_DIR/$repo_dir" ]; then
        git clone "$repo_url.git" "$BASE_DIR/$repo_dir" >> "$LOG_FILE" 2>&1 || {
            log_message "ERROR: Failed to clone $repo_url. Check $LOG_FILE"
            log_failed_build "xlibre-server"
            exit 1
        }
        log_message "Successfully cloned $repo_url"
    else
        log_message "Repository $repo_dir already exists, updating"
        cd "$BASE_DIR/$repo_dir"
        git pull >> "$LOG_FILE" 2>&1 || {
            log_message "ERROR: Failed to update $repo_url. Check $LOG_FILE"
            log_failed_build "xlibre-server"
            exit 1
        }
        cd "$BASE_DIR"
    fi

    # Create PKGBUILD
    create_server_pkgbuild "$pkgdir"

    # Install dependencies
    install_pkgbuild_deps "$pkgdir" || {
        log_message "ERROR: Failed to install dependencies for xlibre-server"
        log_failed_build "xlibre-server"
        exit 1
    }

    # Build and install package
    cd "$pkgdir"
    log_message "Building and installing xlibre-server package"
    if ! makepkg -si --noconfirm >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: Failed to build or install xlibre-server. Check $LOG_FILE"
        log_failed_build "xlibre-server"
        clean_failed_build "$pkgdir"
        exit 1
    fi
    log_message "Successfully built and installed xlibre-server package"
    log_successful_build "xlibre-server"

    # Move packages to repo
    log_message "Moving xlibre-server packages to $REPO_DIR"
    mv *.pkg.tar.zst "$REPO_DIR" 2>/dev/null || {
        log_message "ERROR: No package files found for xlibre-server"
        log_failed_build "xlibre-server"
        exit 1
    }
    log_message "Successfully moved xlibre-server packages"
    cd "$BASE_DIR"
fi

# Build and install remaining packages
for pkgname in "${!REPOS[@]}"; do
    if [ "$pkgname" = "xlibre-server" ]; then
        continue
    fi
    log_message "Checking if $pkgname is already built and installed"
    if check_package_built "$pkgname"; then
        log_message "Skipping $pkgname, already built and installed"
        continue
    fi
    log_message "Starting build process for $pkgname"
    repo_url="${REPOS[$pkgname]}"
    repo_dir="${repo_url##*/}"
    repo_dir="${repo_dir%.git}"
    
    # Skip meta-package until drivers are built
    if [ "$pkgname" = "xlibre-base" ]; then
        log_message "Skipping xlibre-base until drivers are built"
        continue
    fi
    
    # Clone or update repository
    log_message "Cloning or updating repository $repo_url"
    if [ ! -d "$BASE_DIR/$repo_dir" ]; then
        git clone "$repo_url.git" "$BASE_DIR/$repo_dir" >> "$LOG_FILE" 2>&1 || {
            log_message "ERROR: Failed to clone $repo_url. Check $LOG_FILE"
            log_failed_build "$pkgname"
            continue
        }
        log_message "Successfully cloned $repo_url"
    else
        log_message "Repository $repo_dir already exists, updating"
        cd "$BASE_DIR/$repo_dir"
        git pull >> "$LOG_FILE" 2>&1 || {
            log_message "ERROR: Failed to update $repo_url. Check $LOG_FILE"
            log_failed_build "$pkgname"
            continue
        }
        cd "$BASE_DIR"
    fi
    
    # Create PKGBUILD
    pkgdir="$BASE_DIR/$pkgname"
    create_driver_pkgbuild "$pkgname" "$repo_url" "$pkgdir"
    
    # Install dependencies
    install_pkgbuild_deps "$pkgdir" || {
        log_message "ERROR: Failed to install dependencies for $pkgname"
        log_failed_build "$pkgname"
        continue
    }
    
    # Build and install package
    cd "$pkgdir"
    log_message "Building and installing $pkgname package"
    if ! makepkg -si --noconfirm >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: Failed to build or install $pkgname. Check $LOG_FILE"
        log_failed_build "$pkgname"
        clean_failed_build "$pkgdir"
        continue
    fi
    log_message "Successfully built and installed $pkgname package"
    log_successful_build "$pkgname"
    
    # Move packages to repo
    log_message "Moving $pkgname packages to $REPO_DIR"
    mv *.pkg.tar.zst "$REPO_DIR" 2>/dev/null || {
        log_message "ERROR: No package files found for $pkgname"
        log_failed_build "$pkgname"
        continue
    }
    log_message "Successfully moved $pkgname packages"
    cd "$BASE_DIR"
done

# Build and install xlibre-base meta-package last
log_message "Checking if xlibre-base is already built and installed"
if check_package_built "xlibre-base"; then
    log_message "Skipping xlibre-base, already built and installed"
else
    log_message "Starting build process for xlibre-base"
    pkgdir="$BASE_DIR/xlibre-base"
    create_base_pkgbuild "$pkgdir"
    cd "$pkgdir"
    log_message "Building and installing xlibre-base package"
    if ! makepkg -si --noconfirm >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: Failed to build or install xlibre-base. Check $LOG_FILE"
        log_failed_build "xlibre-base"
        clean_failed_build "$pkgdir"
    else
        log_message "Successfully built and installed xlibre-base package"
        log_successful_build "xlibre-base"
        log_message "Moving xlibre-base packages to $REPO_DIR"
        mv *.pkg.tar.zst "$REPO_DIR" 2>/dev/null || {
            log_message "ERROR: No package files found for xlibre-base"
            log_failed_build "xlibre-base"
        }
        log_message "Successfully moved xlibre-base packages"
    fi
    cd "$BASE_DIR"
fi

# Create repository database
log_message "Creating repository database in $REPO_DIR"
cd "$REPO_DIR"
repo-add xlibre-repo.db.tar.gz *.pkg.tar.zst >> "$LOG_FILE" 2>&1 || {
    log_message "ERROR: Failed to create repository database. Check $LOG_FILE"
    exit 1
}
log_message "Successfully created repository database"

log_message "Build and installation process complete! Repository created at $REPO_DIR"
log_message "To use the repository outside the chroot, add to /etc/pacman.conf:"
log_message "[xlibre-repo]"
log_message "Server = file://$REPO_DIR"
log_message "Then run: sudo pacman -Syu xlibre-base"
#!/bin/bash
# vim: et sw=2 ts=2 sts=2:
# bash required to use 'local' in the recursive download_package function.
# if someone knows a POSIX trick' let me know
set -e

info() {
  echo "*** $1"
}
error() {
  echo "!!! $1" >&2
}
fail() {
  err=$1
  msg=$2
  if [ $err -ne 0 ]; then
    error "$msg"
    exit $err
  fi
}
accomplished() {
  i=$1
  n=$2
  nbd=$(expr length $n)
  printf "[%0${nbd}d/%d]" $i $n
}
clean() {
  [ -n "$rootfs" ] && [ -d "$rootfs" ] && rm --preserve-root --one-file-system -rf "$rootfs"
}
revert() {
  echo ''
  error "Interrupted, so cleaning up"
  clean || true
  error "exiting..."
  exit 1
}
trap revert SIGHUP SIGINT SIGTERM


download_package() {
  local premsg
  local slackfolder
  local p
  local hidden
  local pkg_name
  local pkg_mirror
  local pkg_location
  local pkg_deps
  local pkg_info
  local pkg_url
  premsg="$1"
  slackfolder="$2"
  p="$3"
  hidden=0
  if echo "$p" | grep -q '~'; then
    hidden=1
    p=$(echo "$p" | sed -r 's/^~(.*)/\1/')
  fi
  if [ $hidden -eq 0 ]; then
    for b in $blacklist; do
      if [ "$p" = "$b" ]; then
        return
      fi
    done
  fi
  pkg_name=''
  pkg_mirror=''
  pkg_location=''
  pkg_deps=''
  pkg_info=$(mktemp)
  grep -A 6 "^PACKAGE NAME: *$p-[^-]\+-[^-]\+-[^-]\+\.t[gblx]z" $cache/location.lst | head -n 3 > $pkg_info
  while read l; do
    if [ -z "$pkg_name" ] && echo "$l" | grep -q "^PACKAGE NAME:"; then
      pkg_name=$(echo "$l" | sed 's/^PACKAGE NAME: *//')
    fi
    if [ -z "$pkg_mirror" ] && echo "$l" | grep -q "^PACKAGE MIRROR:"; then
      pkg_mirror=$(echo "$l" | sed 's/^PACKAGE MIRROR: *//')
    fi
    if [ -z "$pkg_location" ] && echo "$l" | grep -q "^PACKAGE LOCATION:"; then
      pkg_location=$(echo "$l" | sed 's/^PACKAGE LOCATION: *//')
    fi
    if [ -z "$pkg_deps" ] && echo "$l" | grep -q "^PACKAGE REQUIRED:"; then
      pkg_deps=$(echo "$l" | sed 's/^PACKAGE REQUIRED: *//')
    fi
  done < $pkg_info
  rm $pkg_info
  if [ -n "$pkg_name" ]; then
    if [ -z "$pkg_mirror" ]; then
      if echo $pkg_location | grep -q '^\./salix'; then
        pkg_mirror="$mirror"/$arch/$release/
      else
        pkg_mirror="$mirror"/$arch/$slackfolder-$release/
      fi
    fi
    if [ $hidden -eq 0 ]; then
      if [ -n "$pkg_deps" ]; then
        for dep in $(echo $pkg_deps | sed 's/,/ /g'); do
          if echo "$dep" | grep -q '|'; then
            dep=$(echo "$dep" | cut -d'|' -f1)
          fi
          download_package "  dep:" "$slackfolder" $dep
        done
      fi
      if echo $p | grep -q '^groff'; then
        # hack for groff who depends on heavy gcc package for nothing
        download_package "  hack:" "$slackfolder" ~gcc
      fi
      pkg_url="${pkg_mirror}${pkg_location}/${pkg_name}"
      if [ ! -e "$cache/$pkg_name" ]; then
        info "$premsg $pkg_name"
        wget -q -O "$cache/$pkg_name" "$pkg_url"
      fi
    else
      pkg_url="${pkg_mirror}${pkg_location}/${pkg_name}"
      info "$premsg $pkg_name"
      wget -q -O "$cache/.${pkg_name}.hack" "$pkg_url"
    fi
  fi
}

download_salix() {
  mkdir -p $cache
  if [ -e $cache/location.lst ]; then
    info "Using cache"
    return 0
  fi
  if [ "$arch" = "i486" ] || [ "$arch" = "x86_64" ]; then
    slackfolder=slackware
  elif [ "$arch" = "arm" ]; then
    slackfolder=slackwarearm
  fi
  info "Downloading packages location..."
  wget -q -O - "$mirror"/$arch/$release/PACKAGES.TXT.gz | gunzip -c | grep '^PACKAGE NAME:\|PACKAGE MIRROR:\|PACKAGE LOCATION:\|PACKAGE REQUIRED:' > $cache/location.lst && \
    wget -q -O - "$mirror"/$arch/$slackfolder-$release/patches/PACKAGES.TXT.gz | gunzip -c | grep '^PACKAGE NAME:\|PACKAGE MIRROR:\|PACKAGE LOCATION:\|PACKAGE REQUIRED:' >> $cache/location.lst && \
    wget -q -O - "$mirror"/$arch/$slackfolder-$release/extra/PACKAGES.TXT.gz | gunzip -c | grep '^PACKAGE NAME:\|PACKAGE MIRROR:\|PACKAGE LOCATION:\|PACKAGE REQUIRED:' >> $cache/location.lst && \
    wget -q -O - "$mirror"/$arch/$slackfolder-$release/PACKAGES.TXT.gz | gunzip -c | grep '^PACKAGE NAME:\|PACKAGE MIRROR:\|PACKAGE LOCATION:\|PACKAGE REQUIRED:' >> $cache/location.lst
  if [ $? -ne 0 ]; then
    error "Failed to download the packages location, aborting."
    return 1
  fi
  info "Downloading Salix OS packages..."
  n=$(echo "$pkgs" | sed '/^$/d' | wc -l)
  i=0
  for p in $pkgs; do
    i=$(($i + 1))
    download_package "$(accomplished $i $n)" "$slackfolder" "$p"
  done
  info "Download complete."
}

installpkg() {
  ipkg_root=/
  while [ -n "$1" ]; do
    case "$1" in
      -root) ipkg_root="$2"; shift 2 ;;
      *) ipkg_pkg="$1"; shift; break ;;
    esac
  done
  [ -f "$ipkg_pkg" ] || return 1
  mkdir -p "$ipkg_root"
  (
    cd "$ipkg_root"
    tmp="$cache"/install.log
    ipkg_shortname=$(basename "$ipkg_pkg" $(echo "$ipkg_pkg" | sed 's/.*\(\.t[glbx]z\)$/\1/'))
    ipkg_basename=$(echo "$ipkg_shortname" | sed 's/\(.*\)-[^-]\+-[^-]\+-[^-]\+/\1/')
    ipkg_compressed="$(du -sh "$(readlink -f $ipkg_pkg)" | cut -f 1)"
    tar xvif "$ipkg_pkg" > "$tmp"
    ipkg_log=./var/log
    for PKGDBDIR in packages removed_packages removed_scripts scripts setup; do
      if [ ! -d $ipkg_log/$PKGDBDIR ]; then
        rm -rf $ipkg_log/$PKGDBDIR # make sure it is not a symlink or something stupid
        mkdir -p $ipkg_log/$PKGDBDIR
        chmod 755 $ipkg_log/$PKGDBDIR 
      fi
    done
    echo "PACKAGE NAME:     $ipkg_shortname" > $ipkg_log/packages/$ipkg_shortname
    echo "COMPRESSED PACKAGE SIZE:     $ipkg_compressed" >> $ipkg_log/packages/$ipkg_shortname
    # uncompressed size not known, but that is not very important here.
    echo "UNCOMPRESSED PACKAGE SIZE:     $ipkg_compressed" >> $ipkg_log/packages/$ipkg_shortname
    echo "PACKAGE LOCATION: $ipkg_pkg" >> $ipkg_log/packages/$ipkg_shortname
    echo "PACKAGE DESCRIPTION:" >> $ipkg_log/packages/$ipkg_shortname
    if [ -e install/slack-desc ]; then
      grep "^$ipkg_basename:" install/slack-desc >> $ipkg_log/packages/$ipkg_shortname
    fi
    echo "FILE LIST:" >> $ipkg_log/packages/$ipkg_shortname
    if [ "$(cat "$tmp" | grep '^\./' | wc -l | tr -d ' ')" = "1" ]; then
      cat "$tmp" >> $ipkg_log/packages/$ipkg_shortname
    else
      echo './' >> $ipkg_log/packages/$ipkg_shortname
      cat "$tmp" >> $ipkg_log/packages/$ipkg_shortname
    fi
    rm -f "$tmp"
    [ -x ./sbin/ldconfig ] && ./sbin/ldconfig -r . || true
    if [ -f install/doinst.sh ]; then
      # sanity regarding passwd that could be called outside chroot.
      if grep -q '^\(usr/bin/\)\?passwd ' install/doinst.sh; then
        sed -ri 's,^(usr/bin/)?passwd .*,chroot . \0,' install/doinst.sh
      fi
      # ldconfig using /
      if grep -q -- '-x /sbin/ldconfig ' install/doinst.sh; then
        sed -ri 's,-x /sbin/ldconfig ,-x ./sbin/ldconfig ,' install/doinst.sh
      fi
      if grep -q '^ */sbin/ldconfig -l' install/doinst.sh; then
        sed -ri 's,( *)/sbin/ldconfig -l,\1./sbin/ldconfig -r . -l,' install/doinst.sh
        sed -ri 's,\./sbin/ldconfig -r \. -l `basename \$file \.incoming`,.\0,' install/doinst.sh
      fi
      # chroot with cp
      if grep -q 'chroot . /bin/cp ' install/doinst.sh; then
        sed -ri 's,chroot . /bin/cp ,cp ,' install/doinst.sh
      fi
      # init/telinit disabled
      if grep -q '/sbin/\(tel\)\?init' install/doinst.sh; then
        sed -ri 's,/sbin/(tel)?init [-a-zA-Z0-6],true \0,' install/doinst.sh
      fi
      sh install/doinst.sh -install || true
      cp install/doinst.sh "$ipkg_log"/scripts/$ipkg_shortname
      chmod 755 "$ipkg_log"/scripts/$ipkg_shortname
    fi
    [ -e install ] && rm -rf install
  )
}

install_salix() {
  download_salix || return 1
  mkdir -p $rootfs
  info "Installing packages from $cache into $rootfs..."
  pkg_list=$(find $cache -name '*.t[gblx]z' | sort)
  n=$(echo "$pkg_list" | wc -l)
  i=0
  for package in $pkg_list ; do
    i=$(($i + 1))
    info "$(accomplished $i $n) Installing $(basename $package | sed -r 's/(.*)\.t[gblx]z$/\1/')..."
    installpkg -root $rootfs $package
    if echo $(basename $package) | grep -q '^groff'; then
      info "  Hacking groff with gcc libs"
      tar -C $rootfs -xf $cache/.gcc-*.hack usr/lib$LIBDIRSUFFIX/libgcc_s.so.1
    fi
  done
  return 0
}

configure_salix() {
  info "Configuring..."
  # the next part contains excerpts taken from SeTconfig (written by Patrick Volkerding) from the slackware setup disk.
  # <FROM SeTconfig>
  ( cd "$rootfs" ; chmod 755 ./ )
  ( cd "$rootfs" ; chmod 755 ./var )
  if [ -d "$rootfs"/usr/src/linux ]; then
    chmod 755 "$rootfs"/usr/src/linux
  fi
  if [ ! -d "$rootfs"/proc ]; then
    mkdir "$rootfs"/proc
    chown 0:0 "$rootfs"/proc
  fi
  if [ ! -d "$rootfs"/sys ]; then
    mkdir "$rootfs"/sys
    chown 0:0 "$rootfs"/sys
  fi
  chmod 1777 "$rootfs"/tmp
  if [ ! -d "$rootfs"/var/spool/mail ]; then
    mkdir -p "$rootfs"/var/spool/mail
    chmod 755 "$rootfs"/var/spool
    chown 0:12 "$rootfs"/var/spool/mail
    chmod 1777 "$rootfs"/var/spool/mail
  fi
  echo "#!/bin/sh" > "$rootfs"/etc/rc.d/rc.keymap
  echo "# Load the keyboard map.  More maps are in /usr/share/kbd/keymaps." >> "$rootfs"/etc/rc.d/rc.keymap
  echo "if [ -x /usr/bin/loadkeys ]; then" >> "$rootfs"/etc/rc.d/rc.keymap
  echo "  /usr/bin/loadkeys us" >> "$rootfs"/etc/rc.d/rc.keymap
  echo "fi" >> "$rootfs"/etc/rc.d/rc.keymap
  chmod 755 "$rootfs"/etc/rc.d/rc.keymap
  # </FROM SeTconfig>
  # network configuration is left to the user
  # editing /etc/rc.d/rc.inet1.conf and /etc/resolv.conf of the container
  # just set the hostname
  echo "salix.local" > "$rootfs"/etc/HOSTNAME
  # make needed devices, from Chris Willing's MAKEDEV.sh
  # http://www.vislab.uq.edu.au/howto/lxc/MAKEDEV.sh
  DEV="$rootfs"/dev
  # cleanup & create the few devices needed by the container
  rm -rf "${DEV}" 
  mkdir "${DEV}"
  mkdir -m 755 "${DEV}"/pts
  mkdir -m 1777 "${DEV}"/shm
  mknod -m 666 "${DEV}"/null c 1 3
  mknod -m 666 "${DEV}"/zero c 1 5
  mknod -m 666 "${DEV}"/random c 1 8
  mknod -m 666 "${DEV}"/urandom c 1 9
  mknod -m 666 "${DEV}"/tty c 5 0
  mknod -m 600 "${DEV}"/console c 5 1
  mknod -m 666 "${DEV}"/tty0 c 4 0
  mknod -m 666 "${DEV}"/tty1 c 4 1
  mknod -m 666 "${DEV}"/tty2 c 4 2
  mknod -m 666 "${DEV}"/tty3 c 4 3
  mknod -m 666 "${DEV}"/tty4 c 4 4
  mknod -m 666 "${DEV}"/tty5 c 4 5
  mknod -m 666 "${DEV}"/full c 1 7
  mknod -m 600 "${DEV}"/initctl p
  mknod -m 660 "${DEV}"/loop0 b 7 0
  mknod -m 660 "${DEV}"/loop1 b 7 1
  ln -s pts/ptmx "${DEV}"/ptmx
  # disable pointless services in a container
  chmod -x "$rootfs"/etc/rc.d/rc.inet1 # normally not needed with bridge
  chmod -x "$rootfs"/etc/rc.d/rc.keymap
  # simplify rc.6 and rc.S, http://www.vislab.uq.edu.au/howto/lxc/create_container.html
  # and some other small fixes for a clean boot
  sed -i '
/# Try to mount \/proc:/i \
if [ ! -e /.dockerinit ]; then
; /# Done checking root filesystem/a \
fi # end container check
; /# Remounting the \/ partition will initialize the new \/etc\/mtab:/i \
if [ ! -e /.dockerinit ]; then
; /\/sbin\/mount -w -o remount \//a \
fi # end container check
; /# Fix \/etc\/mtab to list sys and proc/i \
if [ ! -e /.dockerinit ]; then
; /# Add entry for \/ to \/etc\/mtab:/i \
if [ ! -e /.dockerinit ]; then
; /# Clean up some temporary files:/i \
fi # end container check
; /# Run serial port setup script:/i \
if [ ! -e /.dockerinit ]; then
; /# Carry an entropy pool/i \
fi # end container check
    ' "$rootfs"/etc/rc.d/rc.S
  sed -i '
/# Save the system time to the hardware clock/i \
if [ ! -e /.dockerinit ]; then
; /# Run any local shutdown scripts:/ i\
fi # end container check
; /# Turn off swap:/i \
if [ ! -e /.dockerinit ]; then
; /# This never hurts:/i \
fi # end container check
; /# Close any volumes opened by cryptsetup:/i \
if [ ! -e /.dockerinit ]; then
; $i \
else \
  # confirm successful shutdown \
  echo; echo -e "${BOLDYELLOW}Container stopped.${COLOR_RESET}"; echo \
fi # end container check
    ' "$rootfs"/etc/rc.d/rc.6
  sed -i '
/# Screen blanks/i \
if [ ! -e /.dockerinit ]; then
; /# Set the permissions on \/var\/log\/dmesg/i \
fi # end container check
    ' "$rootfs"/etc/rc.d/rc.M
  sed -i '
/# If the interface isn.t in the kernel yet/i \
if [ ! -e /.dockerinit ]; then
; /then # interface exists/i \
fi # end container check
    ' "$rootfs"/etc/rc.d/rc.inet1
  echo "docker container" >> "$rootfs"/etc/motd
  # reduce the number of local consoles: two should be enough
  sed -i '/^c3\|^c4\|^c5\|^c6/s/^/# /' "$rootfs"/etc/inittab
  # set the default runlevel to 3
  sed -i 's/id:4:initdefault:/id:3:initdefault:/' "$rootfs"/etc/inittab 
  # fix some broken links
  if [ -d "$rootfs"/usr/lib${LIBDIRSUFFIX} ]; then
    ( 
      cd "$rootfs"/usr/lib${LIBDIRSUFFIX}
      [ -e libcrypto.so.0 ] || ln -s libcrypto.so libcryto.so.0
      [ -e libssl.so.0 ] || ln -s libssl.so libssl.so.0
    )
  fi
  # set a default combination for the luggage
  sed -ri 's/^root:[^:]+:/root::/' "$rootfs"/etc/shadow
  if [ "$arch" != "x86_64" ]; then
    # fake uname to tell it's the right architecture
    mv "$rootfs/bin/uname" "$rootfs/bin/uname.host"
    cat > "$rootfs/bin/uname" <<EOF
#!/bin/sh
# vim: set et sw=2 ts=2 sts=2 tw=0:
fake_arch=$arch
EOF
    cat >> "$rootfs/bin/uname" <<'EOF'
uname=/bin/uname.host
kernel_name=
kernel_release=
kernel_version=
hostname=
arch=
processor=
platform=
os=
add_kernel_name() {
  kernel_name=1
}
add_kernel_release() {
  kernel_release=1
}
add_kernel_version() {
  kernel_version=1
}
add_hostname() {
  hostname=1
}
add_arch() {
  arch=1
}
add_processor() {
  processor=1
}
add_platform() {
  platform=1
}
add_os() {
  os=1
}
add_all() {
  add_kernel_name
  add_hostname
  add_kernel_release
  add_kernel_version
  add_arch
  [ "($uname -p)" = "unknown" ] || add_processor
  [ "($uname -i)" = "unknown" ] || add_platform
  add_os
}
add_to_res() {
  [ -n "$res" ] && res="$res $1" || res="$1"
}
while [ -n "$1" ]; do
  opt="$1"
  shift
  case "$opt" in
    --help) exec $uname $opt ;;
    --version) exec $uname $opt ;;
    -s|--kernel-name) add_kernel_name ;;
    -r|--kernel-release) add_kernel_release ;;
    -v|--kernel-version) add_kernel_version ;;
    -n|--nodename) add_hostname ;;
    -m|--machine) add_arch ;;
    -p|--processor) add_processor ;;
    -i|--hardware-platform) add_platform ;;
    -o|--operating-system) add_os ;;
    -a|--all) add_all ;;
    -*)
      for o in $(echo "$opt"|sed 's/^-//; s/./-\0 /g'); do
        case "$o" in
          -s) add_kernel_name ;;
          -r) add_kernel_release ;;
          -v) add_kernel_version ;;
          -n) add_hostname ;;
          -m) add_arch ;;
          -p) add_processor ;;
          -i) add_platform ;;
          -o) add_os ;;
          -a) add_all ;;
          *) exec $uname "$opt" ;;
        esac
      done
      ;;
    *) exec $uname "$opt" ;;
  esac
done
res=""
[ -n "$kernel_name" ] && add_to_res "$($uname -s)"
[ -n "$hostname" ] && add_to_res "$($uname -n)"
[ -n "$kernel_release" ] && add_to_res "$($uname -r)"
[ -n "$kernel_version" ] && add_to_res "$($uname -v)"
[ -n "$arch" ] && add_to_res "$fake_arch"
[ -n "$processor" ] && add_to_res "$($uname -p)"
[ -n "$platform" ] && add_to_res "$($uname -i)"
[ -n "$os" ] && add_to_res "$($uname -o)"
[ -n "$res" ] || add_to_res "$($uname -s)"
echo "$res"
EOF
    chmod +x "$rootfs/bin/uname"
  fi
  return 0
}

########## INIT ##########

if [ "$(id -u)" != "0" ]; then
  error "This script should be run as 'root'."
  exit 1
fi

release=14.0
[ -n "$arch" ] || arch=x86_64
case "$arch" in
  i486) suffix='32';;
  arm) suffix='arm';;
  *) suffix='';;
esac
[ -n "$mirror" ] || mirror=http://download.salixos.org
[ -n "$cache_base" ] && cache_base="$(readlink -f "$cache_base")" || cache_base=~/.cache/pkgs-salix
if [ -z "$pkgs" ]; then
  pkgs="
aaa_base
aaa_terminfo
glibc-solibs
attr
bash
bin
binutils
coreutils
dcron
diffutils
dotnew
etc
file
findutils
gawk
gnupg
grep
groff
gzip
htop
infozip
less
lsof
man
nano
network-scripts
patch
procps
salix-man
sed
shadow
spkg
slapt-get
sysklogd
sysvinit
sysvinit-functions
sysvinit-scripts
tar
time
tree
util-linux
which
whois
xz
rootuser-settings
user-settings
"
fi
blacklist="gcc udev"

name=salix-$release-$arch
cache=$cache_base/$arch/$release
rootfs="$(readlink -f "$(dirname "$0")")"/build
[ "$1" = "--no-cache" ] && [ -e "$cache" ] && rm -rf "$cache"
[ "$arch" = "x86_64" ] && LIBDIRSUFFIX="64" || LIBDIRSUFFIX=""

install_salix || fail $? "Failed to install Salix"
configure_salix || fail $? "Failed to configure Salix for a container"
info "Creating tar..."
tar --numeric-owner -C $rootfs -caf $name.tar .
clean
echo "
Salix $release ($arch) container configured and available in the tar:

    $name.tar

Create a docker image with:

    cat $name.tar | docker import - $(docker info|grep ^Username:|cut -d' ' -f2)/salix$suffix-base:$release

"

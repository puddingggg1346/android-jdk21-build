#!/bin/bash
set -e
. setdevkitpath.sh

export FREETYPE_DIR=$PWD/freetype-$BUILD_FREETYPE_VERSION/build_android-$TARGET_SHORT
export CUPS_DIR=$PWD/cups-2.2.4
export CFLAGS+=" -DLE_STANDALONE" # -I$FREETYPE_DIR -I$CUPS_DI
if [ "$TARGET_JDK" == "arm" ] # || [ "$BUILD_IOS" == "1" ]
then
  export CFLAGS+=" -O3 -D__thumb__"
else
  export CFLAGS+=" -O3"
fi

# if [ "$TARGET_JDK" == "aarch32" ] || [ "$TARGET_JDK" == "aarch64" ]
# then
#   export CFLAGS+=" -march=armv7-a+neon"
# fi

# It isn't good, but need make it build anyways
# cp -R $CUPS_DIR/* $ANDROID_INCLUDE/

# cp -R /usr/include/X11 $ANDROID_INCLUDE/
# cp -R /usr/include/fontconfig $ANDROID_INCLUDE/

: # [CI] patch already applied in workflow step

# fix building libjawt
ln -s -f $CUPS_DIR/cups $ANDROID_INCLUDE/

cd openjdk

# Apply patches
# [CI] git reset --hard 已由 workflow 前序步骤替代，跳过
if [ "$BUILD_IOS" != "1" ]; then
# [CI] patch 已在 workflow Apply Android patch 步骤应用
else
# [CI] iOS patch 跳过（非 iOS 构建）

  # Hack: exclude building macOS stuff
  desktop_mac=src/java.desktop/macosx
  mv ${desktop_mac} ${desktop_mac}_NOTIOS
  mkdir -p ${desktop_mac}/native
  mv ${desktop_mac}_NOTIOS/native/libjsound ${desktop_mac}/native/
fi

# rm -rf build

#   --with-extra-cxxflags="$CXXFLAGS -Dchar16_t=uint16_t -Dchar32_t=uint32_t" \
#   --with-extra-cflags="$CPPFLAGS" \

set +e
bash ./configure \
    --with-boot-jdk=$BOOT_JDK \
    --openjdk-target=$TARGET \
    --with-extra-cflags="$CFLAGS" \
    --with-extra-cxxflags="$CFLAGS" \
    --with-extra-ldflags="$LDFLAGS" \
    --disable-precompiled-headers \
    --disable-warnings-as-errors \
    --enable-option-checking=fatal \
    --enable-headless-only=yes \
    --with-jvm-variants=$JVM_VARIANTS \
    --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc \
    --with-cups-include=$CUPS_DIR \
    --with-devkit=$TOOLCHAIN \
    --with-debug-level=$JDK_DEBUG_LEVEL \
    --with-fontconfig-include=$ANDROID_INCLUDE \
    $AUTOCONF_x11arg $AUTOCONF_EXTRA_ARGS \
    --x-libraries=/usr/lib \
    $platform_args
CONFIGURE_RC=$?
if [ $CONFIGURE_RC -ne 0 ]; then
  echo ""
  echo "=== CONFIGURE FAILED (rc=$CONFIGURE_RC) ==="
  echo "=== config.log tail 300 ==="
  tail -300 config.log
  exit $CONFIGURE_RC
fi
set -e

jobs=4

if [ "$BUILD_IOS" == "1" ]; then
  jobs=$(sysctl -n hw.ncpu)
fi

cd build/${JVM_PLATFORM}-${TARGET_JDK}-${JVM_VARIANTS}-${JDK_DEBUG_LEVEL}
set +e
make JOBS=$jobs images
MAKE_RC=$?
set -e
if [ $MAKE_RC -ne 0 ]; then
  echo "=== MAKE FAILED (rc=$MAKE_RC), retry with ENABLE_XOM=false ==="
  make ENABLE_XOM=false JOBS=$jobs images
fi

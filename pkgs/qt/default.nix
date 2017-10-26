# TODO: look into why were compiling with this impure option on Linux:
#   -DDFLT_XKB_CONFIG_ROOT=\"/usr/share/X11/xkb\"

# TODO: patch qt to not use /bin/pwd, test building it in a sandbox

{ crossenv, libudev, libxcb, dejavu-fonts, xcb-util, xcb-util-image,
  xcb-util-wm, xcb-util-keysyms, xcb-util-renderutil, libx11, libxi }:

let
  version = "5.9.2";

  name = "qtbase-${version}";

  platform =
    let
      os_code =
        if crossenv.os == "windows" then "win32"
        else if crossenv.os == "macos" then "macx"
        else if crossenv.os == "linux" then "devices/linux-generic"
        else crossenv.os;
      compiler_code =
        if crossenv.compiler == "gcc" then "g++"
        else crossenv.compiler;
    in "${os_code}-${compiler_code}";

  base_src = crossenv.nixpkgs.fetchurl {
    url = "https://download.qt.io/official_releases/qt/5.9/${version}/submodules/qtbase-opensource-src-${version}.tar.xz";
    sha256 = "16v0dny4rcyd5p8qsnsfg89w98k8kqk3rp9x3g3k7xjmi53bpqkz";
  };

  base_raw = crossenv.make_derivation {
    name = "qtbase-raw-${version}";
    inherit version;
    src = base_src;
    builder = ./builder.sh;

    patches = [
      # Make Qt find our X libraries properly.  The "xlib" test in
      # src/gui/configure.json was failing because its include path
      # was not complete, so we declare that test to use the
      # "xcb_xlib" library (really a group of three libraries).  The
      # 'CONFIG += x11' thing was causing some extra linker arguments
      # like '-Xext' to be added, which caused a linker error, so we
      # removed it.
      # TODO: understand what 'CONFIG += x11' really does and fix it
      ./find-x-libs.patch

      # Fix the build error caused by https://bugreports.qt.io/browse/QTBUG-63637
      ./win32-link-object-max.patch

      # The .pc files have incorrect library names without this (e.g. Qt5Cored)
      ./pc-debug-name.patch

      # uxtheme.h test is broken, always returns false, and results in QtWidgets
      # apps looking bad on Windows.  https://stackoverflow.com/q/44784414/28128
      ./dont-test-uxtheme.patch

      # Add a devices/linux-musl-g++ platform to Qt, copied from
      # devices/linux-arm-generic-g++.  When we upgrade to Qt 5.9, we should
      # consider using device/linux-generic-g++ instead.
      # ./mkspecs.patch  # TODO: remove if linux build succeeds

      # When cross-compiling, Qt uses some heuristics about whether to trust the
      # pkg-config executable supplied by the PKG_CONFIG environment variable.
      # These heuristics are wrong for us, so disable them, making qt use
      # pkg-config-cross.
      ./pkg-config-cross.patch

      # When the DBus session bus is not available, Qt tries to dereference a
      # null pointer, so Linux applications can't start up.
      ./dbus-null-pointer.patch

      # Look for fonts in the same directory as the application by default if
      # the QT_QPA_FONTDIR environment variable is not present.  Without this
      # patch, Qt tries to look for a font directory in the nix store that does
      # not exists, and prints warnings.
      # You must ship a .ttf, .ttc, .pfa, .pfb, or .otf font file
      # with your application (e.g. https://dejavu-fonts.github.io/ ).
      # That list of extensions comes from qbasicfontdatabase.cpp.
      ./font-dir.patch
    ];

    configure_flags =
      "-opensource -confirm-license " +
      "-xplatform ${platform} " +
      "-device-option CROSS_COMPILE=${crossenv.host}- " +
      "-release " +  # change to -debug if you want debugging symbols
      "-static " +
      "-pkg-config " +
      "-nomake examples " +
      "-no-icu " +
      "-no-fontconfig " +
      "-no-reduce-relocations " +
      ( if crossenv.os == "windows" then "-opengl desktop"
        else if crossenv.os == "linux" then
          "-qpa xcb " +
          "-system-xcb " +
          "-no-opengl "
          # This is our attempt to get the tests.xlib test in
          # src/gui/configure.json to pass, but it doesn't work
          # because x11 depends on xproto to provide the X11/X.h
          # header.  We should teach Qt to use pkg-config to find x11,
          # like a normal program.
          # "-device-option QMAKE_INCDIR_X11=${libx11}/include "
        else "" );

     cross_inputs =
       if crossenv.os == "linux" then [
           libudev  # not sure if this helps, but Qt does look for it
           libx11
           libxcb
           xcb-util
           xcb-util-image
           xcb-util-wm
           xcb-util-keysyms
           xcb-util-renderutil
           libxi
         ]
       else [];
  };

  # This wrapper aims to make Qt easier to use by generating CMake package files
  # for it.  The existing support for CMake in Qt does not handle static
  # linking; other projects maintian large, messy patches to fix it, but we
  # prefer to generate the CMake files in a clean way from scratch.
  base = crossenv.make_derivation {
    inherit version name;
    os = crossenv.os;
    qtbase = base_raw;
    cross_inputs = base_raw.cross_inputs;
    builder.ruby = ./wrapper_builder.rb;
  };

  examples = crossenv.make_derivation {
    name = "qtbase-examples-${version}";
    inherit version;
    os = crossenv.os;
    qtbase = base;
    cross_inputs = [ base ];
    dejavu = dejavu-fonts;
    builder = ./examples_builder.sh;
  };

  license_fragment = crossenv.native.make_derivation {
    name = "qtbase-${version}-license-fragment";
    inherit version;
    src = base_src;
    builder = ./license_builder.sh;
  };

  license_set =
    (
      if crossenv.os == "linux" then
        libudev.license_set //
        libx11.license_set //
        libxcb.license_set //
        xcb-util.license_set //
        xcb-util-image.license_set //
        xcb-util-wm.license_set //
        xcb-util-keysyms.license_set //
        xcb-util-renderutil.license_set //
        libxi.license_set
      else
        {}
    ) //
    { "${name}" = license_fragment; };
in
  base // {
    recurseForDerivations = true;
    inherit base_src;
    inherit base_raw;
    inherit base;
    inherit examples;
    inherit license_set;
  }

#!/usr/bin/env python3
"""Build a pinned Ghostscript (AGPL-3.0) as a dynamic iOS framework.

Ghostscript powers vector-preserving PDF compression, PDF/A, PDF repair and grayscale, and
reading EPS/PostScript/Illustrator files. Its own bundled libraries (FreeType, libjpeg,
libpng, zlib, Little CMS, OpenJPEG, jbig2dec, libtiff) are compiled in; fonts and init files
live in its ROM file system, so the framework needs no resources on disk. Only the bridge's
mbgs_* functions are exported.

    python3 Scripts/BuildGhostscript.py --platform ios --platform ios-simulator
    python3 Scripts/BuildGhostscript.py --platform macos        # host tests
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/ghostscript"
PACKAGE = ROOT / "Native/Ghostscript"
BRIDGE = ROOT / "Native/MBGhostscriptBridge"
PATCHES = PACKAGE / "patches"
SOURCES = json.loads((PACKAGE / "sources.json").read_text())
FRAMEWORK = "MBGhostscriptBridge"
REVISION = 2  # Bump when changing how Ghostscript itself is compiled.

# Output devices the app uses; leaving out printers and OCR keeps the framework small.
DRIVERS = "pdfwrite,ps2write,eps2write,png16m,pngalpha,pnggray,jpeg,jpeggray,txtwrite"
CONFIGURE = ["--without-x", "--without-cal", "--without-tesseract", "--disable-cups", "--disable-fontconfig",
             "--disable-dbus", "--without-libpaper", "--without-ijs", "--without-libidn", "--without-pdftoraster",
             "--without-urf", f"--with-drivers={DRIVERS}"]


def capture(args, env=None):
    return subprocess.check_output([str(x) for x in args], text=True, env=env).strip()


def run(args, cwd, env, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as output:
        output.write("\n$ " + shlex.join([str(x) for x in args]) + "\n")
        output.flush()
        result = subprocess.run([str(x) for x in args], cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-45:]), file=sys.stderr)
        raise RuntimeError(f"Build failed; see {log}")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def patches_digest():
    """One hash over every patch, in the order they're applied."""
    return hashlib.sha256(b"".join(path.name.encode() + digest(path).encode() for path in sorted(PATCHES.glob("*.patch")))).hexdigest()


def fetch_source(offline):
    spec = SOURCES["ghostscript"]
    downloads = CACHE / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / spec["archive"]
    if not archive.exists():
        if offline:
            raise RuntimeError(f"Missing cached source: {archive}; run without --offline to fetch")
        temporary = archive.with_suffix(archive.suffix + ".part")
        for candidate in [spec["url"]] + spec.get("mirrors", []):
            download = subprocess.run(["curl", "--fail", "--location", "--retry", "5", "--retry-all-errors",
                                       "--retry-delay", "3", "--output", str(temporary), candidate])
            if download.returncode == 0 and digest(temporary) == spec["sha256"]:
                temporary.replace(archive)
                break
            temporary.unlink(missing_ok=True)
        else:
            raise RuntimeError("Could not download Ghostscript with the pinned checksum")
    if digest(archive) != spec["sha256"]:
        raise RuntimeError(f"Source checksum mismatch: {archive}")
    return archive


def target_settings(platform):
    sdk, target, minimum = {
        "macos": ("macosx", "arm64-apple-macos13.0", "13.0"),
        "ios": ("iphoneos", "arm64-apple-ios17.0", "17.0"),
        "ios-simulator": ("iphonesimulator", "arm64-apple-ios17.0-simulator", "17.0"),
    }[platform]
    sysroot = capture(["xcrun", "--sdk", sdk, "--show-sdk-path"])
    cc = capture(["xcrun", "--sdk", sdk, "--find", "clang"])
    return sdk, target, minimum, sysroot, cc


def build_platform(platform, archive, jobs):
    sdk, target, minimum, sysroot, cc = target_settings(platform)
    work = CACHE / f"{platform}-arm64"
    flags = ["-target", target, "-isysroot", sysroot, "-O2", "-fPIC", "-Wno-implicit-function-declaration"]
    env = os.environ.copy()
    for variable in ("CPATH", "C_INCLUDE_PATH", "LIBRARY_PATH", "SDKROOT", "CONFIG_SITE",
                     "MACOSX_DEPLOYMENT_TARGET", "IPHONEOS_DEPLOYMENT_TARGET"):
        env.pop(variable, None)
    # Host tools (genarch, mkromfs…) run on the Mac during the build; CCAUX builds those.
    # CHECK_INTERRUPTS makes Ghostscript call the bridge's poll hook, which is how jobs get cancelled.
    env.update(CC=cc, CPP=f"{cc} -E", RANLIB=capture(["xcrun", "--find", "ranlib"]),
               CFLAGS=shlex.join(flags + ["-DCHECK_INTERRUPTS"]), CCAUX="/usr/bin/clang",
               CFLAGSAUX="-isysroot " + capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"]), BIGENDIAN="0")
    env["LDFLAGSAUX"] = env["CFLAGSAUX"]
    # Only what affects the compiled library: packaging changes don't force a rebuild.
    identity = hashlib.sha256(json.dumps([REVISION, SOURCES, patches_digest(), CONFIGURE, env["CFLAGS"], target, sysroot,
                                          capture(["xcodebuild", "-version"])],
                                         sort_keys=True).encode()).hexdigest()
    library = work / "source/bin/gs.a"
    stamp = work / ".mb-complete"
    if not (stamp.exists() and stamp.read_text() == identity and library.exists()):
        if work.exists():
            shutil.rmtree(work)
        work.mkdir(parents=True)
        with tarfile.open(archive) as source:
            top = source.getnames()[0].split("/")[0]
            source.extractall(work, filter="data")
        (work / top).rename(work / "source")
        for patch in sorted(PATCHES.glob("*.patch")):
            run(["patch", "-p1", "--forward", "--input", patch], work / "source", env, work / "patch.log")
        print(f"[{platform}] building Ghostscript", flush=True)
        configure = [work / "source/configure"] + CONFIGURE
        if platform != "macos":
            # A --build that differs from --host makes autoconf treat this as a cross build.
            configure += ["--host=aarch64-apple-darwin", f"--build=aarch64-apple-darwin{os.uname().release.split('.')[0]}",
                          "--with-arch_h=./ios/ios_arch-arm.h"]
        run(configure, work / "source", env, work / "configure.log")
        run(["make", f"-j{jobs}", "libgs"], work / "source", env, work / "make.log")
        stamp.write_text(identity)
    else:
        print(f"[{platform}] Ghostscript: cached", flush=True)

    framework = work / f"{FRAMEWORK}.framework"
    if framework.exists():
        shutil.rmtree(framework)
    (framework / "Headers").mkdir(parents=True)
    (framework / "Modules").mkdir()
    shutil.copy2(BRIDGE / "include/MBGhostscriptBridge.h", framework / "Headers")
    (framework / "Modules/module.modulemap").write_text(
        f'framework module {FRAMEWORK} {{\n  umbrella header "MBGhostscriptBridge.h"\n  export *\n}}\n')
    source = work / "source"
    run([cc] + flags + ["-dynamiclib", "-I" + str(BRIDGE / "include"), "-I" + str(source / "psi"), "-I" + str(source / "base"), "-I" + str(source / "obj"),
                        "-install_name", f"@rpath/{FRAMEWORK}.framework/{FRAMEWORK}",
                        "-Wl,-dead_strip", "-Wl,-exported_symbol,_mbgs_*", "-o", framework / FRAMEWORK,
                        BRIDGE / "MBGhostscriptBridge.c", library],
        work, env, work / "bridge.log")
    version = SOURCES["ghostscript"]["version"]
    info = {"CFBundleIdentifier": "app.marginallybetter.MBGhostscriptBridge", "CFBundleName": FRAMEWORK,
            "CFBundleExecutable": FRAMEWORK, "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
            "CFBundleShortVersionString": version, "MinimumOSVersion": minimum,
            "CFBundleSupportedPlatforms": [{"ios": "iPhoneOS", "ios-simulator": "iPhoneSimulator", "macos": "MacOSX"}[platform]]}
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    # Under Licenses/Ghostscript so they don't collide with ImageMagick's notices for the same libraries.
    notices = framework / "Licenses/Ghostscript"
    notices.mkdir(parents=True)
    shutil.copy2(source / "LICENSE", notices / "LICENSE")
    shutil.copy2(source / "doc/COPYING", notices / "COPYING (GNU AGPL 3.0)")
    for name in ("freetype", "jpeg", "libpng", "zlib", "lcms2mt", "openjpeg", "jbig2dec", "tiff", "extract"):
        destination = notices / name
        destination.mkdir()
        for pattern in ("COPYING*", "LICENSE*", "LICENCE*", "README*", "docs/FTL.TXT", "docs/LICENSE.TXT"):
            for license_file in (source / name).glob(pattern):
                if license_file.is_file():
                    shutil.copy2(license_file, destination)
    shutil.copy2(ROOT / "LICENSE", framework / "Licenses/MBGhostscriptBridge-GPL.txt")
    bridge_hash = hashlib.sha256(b"".join(digest(path).encode() for path in sorted(BRIDGE.rglob("*.[ch]")))).hexdigest()
    manifest = {"sources": SOURCES, "platform": platform, "target": target, "drivers": DRIVERS,
                "configure": CONFIGURE, "recipe_revision": REVISION, "recipe_sha256": digest(Path(__file__)),
                "patches": sorted(path.name for path in PATCHES.glob("*.patch")), "patches_sha256": patches_digest(),
                "bridge_sha256": bridge_hash, "license": "AGPL-3.0-or-later", "linkage": "dynamic framework"}
    (framework / "BuildManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[{platform}] framework ready: {framework}", flush=True)
    return framework


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--platform", action="append", choices=["ios", "ios-simulator", "macos"])
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 8))
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    archive = fetch_source(args.offline)
    platforms = list(dict.fromkeys(args.platform or ["ios", "ios-simulator"]))
    if platforms != ["macos"] and "ios" not in platforms:
        parser.error("App XCFramework packaging requires an iOS device slice; add --platform ios")
    frameworks = [build_platform(p, archive, args.jobs) for p in platforms]
    output = ((CACHE / "host") if platforms == ["macos"] else (PACKAGE / "Artifacts")) / f"{FRAMEWORK}.xcframework"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        shutil.rmtree(output)
    command = ["xcodebuild", "-create-xcframework"]
    for framework in frameworks:
        command += ["-framework", str(framework)]
    command += ["-output", str(output)]
    subprocess.run(command, check=True)
    print(f"Built {output}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))

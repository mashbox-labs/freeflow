#!/usr/bin/env python3
"""Generate FreeFlowCatalyst.xcodeproj: Free Flow for Mac from build 20 on. It is the iPhone app (App/, every screen and
the same dictation engine) built for Mac Catalyst, plus an AppKit plug-in (MacBridge/) that the app loads for what
Catalyst can't do: fn in every app, paste at the cursor, the menu-bar item and the floating pill. The aim (2026-10-30)
is a one-to-one port of the iOS Swift app to the Mac. Mac-only Swift for the app side lives in Catalyst/ and compiles
only for Mac Catalyst. Deterministic like generate-project.py (object IDs are hashes of stable names). The project
builds unsigned; scripts/mac-release.sh signs it (Developer ID, hardened runtime), with FF_MAC=catalyst."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
NAME = "FreeFlowCatalyst"
PROJECT = ROOT / f"{NAME}.xcodeproj"
PROJECT.mkdir(exist_ok=True)
PACKAGES = {"FreeFlowKit": "Packages/FreeFlowKit", "FluidAudio": "Packages/FluidAudio", "WhisperKit": "Packages/WhisperKit",
            "FreeFlowEngine": "Packages/FreeFlowEngine"}
WORDLIST_NOTICES = [("ThirdParty/WordList/" + n, t) for n, t in (
    ("SymSpell-LICENSE", "text"), ("symspellpy-LICENSE", "text"), ("GoogleBooksNgram-Usage.html", "text.html"),
    ("CC-BY-3.0-legalcode.txt", "text"), ("SCOWL-Copyright", "text"), ("FrequencyWords-README.md", "net.daringfireball.markdown"),
    ("FrequencyWords-LICENSE", "text"), ("CC-BY-SA-4.0-legalcode.txt", "text"))]

# Build 23: the notices for the loader graphic's font (Outfit, OFL) and renderer (three.js, MIT), byte for byte as their
# authors publish them (ThirdParty/LoaderArt).
# Build 23: Conway Research's NOTICE files for Underdog Bark 3.0 Clean and Pro, byte for byte as published with the weights.
MODEL_NOTICES = [("ThirdParty/Models/Bark-3.0-Clean-NOTICE.txt", "text"), ("ThirdParty/Models/Bark-3.0-Pro-NOTICE.txt", "text")]
LOADER_NOTICES = [("ThirdParty/LoaderArt/OFL-Outfit.txt", "text"), ("ThirdParty/LoaderArt/three.js-LICENSE", "text")]

# Build 23: the first-prepare loader's motion graphic, when its files are in App/Resources/Loader (PrepareLoader.swift).
LOADER_ART = [(p.relative_to(ROOT).as_posix(), {".mov": "video.quicktime", ".png": "image.png"}[p.suffix])
              for p in sorted((ROOT / "App/Resources/Loader").glob("*")) if p.suffix in (".mov", ".png")]

objects: list[str] = []
seen: set[str] = set()
children: list[str] = []


def uid(name: str) -> str:
    return hashlib.sha256(("catalyst:" + name).encode()).hexdigest()[:24].upper()


def q(value: str) -> str:
    return json.dumps(value)


def add(name: str, body: str) -> str:
    ref = uid(name)
    if ref not in seen:
        seen.add(ref)
        objects.append(f"\t\t{ref} = {{ {body} }};")
    return ref


def file_ref(rel: str, ftype: str) -> str:
    ref = add("file:" + rel, f"isa = PBXFileReference; lastKnownFileType = {ftype}; path = {q(rel)}; sourceTree = SOURCE_ROOT;")
    if ref not in children:
        children.append(ref)
    return ref


def build_file(target: str, rel: str, ftype: str, extra: str = "") -> str:
    return add(f"build:{target}:{rel}", f"isa = PBXBuildFile; fileRef = {file_ref(rel, ftype)};{extra}")


package_refs = {n: add(p + ":package", f"isa = XCLocalSwiftPackageReference; relativePath = {q(p)};") for n, p in PACKAGES.items()}
base = file_ref("Configuration/Base.xcconfig", "text.xcconfig")
for rel, ftype in (("Catalyst/Info.plist", "text.plist.xml"), ("Catalyst/FreeFlowCatalyst.entitlements", "text.plist.entitlements"),
                   ("MacBridge/Info.plist", "text.plist.xml")):
    file_ref(rel, ftype)
COMMON = 'SWIFT_VERSION = 5.0; MARKETING_VERSION = 1.1; CURRENT_PROJECT_VERSION = 25; CLANG_ENABLE_MODULES = YES; CODE_SIGNING_ALLOWED = NO; CODE_SIGN_IDENTITY = ""; '


def config_list(key: str, settings: str) -> str:
    refs = []
    cond = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "'
    for mode in ("Debug", "Release"):
        s = settings
        if mode == "Debug" and cond in s:
            # A target's own conditions (FF_MAC_BRIDGE) keep DEBUG beside them; a second key would replace them.
            s, extra = s.replace(cond, cond + "DEBUG "), 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ONLY_ACTIVE_ARCH = YES;'
        elif mode == "Debug":
            extra = cond + 'DEBUG $(inherited)"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ONLY_ACTIVE_ARCH = YES;'
        else:
            extra = 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; ONLY_ACTIVE_ARCH = NO;'
        refs.append(add(f"{key}-{mode}", f"isa = XCBuildConfiguration; name = {mode}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON}{s} {extra} }};"))
    return add(f"{key}-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(refs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")


def target(key, name, ptype, product_name, wrapper, sources, resources, packages, settings, extra_phases=(), deps=()):
    srcs = [build_file(key, rel, "sourcecode.swift") for rel in sources]
    res = [build_file(key, rel, ftype) for rel, ftype in resources if (ROOT / rel).exists()]
    frameworks, product_deps = [], []
    for package in packages:
        dep = add(f"{key}:{package}:product", f"isa = XCSwiftPackageProductDependency; package = {package_refs[package]}; productName = {package};")
        product_deps.append(dep)
        frameworks.append(add(f"{key}:{package}:framework", f"isa = PBXBuildFile; productRef = {dep};"))
    phases = [
        add(f"{key}-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(srcs)},); runOnlyForDeploymentPostprocessing = 0;"),
        add(f"{key}-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({','.join(frameworks)}{',' if frameworks else ''}); runOnlyForDeploymentPostprocessing = 0;"),
        add(f"{key}-resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(res)}{',' if res else ''}); runOnlyForDeploymentPostprocessing = 0;"),
    ] + list(extra_phases)
    product = add(f"{key}-product", f"isa = PBXFileReference; explicitFileType = {q(wrapper)}; includeInIndex = 0; path = {q(product_name)}; sourceTree = BUILT_PRODUCTS_DIR;")
    t = add(f"{key}-target", (
        f"isa = PBXNativeTarget; buildConfigurationList = {config_list(key, settings)}; buildPhases = ({','.join(phases)},); buildRules = (); "
        f"dependencies = ({','.join(deps)}{',' if deps else ''}); name = {name}; packageProductDependencies = ({','.join(product_deps)}{',' if product_deps else ''}); "
        f"productName = {name}; productReference = {product}; productType = {q(ptype)};"))
    return t, product


def swift_files(*dirs: str) -> list[str]:
    return [p.relative_to(ROOT).as_posix() for d in dirs for p in sorted((ROOT / d).rglob("*.swift"))]


# The AppKit plug-in: a plain macOS bundle the Catalyst app loads from Contents/PlugIns. AppKit only (no SwiftUI, no
# FreeFlowKit: a second copy of either can't live in a Catalyst process). FnGesture.swift is compiled in as is, so fn
# behaves exactly as in build 19.
bridge, bridge_product = target(
    "bridge", "FreeFlowMacBridge", "com.apple.product-type.bundle", "FreeFlowMacBridge.bundle", "wrapper.cfbundle",
    swift_files("MacBridge") + ["Packages/FreeFlowKit/Sources/FreeFlowKit/FnGesture.swift",
                                "Mac/FnKeyMonitor.swift", "Mac/TextInserter.swift", "Mac/AudioDevices.swift"], [], [],
    'SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; ARCHS = arm64; PRODUCT_NAME = FreeFlowMacBridge; '
    'PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.mac.bridge"; INFOPLIST_FILE = MacBridge/Info.plist; GENERATE_INFOPLIST_FILE = NO; '
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "FF_MAC_BRIDGE $(inherited)"; ENABLE_HARDENED_RUNTIME = YES; SKIP_INSTALL = YES; '
    'WRAPPER_EXTENSION = bundle; COMBINE_HIDPI_IMAGES = YES; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks";')
proxy = add("bridge-proxy", f"isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {bridge}; remoteInfo = FreeFlowMacBridge;")
bridge_dep = add("bridge-dep", f"isa = PBXTargetDependency; platformFilter = maccatalyst; target = {bridge}; targetProxy = {proxy};")
embed = add("embed:bridge", f"isa = PBXBuildFile; fileRef = {bridge_product}; platformFilter = maccatalyst; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};")
embed_phase = add("embed-plugins", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({embed},); name = \"Embed Mac plug-in\"; runOnlyForDeploymentPostprocessing = 0;")

# The app: the iPhone app's own sources (App/) and the Mac-only ones (Catalyst/).
app, app_product = target(
    "app", "FreeFlowMac", "com.apple.product-type.application", "Free Flow.app", "wrapper.application",
    swift_files("App", "Catalyst"),
    [("App/Assets.xcassets", "folder.assetcatalog"), ("App/Resources/PrivacyInfo.xcprivacy", "text.xml"),
     ("App/Resources/model-manifest.json", "text.json")] + WORDLIST_NOTICES + LOADER_ART + LOADER_NOTICES + MODEL_NOTICES,
    list(PACKAGES),
    'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SUPPORTS_MACCATALYST = YES; SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO; '
    'TARGETED_DEVICE_FAMILY = "1,2"; DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER = NO; ARCHS = arm64; '
    'PRODUCT_NAME = "Free Flow"; PRODUCT_MODULE_NAME = FreeFlowMac; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.mac"; '
    'INFOPLIST_FILE = Catalyst/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_ENTITLEMENTS = Catalyst/FreeFlowCatalyst.entitlements; '
    'ENABLE_HARDENED_RUNTIME = YES; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; '
    # Module FreeFlowMac, as in builds 17-19: with module FreeFlow, Swift type names in the binary read "8FreeFlow12...",
    # which the release check for stray strings in the DMG matches by mistake.
    # FoundationModels (Apple's on-device writer) is macOS 26+; weak so the app still launches on macOS 15.
    'OTHER_LDFLAGS = "$(inherited) -weak_framework FoundationModels"; '
    'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; SKIP_INSTALL = NO;',
    extra_phases=[embed_phase], deps=[bridge_dep])

products = add("products", f"isa = PBXGroup; children = ({app_product},{bridge_product},); name = Products; sourceTree = \"<group>\";")
group = add("main-group", f"isa = PBXGroup; children = ({','.join(children)},{products},); sourceTree = \"<group>\";")
project_configs = [add(f"project-{m}", f"isa = XCBuildConfiguration; name = {m}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON} }};") for m in ("Debug", "Release")]
project_list = add("project-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
root = add("project", (
    "isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; }; "
    f"buildConfigurationList = {project_list}; compatibilityVersion = \"Xcode 16.0\"; developmentRegion = en; hasScannedForEncodings = 0; "
    f"knownRegions = (en,Base,); mainGroup = {group}; packageReferences = ({','.join(package_refs.values())},); productRefGroup = {products}; "
    f"projectDirPath = \"\"; projectRoot = \"\"; targets = ({app},{bridge},);"))
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n"
                                        + "\n".join(objects) + f"\n\t}};\n\trootObject = {root};\n}}\n")

schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Free Flow.app" BlueprintName="FreeFlowMac" ReferencedContainer="container:{NAME}.xcodeproj"/>'
(schemes / "FreeFlowMac.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {NAME}.xcodeproj: {len(objects)} objects")

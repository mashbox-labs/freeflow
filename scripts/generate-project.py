#!/usr/bin/env python3
"""Generate FreeFlow.xcodeproj deterministically, with no third-party project generator.
Object IDs are hashes of stable names, so an unchanged tree gives a byte-identical project.
Targets: the app, the keyboard extension, the widget extension (controls + Live Activity), UI tests."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
NAME = "FreeFlow"
PROJECT = ROOT / f"{NAME}.xcodeproj"
PROJECT.mkdir(exist_ok=True)
PACKAGES = {"FreeFlowKit": "Packages/FreeFlowKit", "FluidAudio": "Packages/FluidAudio", "WhisperKit": "Packages/WhisperKit",
            "FreeFlowEngine": "Packages/FreeFlowEngine"}
# FreeFlowEngine links FreeFlowSpeech.xcframework, which is not in git: scripts/build-engine.sh builds it from pinned sources
# and checks it against Packages/FreeFlowEngine/FreeFlowSpeech.xcframework.sha256 (scripts/release.sh does both).
if not (ROOT / "Packages/FreeFlowEngine/FreeFlowSpeech.xcframework").exists():
    print("note: Packages/FreeFlowEngine/FreeFlowSpeech.xcframework is missing; run scripts/build-engine.sh before building the app")

objects: list[str] = []
seen: set[str] = set()
children: list[str] = []


def uid(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


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


def build_file(target: str, rel: str, ftype: str) -> str:
    return add(f"build:{target}:{rel}", f"isa = PBXBuildFile; fileRef = {file_ref(rel, ftype)};")


package_refs = {n: add(p + ":package", f"isa = XCLocalSwiftPackageReference; relativePath = {q(p)};") for n, p in PACKAGES.items()}
base = file_ref("Configuration/Base.xcconfig", "text.xcconfig")
COMMON = ('IPHONEOS_DEPLOYMENT_TARGET = 18.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2"; '
          'CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 1.1; CURRENT_PROJECT_VERSION = 25; CLANG_ENABLE_MODULES = YES; '
          '"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = x86_64; ')


def config_list(key: str, settings: str) -> str:
    refs = []
    for mode in ("Debug", "Release"):
        extra = ('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; ONLY_ACTIVE_ARCH = YES;'
                 if mode == "Debug" else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; ONLY_ACTIVE_ARCH = NO;')
        refs.append(add(f"{key}-{mode}", f"isa = XCBuildConfiguration; name = {mode}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON}{settings} {extra} }};"))
    return add(f"{key}-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(refs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")


def native_target(key, name, ptype, product_name, wrapper, source_dir, resources, packages, settings, extra_phases=(), deps=()):
    sources = [build_file(key, p.relative_to(ROOT).as_posix(), "sourcecode.swift") for p in sorted((ROOT / source_dir).rglob("*.swift"))]
    res = [build_file(key, rel, ftype) for rel, ftype in resources if (ROOT / rel).exists()]
    frameworks, product_deps = [], []
    for package in packages:
        dep = add(f"{key}:{package}:product", f"isa = XCSwiftPackageProductDependency; package = {package_refs[package]}; productName = {package};")
        product_deps.append(dep)
        frameworks.append(add(f"{key}:{package}:framework", f"isa = PBXBuildFile; productRef = {dep};"))
    phases = [
        add(f"{key}-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(sources)},); runOnlyForDeploymentPostprocessing = 0;"),
        add(f"{key}-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({','.join(frameworks)}{',' if frameworks else ''}); runOnlyForDeploymentPostprocessing = 0;"),
        add(f"{key}-resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(res)}{',' if res else ''}); runOnlyForDeploymentPostprocessing = 0;"),
    ] + list(extra_phases)
    product = add(f"{key}-product", f"isa = PBXFileReference; explicitFileType = {q(wrapper)}; includeInIndex = 0; path = {q(product_name)}; sourceTree = BUILT_PRODUCTS_DIR;")
    target = add(f"{key}-target", (
        f"isa = PBXNativeTarget; buildConfigurationList = {config_list(key, settings)}; buildPhases = ({','.join(phases)},); buildRules = (); "
        f"dependencies = ({','.join(deps)}{',' if deps else ''}); name = {name}; packageProductDependencies = ({','.join(product_deps)}{',' if product_deps else ''}); "
        f"productName = {name}; productReference = {product}; productType = {q(ptype)};"))
    return target, product


def dependency(key: str, target: str, name: str) -> str:
    proxy = add(f"{key}-proxy", f"isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = {name};")
    return add(f"{key}-dep", f"isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};")


# The keyboard's autocorrect word list and the licence and notice files of the lists it is made from (ThirdParty/WordList,
# byte for byte as upstream publishes them; scripts/make-wordlist.py). The app carries the notices too (About > Word list notices).
WORDLIST = [("ThirdParty/WordList/autocorrect-en.tsv", "text")]
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

EXT = ('APPLICATION_EXTENSION_API_ONLY = YES; SKIP_INSTALL = YES; GENERATE_INFOPLIST_FILE = NO; '
       'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks";')
keyboard, keyboard_product = native_target(
    "keyboard", "FreeFlowKeyboard", "com.apple.product-type.app-extension", "FreeFlowKeyboard.appex", "wrapper.app-extension", "Keyboard",
    [("Keyboard/PrivacyInfo.xcprivacy", "text.xml")] + WORDLIST + WORDLIST_NOTICES, ["FreeFlowKit"],
    'PRODUCT_NAME = FreeFlowKeyboard; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.keyboard"; INFOPLIST_FILE = Keyboard/Info.plist; '
    'CODE_SIGN_ENTITLEMENTS = Keyboard/Keyboard.entitlements; '
    # Build 28: the keyboard runs Apple's model (FoundationModels, iOS 26+); weak so it still loads on iOS 18.
    'OTHER_LDFLAGS = "$(inherited) -weak_framework FoundationModels"; ' + EXT)
widgets, widgets_product = native_target(
    "widgets", "FreeFlowWidgets", "com.apple.product-type.app-extension", "FreeFlowWidgets.appex", "wrapper.app-extension", "Widgets",
    [("Widgets/PrivacyInfo.xcprivacy", "text.xml")], ["FreeFlowKit"],
    'PRODUCT_NAME = FreeFlowWidgets; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.widgets"; INFOPLIST_FILE = Widgets/Info.plist; '
    'CODE_SIGN_ENTITLEMENTS = Widgets/Widgets.entitlements; ' + EXT)
embeds = [add(f"embed:{p}", f"isa = PBXBuildFile; fileRef = {p}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};") for p in (keyboard_product, widgets_product)]
embed_phase = add("embed-extensions", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({','.join(embeds)},); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0;")
for rel, ftype in [("App/Info.plist", "text.plist.xml"), ("App/FreeFlow.entitlements", "text.plist.entitlements"), ("Keyboard/Info.plist", "text.plist.xml"),
                   ("Keyboard/Keyboard.entitlements", "text.plist.entitlements"), ("Widgets/Info.plist", "text.plist.xml"), ("Widgets/Widgets.entitlements", "text.plist.entitlements")]:
    file_ref(rel, ftype)
app, app_product = native_target(
    "app", NAME, "com.apple.product-type.application", f"{NAME}.app", "wrapper.application", "App",
    [("App/Assets.xcassets", "folder.assetcatalog"), ("App/Resources/PrivacyInfo.xcprivacy", "text.xml"), ("App/Resources/model-manifest.json", "text.json")] + WORDLIST_NOTICES + LOADER_ART + LOADER_NOTICES + MODEL_NOTICES,
    ["FreeFlowKit", "FluidAudio", "WhisperKit", "FreeFlowEngine"],
    # FoundationModels (the writing layer) is iOS 26+; weak so the app still launches on iOS 18.
    f'OTHER_LDFLAGS = "$(inherited) -weak_framework FoundationModels"; '
    f'PRODUCT_NAME = {NAME}; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow"; INFOPLIST_FILE = App/Info.plist; GENERATE_INFOPLIST_FILE = NO; '
    'CODE_SIGN_ENTITLEMENTS = App/FreeFlow.entitlements; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor; '
    'LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks"; SKIP_INSTALL = NO; ENABLE_PREVIEWS = YES;',
    extra_phases=[embed_phase], deps=[dependency("keyboard", keyboard, "FreeFlowKeyboard"), dependency("widgets", widgets, "FreeFlowWidgets")])
ui_tests, ui_product = native_target(
    "uitests", f"{NAME}UITests", "com.apple.product-type.bundle.ui-testing", f"{NAME}UITests.xctest", "wrapper.cfbundle", "UITests", [], [],
    f'PRODUCT_NAME = {NAME}UITests; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.uitests"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = {NAME};',
    deps=[dependency("uitests", uid("app-target"), NAME)])

products = add("products", f"isa = PBXGroup; children = ({app_product},{keyboard_product},{widgets_product},{ui_product},); name = Products; sourceTree = \"<group>\";")
group = add("main-group", f"isa = PBXGroup; children = ({','.join(children)},{products},); sourceTree = \"<group>\";")
project_configs = [add(f"project-{m}", f"isa = XCBuildConfiguration; name = {m}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON} }};") for m in ("Debug", "Release")]
project_list = add("project-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
root = add("project", (
    "isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; }; "
    f"buildConfigurationList = {project_list}; compatibilityVersion = \"Xcode 16.0\"; developmentRegion = en; hasScannedForEncodings = 0; "
    f"knownRegions = (en,Base,); mainGroup = {group}; packageReferences = ({','.join(package_refs.values())},); productRefGroup = {products}; "
    f"projectDirPath = \"\"; projectRoot = \"\"; targets = ({app},{keyboard},{widgets},{ui_tests},);"))
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n"
                                        + "\n".join(objects) + f"\n\t}};\n\trootObject = {root};\n}}\n")

schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="{NAME}.app" BlueprintName="{NAME}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
test_ref = f'<TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ui_tests}" BuildableName="{NAME}UITests.xctest" BlueprintName="{NAME}UITests" ReferencedContainer="container:{NAME}.xcodeproj"/></TestableReference>'
(schemes / f"{NAME}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{test_ref}</Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {NAME}.xcodeproj: {len(objects)} objects")

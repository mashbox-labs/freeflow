#!/usr/bin/env python3
"""Generate FreeFlowMac.xcodeproj (the native macOS menu-bar app) deterministically, like generate-project.py does for
the iPhone app, and kept separate from it so the two projects never collide. Object IDs are hashes of stable names.
One target: "Free Flow.app" from Mac/*.swift plus App/AudioCapture.swift (shared with the iPhone app as is), linking
FreeFlowKit, FluidAudio and FreeFlowEngine. Signing is done after the build by scripts/mac-release.sh (Developer ID,
hardened runtime), so the project builds unsigned."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
NAME = "FreeFlowMac"
PROJECT = ROOT / f"{NAME}.xcodeproj"
PROJECT.mkdir(exist_ok=True)
PACKAGES = {"FreeFlowKit": "Packages/FreeFlowKit", "FluidAudio": "Packages/FluidAudio", "FreeFlowEngine": "Packages/FreeFlowEngine"}
SHARED_SOURCES = ["App/AudioCapture.swift"]
RESOURCES = [("Mac/Assets.xcassets", "folder.assetcatalog"), ("App/Resources/model-manifest.json", "text.json"),
             ("THIRD-PARTY-NOTICES.md", "net.daringfireball.markdown"), ("LICENSE", "text")]

objects: list[str] = []
seen: set[str] = set()
children: list[str] = []


def uid(name: str) -> str:
    return hashlib.sha256(("mac:" + name).encode()).hexdigest()[:24].upper()


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


def build_file(rel: str, ftype: str) -> str:
    return add(f"build:{rel}", f"isa = PBXBuildFile; fileRef = {file_ref(rel, ftype)};")


package_refs = {n: add(p + ":package", f"isa = XCLocalSwiftPackageReference; relativePath = {q(p)};") for n, p in PACKAGES.items()}
base = file_ref("Configuration/Base.xcconfig", "text.xcconfig")
for rel, ftype in (("Mac/Info.plist", "text.plist.xml"), ("Mac/FreeFlowMac.entitlements", "text.plist.entitlements")):
    file_ref(rel, ftype)
COMMON = ('SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; SWIFT_VERSION = 5.0; MARKETING_VERSION = 1.1; '
          'CURRENT_PROJECT_VERSION = 1; CLANG_ENABLE_MODULES = YES; ARCHS = arm64; ')
TARGET = ('PRODUCT_NAME = "Free Flow"; PRODUCT_MODULE_NAME = FreeFlowMac; PRODUCT_BUNDLE_IDENTIFIER = "$(FF_BUNDLE_PREFIX).freeflow.mac"; '
          'INFOPLIST_FILE = Mac/Info.plist; GENERATE_INFOPLIST_FILE = NO; CODE_SIGN_ENTITLEMENTS = Mac/FreeFlowMac.entitlements; '
          'ENABLE_HARDENED_RUNTIME = YES; CODE_SIGNING_ALLOWED = NO; CODE_SIGN_IDENTITY = ""; COMBINE_HIDPI_IMAGES = YES; '
          'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks"; '
          # FoundationModels (Apple's on-device writer) is macOS 26+; weak so the app still launches on macOS 15.
          'OTHER_LDFLAGS = "$(inherited) -weak_framework FoundationModels"; SKIP_INSTALL = NO;')


def config_list(key: str, settings: str) -> str:
    refs = []
    for mode in ("Debug", "Release"):
        extra = ('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ONLY_ACTIVE_ARCH = YES;'
                 if mode == "Debug" else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; ONLY_ACTIVE_ARCH = NO;')
        refs.append(add(f"{key}-{mode}", f"isa = XCBuildConfiguration; name = {mode}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON}{settings} {extra} }};"))
    return add(f"{key}-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(refs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")


sources = [build_file(p.relative_to(ROOT).as_posix(), "sourcecode.swift") for p in sorted((ROOT / "Mac").rglob("*.swift"))]
sources += [build_file(rel, "sourcecode.swift") for rel in SHARED_SOURCES]
res = [build_file(rel, ftype) for rel, ftype in RESOURCES if (ROOT / rel).exists()]
frameworks, product_deps = [], []
for package in PACKAGES:
    dep = add(f"{package}:product", f"isa = XCSwiftPackageProductDependency; package = {package_refs[package]}; productName = {package};")
    product_deps.append(dep)
    frameworks.append(add(f"{package}:framework", f"isa = PBXBuildFile; productRef = {dep};"))
phases = [
    add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(sources)},); runOnlyForDeploymentPostprocessing = 0;"),
    add("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({','.join(frameworks)},); runOnlyForDeploymentPostprocessing = 0;"),
    add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(res)},); runOnlyForDeploymentPostprocessing = 0;"),
]
product = add("product", 'isa = PBXFileReference; explicitFileType = "wrapper.application"; includeInIndex = 0; path = "Free Flow.app"; sourceTree = BUILT_PRODUCTS_DIR;')
target = add("target", (
    f"isa = PBXNativeTarget; buildConfigurationList = {config_list('app', TARGET)}; buildPhases = ({','.join(phases)},); buildRules = (); "
    f"dependencies = (); name = {NAME}; packageProductDependencies = ({','.join(product_deps)},); "
    f"productName = {NAME}; productReference = {product}; productType = \"com.apple.product-type.application\";"))

products = add("products", f"isa = PBXGroup; children = ({product},); name = Products; sourceTree = \"<group>\";")
group = add("main-group", f"isa = PBXGroup; children = ({','.join(children)},{products},); sourceTree = \"<group>\";")
project_configs = [add(f"project-{m}", f"isa = XCBuildConfiguration; name = {m}; baseConfigurationReference = {base}; buildSettings = {{ {COMMON} }};") for m in ("Debug", "Release")]
project_list = add("project-configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
root = add("project", (
    "isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; }; "
    f"buildConfigurationList = {project_list}; compatibilityVersion = \"Xcode 16.0\"; developmentRegion = en; hasScannedForEncodings = 0; "
    f"knownRegions = (en,Base,); mainGroup = {group}; packageReferences = ({','.join(package_refs.values())},); productRefGroup = {products}; "
    f"projectDirPath = \"\"; projectRoot = \"\"; targets = ({target},);"))
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n"
                                        + "\n".join(objects) + f"\n\t}};\n\trootObject = {root};\n}}\n")

schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Free Flow.app" BlueprintName="{NAME}" ReferencedContainer="container:{NAME}.xcodeproj"/>'
(schemes / f"{NAME}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {NAME}.xcodeproj: {len(objects)} objects")

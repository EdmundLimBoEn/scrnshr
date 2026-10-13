#!/usr/bin/env python3
"""Generate the checked-in Xcode project with only Python's standard library."""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Scrnshr.xcodeproj"
WEBRTC_VERSION = "155.0.0"
WEBRTC_REVISION = "44f36788497f701bc8c0306de3a1c2511d56019d"


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value))


def serialize(value, level=0):
    indent = "\t" * level
    if isinstance(value, dict):
        body = "\n".join(
            f"{indent}\t{key} = {serialize(item, level + 1)};"
            for key, item in value.items()
        )
        return "{\n" + body + "\n" + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(
            f"{indent}\t{serialize(item, level + 1)},\n" for item in value
        ) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return quote(value)


class Project:
    def __init__(self):
        self.objects = {}

    def add(self, object_key, isa, **values):
        object_id = identifier(object_key)
        if object_id in self.objects:
            raise ValueError(f"Duplicate project object: {object_key}")
        self.objects[object_id] = {"isa": isa, **values}
        return object_id

    def configurations(self, name, common, debug=None, release=None):
        configs = []
        for configuration, extras in (("Debug", debug or {}), ("Release", release or {})):
            configs.append(self.add(
                f"{name}.{configuration}", "XCBuildConfiguration",
                buildSettings={**common, **extras}, name=configuration,
            ))
        return self.add(
            f"{name}.configurations", "XCConfigurationList",
            buildConfigurations=configs, defaultConfigurationIsVisible=0,
            defaultConfigurationName="Release",
        )


def sources(folder):
    return sorted(
        str(path.relative_to(ROOT)) for path in (ROOT / folder).rglob("*")
        if path.suffix in {".swift", ".m", ".mm"}
    )


def build_project():
    p = Project()
    source_sets = {
        "ScrnshrPhone": sources("native/Shared") + sources("native/iOS") + sources("native/Audio"),
        "ScrnshrMac": sources("native/Shared") + sources("native/Mac"),
        "ScrnshrTests": [path for path in sources("native/Tests") if not path.startswith("native/Tests/iOS/")],
        "ScrnshrPhoneTests": sources("native/Tests/iOS"),
    }
    file_paths = sorted(set(path for paths in source_sets.values() for path in paths))
    file_paths += sorted(
        str(path.relative_to(ROOT)) for path in (ROOT / "native").rglob("*")
        if path.suffix in {".h", ".plist", ".entitlements"}
    )
    file_refs = {}
    file_types = {
        ".swift": "sourcecode.swift", ".m": "sourcecode.c.objc",
        ".mm": "sourcecode.cpp.objcpp", ".h": "sourcecode.c.h",
        ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
    }
    for path in file_paths:
        file_refs[path] = p.add(
            path, "PBXFileReference", lastKnownFileType=file_types[Path(path).suffix],
            path=path, sourceTree="SOURCE_ROOT",
        )
    products = {}
    for name in source_sets:
        extension = ".xctest" if name.endswith("Tests") else ".app"
        products[name] = p.add(
            f"{name}.product", "PBXFileReference",
            explicitFileType="wrapper.cfbundle" if extension == ".xctest" else "wrapper.application",
            includeInIndex=0, path=name + extension, sourceTree="BUILT_PRODUCTS_DIR",
        )
    source_group = p.add("sources", "PBXGroup", children=list(file_refs.values()), name="Sources", sourceTree="<group>")
    products_group = p.add("products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
    main_group = p.add("main", "PBXGroup", children=[source_group, products_group], sourceTree="<group>")
    package = p.add(
        "WebRTC.package", "XCRemoteSwiftPackageReference",
        repositoryURL="https://github.com/stasel/WebRTC.git",
        requirement={"kind": "exactVersion", "version": WEBRTC_VERSION},
    )
    project_config = p.configurations("project", {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "CLANG_WARN_BOOL_CONVERSION": "YES", "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES", "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNUSED_FUNCTION": "YES", "GCC_WARN_UNUSED_VARIABLE": "YES",
        "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    }, debug={
        "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ONLY_ACTIVE_ARCH": "YES",
    }, release={
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O", "ONLY_ACTIVE_ARCH": "NO",
    })
    target_ids = {}
    for name, paths in source_sets.items():
        package_product = p.add(f"{name}.WebRTC", "XCSwiftPackageProductDependency", package=package, productName="WebRTC")
        package_build_file = p.add(f"{name}.WebRTC.link", "PBXBuildFile", productRef=package_product)
        build_files = [p.add(f"{name}.{path}.compile", "PBXBuildFile", fileRef=file_refs[path]) for path in paths]
        phases = [
            p.add(f"{name}.sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=build_files, runOnlyForDeploymentPostprocessing=0),
            p.add(f"{name}.frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[package_build_file], runOnlyForDeploymentPostprocessing=0),
            p.add(f"{name}.resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0),
        ]
        settings = {
            "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1",
            "MARKETING_VERSION": "0.1.0", "PRODUCT_NAME": "$(TARGET_NAME)",
            "PRODUCT_BUNDLE_IDENTIFIER": f"systems.edmundlim.scrnshr.{ {'ScrnshrPhone': 'phone', 'ScrnshrMac': 'mac', 'ScrnshrTests': 'tests', 'ScrnshrPhoneTests': 'phone-tests'}[name] }",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"] if name.startswith("ScrnshrPhone") else ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
        }
        dependencies = []
        if name == "ScrnshrPhone":
            settings.update({
                "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
                "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO", "TARGETED_DEVICE_FAMILY": "1",
                "INFOPLIST_FILE": "native/iOS/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "native/iOS/ScrnshrPhone.entitlements",
                "SWIFT_OBJC_BRIDGING_HEADER": "native/iOS/ScrnshrPhone-Bridging-Header.h",
            })
        elif name == "ScrnshrMac":
            settings.update({
                "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0",
                "INFOPLIST_FILE": "native/Mac/Info.plist",
                "CODE_SIGN_ENTITLEMENTS": "native/Mac/ScrnshrMac.entitlements",
                "ENABLE_HARDENED_RUNTIME": "YES",
            })
        else:
            host = "ScrnshrPhone" if name == "ScrnshrPhoneTests" else "ScrnshrMac"
            proxy = p.add(
                f"{name}.proxy", "PBXContainerItemProxy", containerPortal=identifier("project"),
                proxyType=1, remoteGlobalIDString=target_ids[host], remoteInfo=host,
            )
            dependencies.append(p.add(f"{name}.host", "PBXTargetDependency", target=target_ids[host], targetProxy=proxy))
            settings.update({"GENERATE_INFOPLIST_FILE": "YES", "BUNDLE_LOADER": "$(TEST_HOST)"})
            if name == "ScrnshrPhoneTests":
                settings.update({
                    "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "27.0",
                    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
                    "TARGETED_DEVICE_FAMILY": "1",
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/ScrnshrPhone.app/ScrnshrPhone",
                    "SWIFT_OBJC_BRIDGING_HEADER": "native/iOS/ScrnshrPhone-Bridging-Header.h",
                })
            else:
                settings.update({
                    "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0",
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/ScrnshrMac.app/Contents/MacOS/ScrnshrMac",
                })
        configs = p.configurations(name, settings)
        target_ids[name] = p.add(
            name, "PBXNativeTarget", buildConfigurationList=configs,
            buildPhases=phases, buildRules=[], dependencies=dependencies, name=name,
            packageProductDependencies=[package_product], productName=name, productReference=products[name],
            productType="com.apple.product-type.bundle.unit-test" if name.endswith("Tests") else "com.apple.product-type.application",
        )
    root_id = p.add(
        "project", "PBXProject",
        attributes={
            "BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2710",
            "TargetAttributes": {
                target_id: {
                    "CreatedOnToolsVersion": "27.1",
                    **({"TestTargetID": target_ids["ScrnshrPhone" if name == "ScrnshrPhoneTests" else "ScrnshrMac"]} if name.endswith("Tests") else {}),
                }
                for name, target_id in target_ids.items()
            },
        },
        buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0",
        developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"],
        mainGroup=main_group, packageReferences=[package], productRefGroup=products_group,
        projectDirPath="", projectRoot="", targets=list(target_ids.values()),
    )
    project = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": p.objects, "rootObject": root_id}
    contents = "// !$*UTF8*$!\n" + serialize(project) + "\n"
    return contents, target_ids


def scheme(name, target_ids):
    document = ET.Element("Scheme", {"LastUpgradeVersion": "2710", "version": "1.7"})
    build = ET.SubElement(document, "BuildAction", {"parallelizeBuildables": "YES", "buildImplicitDependencies": "YES"})
    entries = ET.SubElement(build, "BuildActionEntries")
    entry = ET.SubElement(entries, "BuildActionEntry", {
        "buildForTesting": "YES", "buildForRunning": "YES", "buildForProfiling": "YES",
        "buildForArchiving": "YES", "buildForAnalyzing": "YES",
    })

    def reference(parent, target):
        return ET.SubElement(parent, "BuildableReference", {
            "BuildableIdentifier": "primary", "BlueprintIdentifier": target_ids[target],
            "BuildableName": target + (".xctest" if target.endswith("Tests") else ".app"),
            "BlueprintName": target, "ReferencedContainer": "container:Scrnshr.xcodeproj",
        })

    reference(entry, name)
    test_target = "ScrnshrTests" if name == "ScrnshrMac" else "ScrnshrPhoneTests"
    test_entry = ET.SubElement(entries, "BuildActionEntry", {
        "buildForTesting": "YES", "buildForRunning": "NO", "buildForProfiling": "NO",
        "buildForArchiving": "NO", "buildForAnalyzing": "NO",
    })
    reference(test_entry, test_target)
    test = ET.SubElement(document, "TestAction", {
        "buildConfiguration": "Debug", "selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
        "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "shouldUseLaunchSchemeArgsEnv": "YES",
        "codeCoverageEnabled": "YES",
    })
    testables = ET.SubElement(test, "Testables")
    testable = ET.SubElement(testables, "TestableReference", {"skipped": "NO", "parallelizable": "NO"})
    reference(testable, test_target)
    for action, configuration in (("LaunchAction", "Debug"), ("ProfileAction", "Release")):
        element = ET.SubElement(document, action, {"buildConfiguration": configuration, "useCustomWorkingDirectory": "NO"})
        if action == "LaunchAction":
            element.attrib.update({"selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB", "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB", "launchStyle": "0", "ignoresPersistentStateOnLaunch": "NO", "debugDocumentVersioning": "YES", "debugServiceExtension": "internal", "allowLocationSimulation": "YES"})
        runnable = ET.SubElement(element, "BuildableProductRunnable", {"runnableDebuggingMode": "0"})
        reference(runnable, name)
    ET.SubElement(document, "AnalyzeAction", {"buildConfiguration": "Debug"})
    ET.SubElement(document, "ArchiveAction", {"buildConfiguration": "Release", "revealArchiveInOrganizer": "YES"})
    ET.indent(document, space="  ")
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(document, encoding="unicode") + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if checked-in files differ from generation")
    args = parser.parse_args()
    project, targets = build_project()
    outputs = {PROJECT / "project.pbxproj": project}
    for name in ("ScrnshrPhone", "ScrnshrMac"):
        outputs[PROJECT / "xcshareddata" / "xcschemes" / f"{name}.xcscheme"] = scheme(name, targets)
    outputs[PROJECT / "project.xcworkspace" / "contents.xcworkspacedata"] = '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:" /></Workspace>\n'
    outputs[PROJECT / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"] = json.dumps({
        "pins": [{"identity": "webrtc", "kind": "remoteSourceControl", "location": "https://github.com/stasel/WebRTC.git", "state": {"revision": WEBRTC_REVISION, "version": WEBRTC_VERSION}}], "version": 2,
    }, indent=2) + "\n"
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        print("Project is stale. Run python3 scripts/generate-project.py.", file=sys.stderr)
        print("\n".join(stale), file=sys.stderr)
        return 1
    print("Xcode project matches native sources." if args.check else "Generated Scrnshr.xcodeproj.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

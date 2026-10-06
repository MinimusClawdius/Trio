#!/usr/bin/env python3
"""
Minimal script to add Pebble files to the fresh Trio pbxproj.
Run from Trio repo root.
"""

import re
import random
import string

def gen_id():
    return ''.join(random.choices('0123456789ABCDEF', k=24))

PBX = "Trio.xcodeproj/project.pbxproj"

pebble_swift = [
    "Trio/Sources/Services/PebbleManager/PebbleAppMessageKeys.swift",
    "Trio/Sources/Services/PebbleManager/PebbleBLEBridge.swift",
    "Trio/Sources/Services/PebbleManager/PebbleCommandConfirmationView.swift",
    "Trio/Sources/Services/PebbleManager/PebbleCommandManager.swift",
    "Trio/Sources/Services/PebbleManager/PebbleDataBridge.swift",
    "Trio/Sources/Services/PebbleManager/PebbleLocalAPIServer.swift",
    "Trio/Sources/Services/PebbleManager/PebbleManager.swift",
    "Trio/Sources/Services/PebbleService/PebbleServiceFormView.swift",
    "Trio/Sources/Services/PebbleService/PebbleServiceManager.swift",
    "Trio/Sources/Services/PebbleService/PebbleService.swift",
    "Trio/Sources/Services/PebbleService/PebbleService+UI.swift",
]

with open(PBX) as f:
    txt = f.read()

# Services group ID (from inspection)
SERVICES_GROUP = "3811DE9125C9D88200A708ED"

# Main app sources phase
MAIN_SOURCES = "388E595425AD948C0019842D"

# Generate IDs
file_refs = {}
build_files = {}
for path in pebble_swift:
    fname = path.split("/")[-1]
    fid = gen_id()
    bid = gen_id()
    file_refs[path] = (fid, fname)
    build_files[path] = (bid, fname, fid)

# Add FileReferences (insert before End PBXFileReference section)
fr_section = []
for path, (fid, fname) in file_refs.items():
    fr_section.append(f'\t\t{fid} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{fname}"; sourceTree = "<group>"; }};')

end_fr = txt.find("/* End PBXFileReference section */")
if end_fr != -1:
    txt = txt[:end_fr] + "\n".join(fr_section) + "\n" + txt[end_fr:]
    print("Added FileReferences")

# Add BuildFiles
bf_section = []
for path, (bid, fname, fid) in build_files.items():
    bf_section.append(f'\t\t{bid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid}; }};')

end_bf = txt.find("/* End PBXBuildFile section */")
if end_bf != -1:
    txt = txt[:end_bf] + "\n".join(bf_section) + "\n" + txt[end_bf:]
    print("Added BuildFiles")

# Add two Pebble groups under Services
mgr_gid = gen_id()
svc_gid = gen_id()

# Find Services children and append
services_re = re.compile(rf"({SERVICES_GROUP} /\* Services \*/ = \{{[^}}]*?children = \()([^)]*)(\);)", re.DOTALL)
m = services_re.search(txt)
if m:
    kids = m.group(2).rstrip()
    if kids:
        kids += ",\n"
    kids += f"\t\t\t\t{mgr_gid} /* PebbleManager */,\n\t\t\t\t{svc_gid} /* PebbleService */,"
    txt = txt[:m.start(2)] + kids + txt[m.end(2):]
    print("Updated Services children")

# Add group definitions
group_defs = f"""
\t\t{mgr_gid} /* PebbleManager */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleManager.swift"][0]} /* PebbleManager.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleAppMessageKeys.swift"][0]} /* PebbleAppMessageKeys.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleBLEBridge.swift"][0]} /* PebbleBLEBridge.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleCommandConfirmationView.swift"][0]} /* PebbleCommandConfirmationView.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleCommandManager.swift"][0]} /* PebbleCommandManager.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleDataBridge.swift"][0]} /* PebbleDataBridge.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleManager/PebbleLocalAPIServer.swift"][0]} /* PebbleLocalAPIServer.swift */,
\t\t\t);
\t\t\tpath = "PebbleManager";
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{svc_gid} /* PebbleService */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleService/PebbleService.swift"][0]} /* PebbleService.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleService/PebbleServiceManager.swift"][0]} /* PebbleServiceManager.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleService/PebbleServiceFormView.swift"][0]} /* PebbleServiceFormView.swift */,
\t\t\t\t{file_refs["Trio/Sources/Services/PebbleService/PebbleService+UI.swift"][0]} /* PebbleService+UI.swift */,
\t\t\t);
\t\t\tpath = "PebbleService";
\t\t\tsourceTree = "<group>";
\t\t}};
"""

end_group = txt.find("/* End PBXGroup section */")
if end_group != -1:
    txt = txt[:end_group] + group_defs + txt[end_group:]
    print("Added group defs")

# Add BuildFiles to main Sources phase
main_re = re.compile(rf"({MAIN_SOURCES} /* Sources */ = \{{[^}}]*?files = \()([^)]*)(\);)", re.DOTALL)
m = main_re.search(txt)
if m:
    files_part = m.group(2).rstrip()
    if files_part:
        files_part += ",\n"
    for path in pebble_swift:
        bid = build_files[path][0]
        fname = build_files[path][1]
        files_part += f"\t\t\t\t{bid} /* {fname} in Sources */,\n"
    txt = txt[:m.start(2)] + files_part + txt[m.end(2):]
    print("Added to main Sources phase")

with open(PBX, "w") as f:
    f.write(txt)

print("pbxproj updated. Now run the repair script if needed.")

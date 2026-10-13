#!/usr/bin/env python3
"""
Script to add Pebble integration files (and related view files) to the Trio Xcode project.
Run from Trio repo root.
It performs text-level insertion of FileReferences, BuildFiles, Groups, and wires them into Services + Subviews groups
and the main Sources build phase.
"""

import re
import random

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

# Additional files that live under Modules/Settings/View (will be added to Subviews group)
view_swift = [
    "Trio/Sources/Modules/Settings/View/PebbleServiceConfigViews.swift",
    "Trio/Sources/Modules/Settings/View/PebbleServiceStartView.swift",
]

all_new = pebble_swift + view_swift

with open(PBX) as f:
    txt = f.read()

# Services group ID (from inspection)
SERVICES_GROUP = "3811DE9125C9D88200A708ED"

# Subviews group ID (under Settings -> View)
SUBVIEWS_GROUP = "DD1745112C54168300211FAC"

# Main app sources phase ID
MAIN_SOURCES = "388E595425AD948C0019842D"

# Generate IDs
file_refs = {}
build_files = {}
for path in all_new:
    fname = path.split("/")[-1]
    fid = gen_id()
    bid = gen_id()
    file_refs[path] = (fid, fname)
    build_files[path] = (bid, fname, fid)

# Separate for insertion logic
pebble_file_refs = {p: file_refs[p] for p in pebble_swift}
view_file_refs = {p: file_refs[p] for p in view_swift}

# Add FileReferences (insert before End PBXFileReference section)
fr_section = []
for path, (fid, fname) in file_refs.items():
    fr_section.append(f'\t\t{fid} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{fname}"; sourceTree = "<group>"; }};')

end_fr = txt.find("/* End PBXFileReference section */")
if end_fr != -1:
    txt = txt[:end_fr] + "\n".join(fr_section) + "\n" + txt[end_fr:]
    print("Added FileReferences for", len(file_refs), "files")
else:
    print("ERROR: Could not find End PBXFileReference section")

# Add BuildFiles
bf_section = []
for path, (bid, fname, fid) in build_files.items():
    bf_section.append(f'\t\t{bid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {fid}; }};')

end_bf = txt.find("/* End PBXBuildFile section */")
if end_bf != -1:
    txt = txt[:end_bf] + "\n".join(bf_section) + "\n" + txt[end_bf:]
    print("Added BuildFiles for", len(build_files), "files")
else:
    print("ERROR: Could not find End PBXBuildFile section")

# Add two Pebble groups under Services
mgr_gid = gen_id()
svc_gid = gen_id()

services_re = re.compile(rf"({SERVICES_GROUP} /\* Services \*/ = \{{[^}}]*?children = \()([^)]*)(\);)", re.DOTALL)
m = services_re.search(txt)
if m:
    kids = m.group(2).rstrip()
    if kids and not kids.rstrip().endswith(","):
        kids += ",\n"
    kids += f"\t\t\t\t{mgr_gid} /* PebbleManager */,\n\t\t\t\t{svc_gid} /* PebbleService */,"
    txt = txt[:m.start(2)] + kids + txt[m.end(2):]
    print("Updated Services children with Pebble groups")
else:
    print("WARNING: Could not find Services group children to update")

# Add group definitions for Pebble* (insert before End PBXGroup section)
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
    print("Added PebbleManager and PebbleService group defs")
else:
    print("ERROR: Could not find End PBXGroup section")

# Add the view files to the Subviews group children
sub_re = re.compile(rf"({SUBVIEWS_GROUP} /\* Subviews \*/ = \{{[^}}]*?children = \()([^)]*)(\);)", re.DOTALL)
m = sub_re.search(txt)
if m:
    kids = m.group(2).rstrip()
    if kids and not kids.rstrip().endswith(","):
        kids += ",\n"
    for path in view_swift:
        fid = file_refs[path][0]
        fname = file_refs[path][1]
        kids += f"\t\t\t\t{fid} /* {fname} */,\n"
    txt = txt[:m.start(2)] + kids + txt[m.end(2):]
    print("Updated Subviews children with Pebble view files")
else:
    print("WARNING: Could not find Subviews group to add view files")

# Add BuildFiles to main Sources phase (robust insertion at start of list)
phase_marker = MAIN_SOURCES + " /* Sources */ = {"
phase_idx = txt.find(phase_marker)
if phase_idx != -1:
    files_start = txt.find("files = (", phase_idx)
    if files_start != -1:
        # Insert right after the opening "(\n"
        insert_pos = files_start + len("files = (")
        nl = txt.find("\n", insert_pos)
        if nl != -1:
            insert_pos = nl + 1
        new_lines = ""
        for path in all_new:
            bid = build_files[path][0]
            fname = build_files[path][1]
            new_lines += f"\t\t\t\t{bid} /* {fname} in Sources */,\n"
        txt = txt[:insert_pos] + new_lines + txt[insert_pos:]
        print("Added all new BuildFile refs to main Sources phase (robust)")
    else:
        print("WARNING: found phase ID but not files = (")
else:
    print("WARNING: Could not locate main sources phase ID")

with open(PBX, "w") as f:
    f.write(txt)

print("pbxproj updated with Pebble files.")
print("Run the repair script (if any) or validate the project.")
print("Then commit the pbxproj change.")
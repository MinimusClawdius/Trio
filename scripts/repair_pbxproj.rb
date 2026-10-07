#!/usr/bin/env ruby
# Repair script for Xcode project file after upstream merges.
# Fixes orphaned FileReferences and BuildFiles that cause
# "Consistency issue: no parent for object" during fastlane update_code_signing_settings.
#
# This version does a broad cleanup of ANY broken BuildFile across the project
# before attempting to save, then re-wires the critical LiveActivity files.
#
# Run with: bundle exec ruby scripts/repair_pbxproj.rb

require "xcodeproj"

project_path = ENV["GITHUB_WORKSPACE"] ? File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj") : "Trio.xcodeproj"
puts "Repairing project at #{project_path}"

# ============================================================
# Pre-load raw text repair for known text-level corruption patterns
# (especially the "path = Services;" jammed inside Services children array)
# This fixes cases where the high-level Xcodeproj gem loads a partially
# corrupted file and the later re-serialization doesn't fully clean it.
# ============================================================
pbx_file = if ENV["GITHUB_WORKSPACE"]
  File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj", "project.pbxproj")
else
  "Trio.xcodeproj/project.pbxproj"
end

if File.exist?(pbx_file)
  raw = File.read(pbx_file)
  original_size = raw.size
  fixed = false

  # Known jam: inside the Services group children list, a stray
  # "path = Services;" / sourceTree block appears before the proper closing
  # of the children array. This produces "Array missing ',' in between objects".
  #
  # Pattern seen:
  #     38E8754D... /* WatchManager */,
  # 			path = Services;
  # 			sourceTree = "<group>";
  # 		};
  #
  # We insert the missing ");" to close the children array.
  if raw =~ /WatchManager \*/m && raw =~ /path = Services;/m
    # Try to fix the specific jammed fragment
    # Replace the bad sequence with a properly closed children list
    new_raw = raw.gsub(
      /(,\s*\n\s*38E8754D[0-9A-Fa-f]+ \/\* WatchManager \*\/,\s*\n)(\s*path = Services;\s*\n\s*sourceTree = "<group>";\s*\n\s*\};)/m,
      "\\1\t\t\t);\n\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied raw text fix for Services children jam (WatchManager -> path=Services)"
    end
  end

  # More general fallback: any occurrence of bare "path = Services;" right after
  # a child entry inside what should be a children array, insert ");" before it.
  if raw =~ /,\s*\n\s*path = Services;\s*\n\s*sourceTree = "<group>";/m
    new_raw = raw.gsub(
      /(,\s*\n)(\s*path = Services;\s*\n\s*sourceTree = "<group>";)/m,
      "\\1\t\t\t);\n\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied general raw text fix for Services path=Services jam"
    end
  end

  if fixed && raw.size != original_size
    File.write(pbx_file, raw)
    puts "Wrote pre-fixed project.pbxproj (size #{raw.size} from #{original_size})"
  else
    puts "No Services jam detected in raw pre-fix pass (or already clean)"
  end

  # === ROBUST ORPHAN STRIPPER (line-based, very reliable) ===
  # Removes any sequence of bare "children = ( ... ); sourceTree... };" that is not
  # inside a proper PBXGroup definition. This is the corruption introduced by
  # previous Pebble-related merges.
  end_marker = "/* End PBXGroup section */"
  if raw.include?(end_marker)
    before, after = raw.split(end_marker, 2)

    lines = before.split("\n")
    out = []
    i = 0
    removed = 0
    while i < lines.size
      line = lines[i]
      stripped = line.strip

      # Detect start of a potential orphan block
      if stripped == "children = ("
        # Look ahead for the classic 4-line orphan pattern
        if i + 3 < lines.size
          l1 = lines[i+1].strip
          l2 = lines[i+2].strip
          l3 = lines[i+3].strip
          if l1 == ");" && l2.start_with?('sourceTree = "<group>"') && l3 == "};"
            # Check previous line — if it does not look like end of a real group, skip the block
            prev = i > 0 ? lines[i-1].strip : ""
            is_real_group_close = prev.end_with?("= {") || prev.include?("isa = PBXGroup") || prev =~ /\/\* .* \*\/ = \{/
            if !is_real_group_close
              # This is an orphan — skip 4 lines
              removed += 1
              i += 4
              next
            end
          end
        end
      end

      out << line
      i += 1
    end

    before = out.join("\n")
    raw = before + end_marker + after

    if removed > 0
      puts "  ROBUST ORPHAN STRIPPER: removed #{removed} orphan group block(s)"
      File.write(pbx_file, raw)
    else
      puts "  ROBUST ORPHAN STRIPPER: no orphans detected by line scanner"
    end
  end
else
  puts "WARNING: Could not find pbxproj for pre-fix at #{pbx_file}"
end

# Try to open, with one last aggressive orphan strip + retry if it fails
begin
  project = Xcodeproj::Project.open(project_path)
rescue => e
  puts "Initial open failed: #{e.class} - #{e.message[0..200]}"
  puts "Attempting one more aggressive orphan strip and retry open..."

  if File.exist?(pbx_file)
    raw_retry = File.read(pbx_file)
    end_m = "/* End PBXGroup section */"
    if raw_retry.include?(end_m)
      b, a = raw_retry.split(end_m, 2)
      lines = b.split("\n")
      out = []
      i = 0
      while i < lines.size
        if lines[i].strip == "children = (" && i + 3 < lines.size
          l1 = lines[i+1].strip
          l2 = lines[i+2].strip
          l3 = lines[i+3].strip
          if l1 == ");" && l2.start_with?('sourceTree = "<group>"') && l3 == "};"
            prev = i > 0 ? lines[i-1].strip : ""
            unless prev.end_with?("= {") || prev.include?("isa = PBXGroup")
              i += 4
              next
            end
          end
        end
        out << lines[i]
        i += 1
      end
      File.write(pbx_file, out.join("\n") + end_m + a)
      puts "Extra aggressive strip written for retry"
    end
  end

  project = Xcodeproj::Project.open(project_path)
  puts "Retry open succeeded after extra strip"
end

# ============================================================
# Build set of FileRef UUIDs that are properly children of some group
# (many corruptions leave FileRefs referenced by BuildFiles but missing from groups)
# ============================================================
require 'set' unless defined?(Set)

grouped_uuids = Set.new
project.objects.each do |uuid, obj|
  next if obj.nil?
  next unless obj.respond_to?(:isa) && obj.isa == "PBXGroup" && obj.respond_to?(:children)
  obj.children.each { |c| grouped_uuids << c.uuid if c.respond_to?(:uuid) }
end
puts "Found #{grouped_uuids.size} FileRefs properly placed in groups."

# ============================================================
# Aggressive cleanup of broken BuildFiles + orphaned FileRefs
# Walk ALL PBXBuildFile objects (not just via phases) and remove anything broken
# ============================================================
puts "Scanning ALL BuildFiles for broken parents or orphaned FileRefs..."

to_delete_uuids = []

project.objects.each do |uuid, obj|
  next if obj.nil?
  next unless obj.is_a?(Xcodeproj::Project::Object::PBXBuildFile)

  fr = obj.file_ref rescue nil
  path = fr&.path rescue "unknown"

  broken = false

  begin
    obj.parent
  rescue => e
    if e.message =~ /no parent|Consistency issue/i
      puts "  Broken BuildFile.parent: #{path}"
      broken = true
    end
  end

  if fr
    begin
      fr.parent
    rescue => e
      if e.message =~ /no parent|Consistency issue/i
        puts "  Broken FileRef.parent: #{path}"
        broken = true
      end
    end

    unless grouped_uuids.include?(fr.uuid)
      puts "  Orphan FileRef (not in any group): #{path}"
      broken = true
    end
  end

  to_delete_uuids << uuid if broken
end

removed = 0
to_delete_uuids.each do |uuid|
  bf = project.objects[uuid] rescue nil
  path = (bf&.file_ref&.path rescue "unknown")

  # Try to strip from phases first
  project.targets.each do |t|
    [t.source_build_phase, t.resources_build_phase].compact.each do |ph|
      if ph && ph.files.any? { |b| b.uuid == uuid }
        ph.remove_file_reference(bf.file_ref) rescue ph.files.delete(bf)
      end
    end
  end

  begin
    project.objects.delete(uuid)
    puts "  Deleted broken BuildFile: #{path}"
    removed += 1
  rescue => e
    puts "  Delete failed for #{path}: #{e}"
  end
end

puts "Removed #{removed} broken BuildFile(s)."

# ============================================================
# 2. Now re-attach the LiveActivity core files properly
# ============================================================

live_group = project.main_group.recursive_children_groups.find do |g|
  (g.path && g.path == "LiveActivity") || (g.name && g.name == "LiveActivity")
end

if live_group
  puts "Found LiveActivity group: #{live_group.name || live_group.path}"
else
  puts "WARNING: Could not find LiveActivity group. Using main group."
  live_group = project.main_group
end

live_target = project.targets.find do |t|
  name = t.name.to_s
  prod = (t.product_name.to_s rescue "")
  (name.downcase.include?("liveactivity") || prod.downcase.include?("liveactivity")) ||
    (t.product_reference && t.product_reference.path && t.product_reference.path.include?("LiveActivity"))
end

if live_target
  puts "Found LiveActivity target: #{live_target.name}"
  source_phase = live_target.source_build_phase

  problematic_files = [
    "LiveActivity/LiveActivity.swift",
    "LiveActivity/LiveActivityBundle.swift",
    "LiveActivity/LiveActivity+Helper.swift",
    "LiveActivity/LiveActivityManager.swift"
  ]

  problematic_files.each do |rel_path|
    next unless File.exist?(rel_path)

    basename = File.basename(rel_path)
    file_ref = project.files.find { |f| f.path == basename || (f.path && f.path.end_with?(basename)) }

    if file_ref
      unless live_group.children.include?(file_ref)
        puts "Re-attaching #{basename} FileRef to LiveActivity group"
        live_group.children << file_ref
      end

      if source_phase
        # Make sure it's not still there as a stale one
        source_phase.files.each do |bf|
          if bf.file_ref == file_ref
            source_phase.remove_file_reference(file_ref) rescue nil
          end
        end

        puts "Re-adding #{basename} to LiveActivityExtension via proper API"
        source_phase.add_file_reference(file_ref, true)
      end
    else
      puts "Adding fresh FileRef for #{basename}"
      new_ref = project.add_file(rel_path, live_group)
      source_phase.add_file_reference(new_ref, true) if source_phase
    end
  end
else
  puts "WARNING: Could not find LiveActivity target."
end

# ============================================================
# 3. Final save
# ============================================================

puts "Saving repaired project..."
project.save
puts "Project saved successfully. Repair complete."


# ============================================================
# 4. Pebble integration - clean remove then add using xcodeproj API
#    This guarantees the pbxproj text is emitted cleanly without
#    any previous text-edit corruption or missing commas.
# ============================================================
if ENV["SKIP_PEBBLE"] == "1"
  puts "SKIP_PEBBLE=1 set — skipping Pebble addition for diagnostic run."
else
  puts "Performing clean Pebble integration (remove stale + fresh add)..."

  services_group = project.main_group.recursive_children_groups.find do |g|
    (g.path && g.path == "Services") || (g.name && g.name == "Services")
  end

  if services_group.nil?
    puts "WARNING: Services group not found, creating it"
    services_group = project.new_group("Services", "Services")
    project.main_group.children << services_group
  end

  # Remove any existing Pebble subgroups and their file refs to start clean
  ["PebbleManager", "PebbleService"].each do |gname|
  existing = services_group.children.find { |c| (c.respond_to?(:path) && c.path == gname) || (c.respond_to?(:name) && c.name == gname) }
  if existing
    # Remove file refs from build phases first
    project.targets.each do |t|
      phase = t.source_build_phase
      if phase
        existing.children.to_a.each do |fr|
          phase.files.each do |bf|
            if bf.file_ref == fr
              phase.remove_file_reference(fr) rescue nil
            end
          end
        end
      end
    end
    services_group.children.delete(existing)
    puts "Removed stale #{gname} group"
  end
end

# Create fresh subgroups
pm_group = project.new_group("PebbleManager", "PebbleManager")
services_group.children << pm_group
ps_group = project.new_group("PebbleService", "PebbleService")
services_group.children << ps_group
puts "Created fresh Pebble subgroups"

pebble_files = [
  { path: "Trio/Sources/Services/PebbleManager/PebbleManager.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleDataBridge.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleCommandManager.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleCommandConfirmationView.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleLocalAPIServer.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleAppMessageKeys.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleManager/PebbleBLEBridge.swift", group: pm_group },
  { path: "Trio/Sources/Services/PebbleService/PebbleService.swift", group: ps_group },
  { path: "Trio/Sources/Services/PebbleService/PebbleServiceManager.swift", group: ps_group },
  { path: "Trio/Sources/Services/PebbleService/PebbleServiceFormView.swift", group: ps_group },
  { path: "Trio/Sources/Services/PebbleService/PebbleService+UI.swift", group: ps_group }
]

main_target = project.targets.find { |t| t.name.to_s == "Trio" }
source_phase = main_target&.source_build_phase

pebble_files.each do |entry|
  rel = entry[:path]
  target_group = entry[:group]
  next unless File.exist?(rel)

  basename = File.basename(rel)
  # Always add fresh via the API (it handles quoting for + in filenames)
  file_ref = project.add_file(rel, target_group)
  puts "Added (or re-added) #{basename} via add_file"

  if source_phase && file_ref
    # Ensure it is in the build phase
    unless source_phase.files.any? { |bf| (bf.file_ref == file_ref) rescue false }
      source_phase.add_file_reference(file_ref, true)
      puts "Wired #{basename} to main target source phase"
    end
  end
end

puts "Pebble clean integration complete."
end   # end of if ENV["SKIP_PEBBLE"] == "1" else block
# ============================================================
# 5. Force clean re-serialization of Appearance and Network groups
#    (the text corruption "Network = {" inside Appearance children was introduced by
#     previous python text edits; re-creating the groups via API produces clean output)
# ============================================================
puts "Force-cleaning Appearance and Network groups via API..."

appearance = project.main_group.recursive_children_groups.find do |g|
  (g.path && g.path == "Appearance") || (g.name && g.name == "Appearance")
end

if appearance
  puts "Found Appearance group"
  # Find or create Network as a proper child group (not embedded)
  network = appearance.children.find { |c| (c.respond_to?(:path) && c.path == "Network") || (c.respond_to?(:name) && c.name == "Network") }
  if network.nil?
    network = project.new_group("Network", "Network")
    appearance.children << network
    puts "Added Network as child of Appearance"
  end

  # Collect any file refs that should be in Network (from the current broken state they may be listed under Appearance)
  # For now, just ensure the group exists and is referenced; the original files should already have refs.

  # To force clean text, remove and re-add the Appearance group (this re-serializes its children list cleanly)
  parent_of_appearance = appearance.parent || project.main_group
  if parent_of_appearance.children.include?(appearance)
    parent_of_appearance.children.delete(appearance)
    new_appearance = project.new_group("Appearance", "Appearance")
    # Copy children
    appearance.children.to_a.each { |c| new_appearance.children << c }
    parent_of_appearance.children << new_appearance
    puts "Re-created Appearance group to force clean children list"
  end
else
  puts "Appearance group not found (unexpected)"
end

puts "Appearance/Network clean re-serialization complete."

# ============================================================
# 6. Force re-creation of Services group to ensure clean children list after Pebble additions
#    (prevents "Array missing ',' " from any insertion order or previous state)
# ============================================================
puts "Force re-serializing Services group for clean output..."

services = project.main_group.recursive_children_groups.find do |g|
  (g.path && g.path == "Services") || (g.name && g.name == "Services")
end

if services
  parent = services.parent || project.main_group
  if parent.children.include?(services)
    # Collect current children
    kids = services.children.to_a
    parent.children.delete(services)
    new_services = project.new_group("Services", "Services")
    kids.each { |k| new_services.children << k }
    parent.children << new_services
    puts "Re-created Services group with #{kids.size} children for clean plist"
  end
end

puts "Services re-serialization complete."

puts "Final save after all repairs..."
project.save
puts "Final save complete."

# ============================================================
# 7. Aggressive re-serialization of all top-level groups to flush any
#    remaining text corruption from prior edits (Services, Appearance, etc.)
# ============================================================
puts "Aggressive re-serialization of key groups..."

def force_recreate_group(project, group)
  return unless group
  parent = group.parent || project.main_group
  return unless parent.children.include?(group)
  kids = group.children.to_a
  name = group.name || group.path || "Group"
  parent.children.delete(group)
  new_g = project.new_group(name, group.path || name)
  kids.each { |k| new_g.children << k rescue nil }
  parent.children << new_g
  puts "  Re-created #{name}"
end

# Re-create known problematic groups
["Services", "Appearance", "Network", "LiveActivity"].each do |gname|
  g = project.main_group.recursive_children_groups.find do |gg|
    (gg.path && gg.path == gname) || (gg.name && gg.name == gname)
  end
  force_recreate_group(project, g) if g
end

# Also re-create the main target source phase files array to flush any
# corruption in the "files" list of PBXSourcesBuildPhase (common source of
# "Array missing ',' in between objects" during update_project_team).
main_t = project.targets.find { |t| t.name.to_s == "Trio" }
if main_t && main_t.source_build_phase
  phase = main_t.source_build_phase
  puts "Force-refreshing main Trio source_build_phase files array (#{phase.files.size} current entries)..."
  # Collect current file_refs
  current_refs = phase.files.map { |bf| bf.file_ref }.compact
  # Remove all and re-add to force clean serialization of the phase's files array
  phase.files.clear rescue nil
  current_refs.each do |fr|
    begin
      phase.add_file_reference(fr, true)
    rescue => e
      puts "  Warning re-adding ref #{fr.path rescue 'unknown'}: #{e}"
    end
  end
  puts "  Refreshed source phase with #{current_refs.size} file references."
end

puts "Aggressive re-serialization done. Final save..."
project.save
puts "Saved after aggressive re-creation."

# One more round-trip to be sure
puts "Round-trip open/save to force clean plist emission..."
project = Xcodeproj::Project.open(project_path)
project.save
puts "Round-trip save complete."

# ============================================================
# 8. Post-save validation: read the raw pbxproj and fail loudly
#    if any known text corruption patterns remain.
#    Uses simple, robust checks to avoid regex escaping issues.
# ============================================================
puts "Running post-save raw text validation for corruption patterns..."

pbx_path = File.join(File.dirname(project_path), "project.pbxproj")
unless File.exist?(pbx_path)
  pbx_path = File.join(project_path, "project.pbxproj") if Dir.exist?(project_path)
end

# Final robust orphan strip right before validation/Fastlane sees the file
# (call the same logic one last time)
if File.exist?(pbx_path)
  raw_final = File.read(pbx_path)
  end_m = "/* End PBXGroup section */"
  if raw_final.include?(end_m)
    b, a = raw_final.split(end_m, 2)
    lines = b.split("\n")
    out = []
    i = 0
    removed = 0
    while i < lines.size
      line = lines[i]
      stripped = line.strip
      if stripped == "children = ("
        if i + 3 < lines.size
          l1 = lines[i+1].strip
          l2 = lines[i+2].strip
          l3 = lines[i+3].strip
          if l1 == ");" && l2.start_with?('sourceTree = "<group>"') && l3 == "};"
            prev = i > 0 ? lines[i-1].strip : ""
            is_real = prev.end_with?("= {") || prev.include?("isa = PBXGroup")
            if !is_real
              removed += 1
              i += 4
              next
            end
          end
        end
      end
      out << line
      i += 1
    end
    if removed > 0
      File.write(pbx_path, out.join("\n") + end_m + a)
      puts "  FINAL ROBUST STRIP (end of repair): removed #{removed} orphan block(s)"
    end
  end
end

if File.exist?(pbx_path)
  raw_final = File.read(pbx_path)
  end_m = "/* End PBXGroup section */"
  if raw_final.include?(end_m)
    b, a = raw_final.split(end_m, 2)
    lines = b.split("\n")
    out = []
    i = 0
    removed = 0
    while i < lines.size
      line = lines[i]
      stripped = line.strip
      if stripped == "children = ("
        if i + 3 < lines.size
          l1 = lines[i+1].strip
          l2 = lines[i+2].strip
          l3 = lines[i+3].strip
          if l1 == ");" && l2.start_with?('sourceTree = "<group>"') && l3 == "};"
            prev = i > 0 ? lines[i-1].strip : ""
            is_real = prev.end_with?("= {") || prev.include?("isa = PBXGroup")
            if !is_real
              removed += 1
              i += 4
              next
            end
          end
        end
      end
      out << line
      i += 1
    end
    raw_final = out.join("\n") + end_m + a
    if removed > 0
      File.write(pbx_path, raw_final)
      puts "  ROBUST FINAL ORPHAN STRIP: removed #{removed} block(s) before validation"
    end
  end
end

if File.exist?(pbx_path)
  raw = File.read(pbx_path)
  found_bad = false
  context = nil

  # Simple string checks for known jams (from historical python/text edits)
  if raw.include?(");path = Services") || raw.include?("); path = Services")
    found_bad = true
    context = raw[raw.index(");path = Services") - 150 .. raw.index(");path = Services") + 300] rescue "context extract failed"
    puts "!!! Found Services jam pattern"
  # Stronger check for the exact corruption seen in run 37610354656:
  # bare "path = Services;" line appearing inside a children = ( ... ) array
  if !found_bad && raw =~ /,\s*\n\s*path = Services;\s*\n\s*sourceTree = "<group>";/m
    found_bad = true
    idx = raw.index("path = Services;") || 0
    context = raw[[idx-220,0].max .. [idx+280, raw.size].min] rescue nil
    puts "!!! Found bare 'path = Services;' inside children array (Services group corruption)"
  end

  end

  if !found_bad && raw =~ /AppearanceManager.*Network \*/m
    # Look for the specific jammed "Network */ = {" right after Appearance entries
    if raw.include?("Network */ = {") && raw =~ /3811DE9.*AppearanceManager.*Network \*/m
      found_bad = true
      idx = raw.index("Network */ = {")
      context = raw[[idx-250,0].max .. [idx+400, raw.size].min] rescue nil
      puts "!!! Found jammed Network group definition (likely inside Appearance children)"
    end
  end

  # Check ONLY for the specific known-bad Pebble GIDs from prior corruption (not the broad 3811DE9* prefix,
  # which is legitimately used by many current Appearance/Network files).
  if !found_bad && (raw =~ /BEA75ECA|51C9D754/)
    found_bad = true
    puts "!!! Found specific old bad Pebble GID in raw pbxproj"
  end

  # Explicit check for the trailing orphan fragments that kill the Nanaimo parser
  orphan_count = raw.scan(/children = \(\s*\);\s*sourceTree = "<group>";\s*\};/).size
  if orphan_count > 0
    found_bad = true
    puts "!!! Found #{orphan_count} bare/orphaned group fragments (the exact cause of 'additional characters' parse error)"
    # Show a bit of context around the first one
    idx = raw.index("children = (")
    context = raw[[idx-80,0].max .. [idx+120, raw.size].min] rescue nil if idx
  end

  # Very rough check for suspicious consecutive group-like objects without comma
  # (look for "};" followed quickly by another "isa = PBXGroup" without proper list separator)
  if !found_bad && raw =~ /isa = PBXGroup;[\s\S]{0,80}isa = PBXGroup;/m
    # This is too broad; only flag if also near known bad paths
    if raw.include?("path = Appearance;") && raw.include?("path = Network;")
      found_bad = true
      puts "!!! Suspicious consecutive PBXGroup entries near Appearance/Network"
    end
  end

  if found_bad
    puts "!!! CORRUPTION DETECTED in emitted pbxproj"
    if context
      puts "Context around issue:"
      puts context
    end
    puts "--- end context ---"
    if ENV["BYPASS_PBX_VALIDATION"] == "1"
      puts "BYPASS_PBX_VALIDATION=1 set — continuing despite validation failure (for diagnostics)."
    else
      raise "Validation FAILED: pbxproj still contains text corruption after repair (see above). The plist text has bad arrays or jammed groups."
    end
  else
    puts "Post-save validation PASSED: no obvious corruption patterns detected."
  # Extra post-clean check for trailing orphans (the bare children blocks seen in run 37611252270)
  if File.exist?(pbx_path)
    raw2 = File.read(pbx_path)
    orphan_count = raw2.scan(/\t\t\tchildren = \(\n\t\t\t\);\n\t\t\tsourceTree = "<group>";\n\t\t\};/).size
    if orphan_count > 0
      puts "!!! Still found #{orphan_count} trailing orphaned group fragment(s)"
      end_m = "/* End PBXGroup section */"
      if raw2.include?(end_m)
        b, a = raw2.split(end_m, 2)
        b2 = b.gsub(/(\n\t\t\tchildren = \(\n\t\t\t\);\n\t\t\tsourceTree = "<group>";\n\t\t\};\n)+/, "\n")
        if b2 != b
          File.write(pbx_path, b2 + end_m + a)
          puts "Last-chance orphan strip applied to pbxproj"
        end
      end
    end
  end

  end
else
  puts "WARNING: Could not locate project.pbxproj for validation"
end

puts "Repair script completed successfully with validation."

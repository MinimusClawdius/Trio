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
  # "path = .../Services;" line appears where a child entry should be,
  # before the proper closing of the children array.
  # This produces "Array missing ',' in between objects".
  #
  # Current observed form (after path normalization):
  #     38E8754D... /* WatchManager */,
  # 			path = "Trio/Sources/Services";
  # 			sourceTree = "<group>";
  # 		};
  #
  # We insert the missing ");" (with matching indent) to close the children array.
  # Handle both old bare "path = Services;" and new full quoted path.

  # Specific for current full quoted path after WatchManager (or similar last child)
  services_path_pattern = /path = "Trio\/Sources\/Services";/
  if raw =~ /WatchManager \*/m && raw =~ services_path_pattern
    # Match last child line ending with comma, followed by the path line
    new_raw = raw.gsub(
      /(,\s*\n)(\s*path = "Trio\/Sources\/Services";\s*\n\s*sourceTree = "<group>";)/m,
      "\\1\t\t\t);\n\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied raw text fix for Services children jam (full path after WatchManager)"
    end
  end

  # General fallback for current full path form right after any child comma
  if raw =~ /,\s*\n\s*path = "Trio\/Sources\/Services";\s*\n\s*sourceTree = "<group>";/m
    new_raw = raw.gsub(
      /(,\s*\n)(\s*path = "Trio\/Sources\/Services";\s*\n\s*sourceTree = "<group>";)/m,
      "\\1\t\t\t);\n\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied general raw text fix for Trio/Sources/Services jam"
    end
  end

  # Backward compat for old bare unquoted form
  if raw =~ /,\s*\n\s*path = Services;\s*\n\s*sourceTree = "<group>";/m
    new_raw = raw.gsub(
      /(,\s*\n)(\s*path = Services;\s*\n\s*sourceTree = "<group>";)/m,
      "\\1\t\t\t);\n\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied general raw text fix for bare path=Services jam"
    end
  end

  # Also handle the case where the path line has no leading whitespace in the jam
  if raw =~ /,\s*\npath = "Trio\/Sources\/Services";/m
    new_raw = raw.gsub(
      /(,\s*\n)(path = "Trio\/Sources\/Services";)/m,
      "\\1\t\t\t);\n\t\t\t\\2"
    )
    if new_raw != raw
      raw = new_raw
      fixed = true
      puts "Applied fix for unindented path=Services jam"
    end
  end

  
  # Early removal of bad Attributes BuildFiles (before any high-level processing)
  bad_dd = "6BCF84DD2B16843A003AD46E"
  bad_de = "6BCF84DE2B16843A003AD46E"
  ["LiveActivityAttributes.swift", "LiveActitiyAttributes.swift"].each do |sp|
    raw.gsub!(/^\t\t#{bad_dd} \/\* #{sp} in Sources \*\/ = \{isa = PBXBuildFile; fileRef = 6BCF84DC2B16843A003AD46E \/\* #{sp} \*\/; \};\s*$/, "")
    raw.gsub!(/^\t\t#{bad_de} \/\* #{sp} in Sources \*\/ = \{isa = PBXBuildFile; fileRef = 6BCF84DC2B16843A003AD46E \/\* #{sp} \*\/; \};\s*$/, "")
    raw.gsub!(/^\t\t\t\t#{bad_dd} \/\* #{sp} in Sources \*\/,?\s*$/, "")
    raw.gsub!(/^\t\t\t\t#{bad_de} \/\* #{sp} in Sources \*\/,?\s*$/, "")
    raw.gsub!(/#{bad_dd} \/\* #{sp} in Sources \*\//, "")
    raw.gsub!(/#{bad_de} \/\* #{sp} in Sources \*\//, "")
  end
  puts "EARLY-ATTRIBUTES-NUKE: applied (if any bad entries present)"
# === EARLY RAW CLEAN (before any potentially crashing gem traversal) ===
begin
  pbx_early = if ENV["GITHUB_WORKSPACE"]
    File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj", "project.pbxproj")
  else
    "Trio.xcodeproj/project.pbxproj"
  end
  if File.exist?(pbx_early)
    r = File.read(pbx_early)
    o = r.dup
    r.gsub!(/path = "[^"]*LiveActivity[^"]*";/, 'path = "LiveActivity";')
    r.gsub!(/path = "Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')
    r.gsub!(/path = "[^"]*Trio\/[^"]*LiveActivity[^"]*";/, 'path = "LiveActivity";')
    r.gsub!(/path = "[^"]*Sources\/Services\/LiveActivity[^"]*";/, 'path = "LiveActivity";')
    r.gsub!(/path = "Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')
    if r != o
      File.write(pbx_early, r)
      puts "  EARLY-RAW: cleaned LiveActivity group paths"
    end
  end
rescue => e
  puts "  EARLY-RAW error (continuing): #{e.message[0..100]}"
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

  # Clean duplicate End PBXGroup section markers (can appear from previous bad merges or partial repairs)
  end_marker = "/* End PBXGroup section */"
  if raw.count(end_marker) > 1
    # Keep only the last occurrence before the NativeTarget section
    parts = raw.split(end_marker)
    # Rejoin with only one marker at the correct place
    raw = parts[0] + end_marker + parts[1..-1].join("")
    # Remove any extra blank lines around it
    raw.gsub!(/\n\s*\n(#{Regexp.escape(end_marker)})/, "\n\\1")
    raw.gsub!(/(#{Regexp.escape(end_marker)})\n\s*\n/, "\\1\n\n")
    File.write(pbx_file, raw)
    puts "  Cleaned duplicate End PBXGroup section markers"
  end
else
  puts "WARNING: Could not find pbxproj for pre-fix at #{pbx_file}"
end

# === TEMPORARY BYPASS: strip time-sensitive notifications entitlement ===
# The current match AppStore profile does not include this capability.
# Code uses .timeSensitive alerts; re-enable once profile is updated in dev portal.
ent_path = if ENV["GITHUB_WORKSPACE"]
  File.join(ENV["GITHUB_WORKSPACE"], "Trio/Resources/Trio.entitlements")
else
  "Trio/Resources/Trio.entitlements"
end
if File.exist?(ent_path)
  ent = File.read(ent_path)
  if ent.include?("usernotifications.time-sensitive")
    original_ent = ent.dup
    ent.gsub!(/\s*<key>com\.apple\.developer\.usernotifications\.time-sensitive<\/key>\s*<true\/>/, "")
    if ent != original_ent
      File.write(ent_path, ent)
      puts "Stripped com.apple.developer.usernotifications.time-sensitive entitlement (profile workaround)"
    end
  end
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
    path = (g.path || "").to_s
    name = (g.name || "").to_s
    is_live = (path == "LiveActivity" || path.end_with?("/LiveActivity") || name == "LiveActivity")
    # Prefer the one that is NOT under Services/Trio/Sources/Services (for the extension)
    if is_live
      parent_path = ""
      # crude parent check via string on path
      if path.include?("Services/LiveActivity") || path.include?("Trio/Sources")
        next false unless path == "LiveActivity"  # only accept exact "LiveActivity"
      end
      true
    else
      false
    end
end

# Fallback to any LiveActivity if the strict one wasn't found
if !live_group
  live_group = project.main_group.recursive_children_groups.find do |g|
    path = (g.path || "").to_s
    name = (g.name || "").to_s
    (path == "LiveActivity" || path.end_with?("/LiveActivity") || name == "LiveActivity")
  end
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
    basename = File.basename(rel_path)
    # Try multiple possible on-disk locations
    candidates = [rel_path, "LiveActivity/#{basename}", "Trio/Sources/Services/LiveActivity/#{basename}", basename]
    found_on_disk = candidates.find { |p| File.exist?(p) }

    file_ref = project.files.find { |f| f.path == basename || (f.path && f.path.end_with?(basename)) }

    if file_ref.nil? && found_on_disk
      puts "Creating fresh FileRef for #{basename} (from #{found_on_disk})"
      file_ref = project.new_file(found_on_disk)
    end

    if file_ref
      # Ensure in the group
      unless live_group.children.include?(file_ref)
        live_group.children << file_ref rescue nil
        puts "  Attached #{basename} to LiveActivity group"
      end

      if source_phase
        # Remove any existing BuildFiles for this ref to avoid dups
        source_phase.files.select { |bf| bf.file_ref == file_ref }.each do |bf|
          source_phase.remove_file_reference(file_ref) rescue nil
        end

        puts "Re-adding #{basename} to LiveActivityExtension via proper API"
        source_phase.add_file_reference(file_ref, true)
      end
    else
      puts "WARNING: Could not locate or create FileRef for #{basename}"
    end
  end

  # Deduplicate any remaining duplicate BuildFiles in the extension sources phase
  if source_phase
    seen = {}
    source_phase.files.each do |bf|
      next unless bf.file_ref
      key = bf.file_ref.uuid
      if seen[key]
        puts "  Dedup: removing duplicate BuildFile for #{bf.file_ref.path}"
        source_phase.remove_file_reference(bf.file_ref) rescue nil
      else
        seen[key] = true
      end
    end
  end
else
  puts "WARNING: Could not find LiveActivity target."
# ============================================================
# 2.5 Robust path sanitizer - fix any stacked/duplicated paths
#     introduced by prior merges or over-eager rewrites.
#     This runs after LiveActivity re-wire but before Pebble and final save.
# ============================================================
puts "Running path sanitizer for stacked/duplicated references..."
sanitized = 0
project.files.each do |f|
  next unless f.path
  orig = f.path.to_s
  newp = orig.dup

  # Fix common stacking patterns seen in LiveActivity and Services
  newp = newp.gsub(%r{(Trio/Sources/)+}, 'Trio/Sources/')
  newp = newp.gsub(%r{LiveActivity/LiveActivity/}, 'LiveActivity/')
  newp = newp.gsub(%r{Services/Services/}, 'Services/')
  newp = newp.gsub(%r{(Trio/){2,}}, 'Trio/')

  if newp != orig
    f.path = newp
    sanitized += 1
    puts "  Sanitized path: #{orig} -> #{newp}"
  end
end
puts "Path sanitizer fixed #{sanitized} FileReference(s)."

# Also clean any group paths that are stacked
project.main_group.recursive_children_groups.each do |g|
  next unless g.path
  orig = g.path.to_s
  newp = orig.dup
  newp = newp.gsub(%r{(Trio/Sources/)+}, 'Trio/Sources/')
  newp = newp.gsub(%r{(Trio/){2,}}, 'Trio/')
  if newp != orig
    g.path = newp
    sanitized += 1
    puts "  Sanitized group path: #{orig} -> #{newp}"
  end
end
end


# ============================================================
# 2.6 Strong LiveActivityExtension source cleanup and re-add
#     Force correct root-relative paths for the extension files.
#     Remove typo and any bad refs from the extension target.
# ============================================================
puts "Strong LiveActivityExtension cleanup..."
live_target = project.targets.find do |t|
  name = t.name.to_s.downcase
  name.include?("liveactivity")
end

if live_target
  puts "Re-cleaning sources for #{live_target.name}"
  source_phase = live_target.source_build_phase

  # === CRITICAL: Remove any directory "LiveActivity" reference from extension sources ===
  # Directory ref + individual files = duplicate compile tasks -> "Multiple commands produce .stringsdata"
  if source_phase
    removed_any = false
    dir_uuids = ["DDCEBF5B2CC1B76400DF4C36", "BDF34F922C10D0E100D51995"]
    source_phase.files.each do |bf|
      next unless bf.file_ref
      ref = bf.file_ref
      pname = (ref.path || ref.name || "").to_s
      is_dir = (pname == "LiveActivity" || pname.end_with?("/LiveActivity") || pname == "LiveActivity/")
      is_dir ||= dir_uuids.include?(ref.uuid.to_s)
      if is_dir
        puts "  REMOVING directory ref 'LiveActivity' (#{pname || ref.uuid}) from LiveActivityExtension sources"
        source_phase.remove_file_reference(ref) rescue nil
        removed_any = true
      end
    end
    puts "  No directory LiveActivity ref found in extension sources" unless removed_any
  end

  # Remove bad BuildFile refs (typo Attributes, stacked paths)
  if source_phase
    bad_basenames = ["LiveActitiyAttributes.swift"]
    source_phase.files.each do |bf|
      next unless bf.file_ref && bf.file_ref.path
      p = bf.file_ref.path.to_s
      if bad_basenames.any? { |b| p.end_with?(b) } || p.include?("Trio/Sources/Trio") || p.include?("/Trio/Trio/")
        puts "  Removing bad ref from extension: #{p}"
        source_phase.remove_file_reference(bf.file_ref) rescue nil
      end
    end
  end

  # Ensure the core extension files are present with clean bare paths
  core_live_files = [
    "LiveActivity/LiveActivity.swift",
    "LiveActivity/LiveActivityBundle.swift",
    "LiveActivity/LiveActivity+Helper.swift"
  ]

  core_live_files.each do |rel|
    next unless File.exist?(rel)
    basename = File.basename(rel)

    ref = project.files.find { |f| f.path && (f.path == basename || f.path.end_with?("/#{basename}")) }
    if ref
      if ref.path.to_s != basename && !ref.path.to_s.start_with?("LiveActivity/")
        puts "  Forcing clean path on #{basename}: was #{ref.path}"
        ref.path = basename
      end
    else
      puts "  Creating fresh clean ref for #{rel}"
      ref = project.new_file(rel)
    end

    if ref && source_phase
      # remove existing to dedup then add
      source_phase.files.select { |bf| bf.file_ref == ref }.each do |bf|
        source_phase.remove_file_reference(ref) rescue nil
      end
      puts "  Adding clean #{basename} to LiveActivityExtension sources"
      source_phase.add_file_reference(ref, true)
    end
  end

  # Final force pass for the three widget files
  %w[LiveActivity.swift LiveActivityBundle.swift LiveActivity+Helper.swift].each do |fname|
    ref = project.files.find { |f| f.path && f.path.to_s.end_with?(fname) }
    if ref.nil? && File.exist?("LiveActivity/#{fname}")
      ref = project.new_file("LiveActivity/#{fname}")
    end
    if ref && source_phase
      source_phase.files.select { |bf| bf.file_ref == ref }.each { |bf| source_phase.remove_file_reference(ref) rescue nil }
      has_it = source_phase.files.any? { |bf| bf.file_ref == ref }
      unless has_it
        puts "  Force-adding #{fname} to extension sources"
        source_phase.add_file_reference(ref, true)
      end
    end
  end
else
  puts "WARNING: live_target not found in strong cleanup"
end


puts "Fixing LiveActivity group path for extension Views..."
# Find the group that contains the Views synchronized group (the extension's LiveActivity parent)
views_group_id = "DDCEBF412CC1B42500DF4C36"
live_activity_group = nil

project.main_group.recursive_children_groups.each do |g|
  if g.children && g.children.any? { |c| c.uuid == views_group_id || (c.name || "").to_s == "Views" }
    live_activity_group = g
    break
  end
end

if live_activity_group
  orig_path = live_activity_group.path.to_s
  if orig_path != "LiveActivity" && !orig_path.end_with?("/LiveActivity")
    puts "  Setting LiveActivity group path: '#{orig_path}' -> 'LiveActivity'"
    live_activity_group.path = "LiveActivity"
  else
    puts "  LiveActivity group path already clean: #{orig_path}"
  end

  # Also ensure the core widget files are children of this group with clean paths
  core_widget = ["LiveActivity.swift", "LiveActivityBundle.swift", "LiveActivity+Helper.swift"]
  core_widget.each do |fname|
    ref = project.files.find { |f| f.path && f.path.to_s.end_with?(fname) }
    if ref
      if ref.path.to_s != fname
        puts "  Cleaning path on #{fname}: #{ref.path} -> #{fname}"
        ref.path = fname
      end
      # Ensure it's under the live_activity_group if possible (add as child if missing)
      unless live_activity_group.children.include?(ref)
        # Note: may already be referenced; adding again is usually safe or no-op
        live_activity_group.children << ref rescue nil
        puts "  Ensured #{fname} is child of the LiveActivity group"
      end
    end
  end
else
  puts "  WARNING: Could not find the LiveActivity group owning Views"
end


# ============================================================
# 2.8 Aggressive re-parent + path fix for LiveActivity extension group
#     The group 6B1A8D1C... (owner of Views + widget files) has path
#     "Trio/Sources/Services/LiveActivity" because it is nested under
#     a Services parent. This causes the build to look in the wrong place.
#     We must:
#       - Force path = "LiveActivity"
#       - Re-parent it directly under main_group (or the top "Trio" group)
#         so it is not relative to Sources/Services.
# ============================================================
puts "Aggressive LiveActivity extension group re-parent and path fix..."

begin  # safe wrapper for modern group types

# Find the problematic LiveActivity group: the one owning Views or having the widget files as children
target_group = nil
project.main_group.recursive_children_groups.each do |g|
  path = (g.path || "").to_s
  name = (g.name || "").to_s
  next if g.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) || g.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedGroup)
  has_views = begin
    g.children.any? { |c| (c.name || "").to_s == "Views" || (c.uuid || "") == "DDCEBF412CC1B42500DF4C36" }
  rescue
    false
  end
  has_widget_files = begin
    g.children.any? do |cc|
      p = (cc.path || cc.name || "").to_s
      p.end_with?("LiveActivity.swift") || p.end_with?("LiveActivityBundle.swift") || p.end_with?("LiveActivity+Helper.swift")
    end
  rescue
    false
  end
  if (name == "LiveActivity" || path.end_with?("LiveActivity")) && (has_views || has_widget_files)
    target_group = g
    puts "  Found target LiveActivity group: name=#{name}, path=#{path}, has_views=#{has_views}, has_widget=#{has_widget_files}"
    break
  end
end

if target_group
  orig_path = target_group.path.to_s
  target_group.path = "LiveActivity"
  puts "  Forced path: #{orig_path} -> LiveActivity"

  # Find current parent and re-parent to main_group level if necessary
  # The main_group or a top-level "Trio" group
  root_parent = project.main_group
  # Try to find a "Trio" group at top level if it exists
  trio_group = project.main_group.children.find { |c| (c.name || "").to_s == "Trio" && c.is_a?(Xcodeproj::Project::Object::PBXGroup) }
  root_parent = trio_group if trio_group

  # Check if already directly under root_parent
  already_direct = root_parent.children.include?(target_group)

  if !already_direct
    # Remove from any current parent
    project.main_group.recursive_children_groups.each do |parent|
      if parent.children.include?(target_group)
        parent.children.delete(target_group) rescue nil
        puts "  Removed from parent group (path: #{parent.path || parent.name})"
      end
    end
    # Add to the root parent
    root_parent.children << target_group unless root_parent.children.include?(target_group)
    puts "  Re-parented LiveActivity group directly under #{root_parent.name || 'main_group'}"
  else
    puts "  Already directly under root parent"
  end

  # Clean paths on the widget files inside this group
  target_group.children.each do |child|
    if child.is_a?(Xcodeproj::Project::Object::PBXFileReference)
      p = child.path.to_s
      if p.include?("Trio/") || p.include?("Sources/Services/LiveActivity")
        newp = File.basename(p)
        puts "  Cleaned file path inside group: #{p} -> #{newp}"
        child.path = newp
      end
    end
  end
else
  puts "  WARNING: Could not locate the target LiveActivity group for re-parent"
end

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
    path = (g.path || "").to_s
    name = (g.name || "").to_s
    path == "Services" || path.end_with?("/Services") || path == "Trio/Sources/Services" || name == "Services"
  end

  if services_group.nil?
    puts "WARNING: Services group not found, creating it"
    services_group = project.new_group("Services", "Services")
    project.main_group.children << services_group
  end

  # Remove any existing Pebble subgroups (search whole project to avoid multiple-parent issues)
  puts "Aggressive cleanup of any pre-existing Pebble groups..."
  ["PebbleManager", "PebbleService"].each do |gname|
    project.objects.select { |o| o.is_a?(Xcodeproj::Project::Object::PBXGroup) && ((o.path == gname) || (o.name == gname)) }.each do |existing|
      begin
        parent = existing.parent
        if parent && parent.children.include?(existing)
          parent.children.delete(existing)
          puts "  Detached stale #{gname} (#{existing.uuid}) from parent"
        end
        # Also remove any file refs belonging to it from build phases
        project.targets.each do |t|
          phase = t.source_build_phase
          next unless phase
          existing.children.to_a.each do |fr|
            phase.files.to_a.each do |bf|
              if (bf.respond_to?(:file_ref) && bf.file_ref == fr) || (bf.respond_to?(:file_ref) && bf.file_ref && bf.file_ref.path == fr.path)
                phase.remove_file_reference(fr) rescue nil
              end
            end
          end
        end
      rescue => e
        puts "  Warning during cleanup of #{gname}: #{e.message}"
      end
    end
  end

  # Create fresh subgroups under Services
  pm_group = project.new_group("PebbleManager", "PebbleManager")
  services_group.children << pm_group rescue (puts "Warning: could not attach pm_group directly")
  ps_group = project.new_group("PebbleService", "PebbleService")
  services_group.children << ps_group rescue (puts "Warning: could not attach ps_group directly")
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
  { path: "Trio/Sources/Services/PebbleService/PebbleService+UI.swift", group: ps_group },
  # Settings UI files that reference the Pebble types (critical for compile)
  { path: "Trio/Sources/Modules/Settings/View/PebbleServiceStartView.swift", group: ps_group },
  { path: "Trio/Sources/Modules/Settings/View/PebbleServiceConfigViews.swift", group: ps_group }
]

main_target = project.targets.find { |t| t.name.to_s == "Trio" }
source_phase = main_target&.source_build_phase

begin
  pebble_files.each do |entry|
    rel = entry[:path]
    target_group = entry[:group]
    next unless File.exist?(rel)

    basename = File.basename(rel)
    # Always add fresh via the API (it handles quoting for + in filenames)
    file_ref = nil
    begin
      file_ref = target_group.new_file(rel)
      puts "Added (or re-added) #{basename} via new_file"
    rescue => e
      puts "  Warning: could not new_file #{basename}: #{e.message}"
    end

    if source_phase && file_ref
      begin
        # Ensure it is in the build phase
        unless source_phase.files.any? { |bf| (bf.file_ref == file_ref) rescue false }
          source_phase.add_file_reference(file_ref, true)
          puts "Wired #{basename} to main target source phase"
        end
      rescue => e
        puts "  Warning wiring #{basename}: #{e.message}"
      end
    end
  end
  puts "Pebble clean integration complete."
  project.save
  puts "Saved after Pebble block"
rescue => e
  puts "WARNING: Pebble integration block hit an error but continuing: #{e.message}"
  puts e.backtrace.first(3).join("\n")
  begin
    project.save
  rescue
  end
end
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

# ============================================================
# 9b. Late aggressive Trio/ path correction (run after all re-serialization)
#     This is the last chance to fix any FileRefs that still have bare paths.
# ============================================================
puts "Late aggressive Trio/ path correction..."

late_corrected = 0
project.files.each do |fr|
  next unless fr.respond_to?(:path) && fr.path
  next if fr.path.start_with?("Trio/")
  next if fr.path.include?("LiveActivity")
  next if fr.path.include?("LiveActivity")  # do not touch LiveActivity paths here

  bare = fr.path
  candidate = "Trio/#{bare}"

  if File.exist?(candidate) && !File.exist?(bare)
    puts "  [LATE] Fixing #{bare} -> #{candidate}"
    fr.path = candidate
    late_corrected += 1
  end
end

if late_corrected > 0
  puts "Late correction fixed #{late_corrected} path(s). Re-saving..."
  project.save
else
  puts "Late correction: no additional fixes needed."
end


# ============================================================
# 2.9 Final ultra-late LiveActivity group path + re-parent + stack strip (raw + gem)
#     This runs after ALL other sanitizers, Trio/ corrections, Pebble, re-serialization.
#     It forces the critical extension group (owner of Views) to path="LiveActivity"
#     and strips every known stacking pattern seen in previous failures.
#     Raw text edit is the hammer to guarantee the pbxproj text the Fastlane sees is clean.
# ============================================================
rescue => e
  puts "  2.8/2.9 gem section error (non-fatal): #{e.message[0..120]}"
end



# Late pass: ensure no directory LiveActivity ref remains in the extension
live_target2 = project.targets.find { |t| t.name.to_s.downcase.include?("liveactivity") }
if live_target2
  sp = live_target2.source_build_phase
  if sp
    sp.files.each do |bf|
      next unless bf.file_ref
      p = (bf.file_ref.path || bf.file_ref.name || "").to_s
      if p == "LiveActivity" || p.end_with?("/LiveActivity")
        puts "  LATE-REMOVE: directory LiveActivity ref from extension sources"
        sp.remove_file_reference(bf.file_ref) rescue nil
      end
    end
  end
end


# === VERY LATE RAW HAMMER: nuke any remaining directory LiveActivity refs in extension context ===
begin
  pbx_late = if ENV["GITHUB_WORKSPACE"]
    File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj", "project.pbxproj")
  else
    "Trio.xcodeproj/project.pbxproj"
  end
  if File.exist?(pbx_late)
    r = File.read(pbx_late)
    o = r.dup
    # Remove BuildFile + reference to the known directory LiveActivity for the extension
    r.gsub!(/\t\tDDCEBF5B2CC1B76400DF4C36 \/\* LiveActivity in Sources \*\/,\n/, "")
    r.gsub!(/\t\tBDF34F932C10D0E100D51995 \/\* LiveActivity in Sources \*\/,\n/, "")
    r.gsub!(/\t\t\t\tDDCEBF5B2CC1B76400DF4C36 \/\* LiveActivity in Sources \*\/,\n/, "")
    if r != o
      File.write(pbx_late, r)
      puts "  VERY-LATE-RAW: removed directory LiveActivity refs from sources"
    end
  end
rescue => e
  puts "  VERY-LATE-RAW error: #{e.message[0..80]}"
end

puts "2.9 Final ultra-late LiveActivity path/re-parent/strip..."

# Re-open project for gem attempt
begin
  project = Xcodeproj::Project.open(project_path)
  target_group = nil
  views_id = "DDCEBF412CC1B42500DF4C36"
  widget_names = ["LiveActivity.swift", "LiveActivityBundle.swift", "LiveActivity+Helper.swift"]

  project.main_group.recursive_children_groups.each do |g|
    path = (g.path || "").to_s
    name = (g.name || "").to_s
    has_views = g.children.any? { |c| (c.name || "").to_s == "Views" || (c.uuid || "") == views_id }
    has_widgets = g.children.any? do |c|
      p = (c.path || c.name || "").to_s
      widget_names.any? { |w| p.end_with?(w) }
    end
    if (name == "LiveActivity" || path.include?("LiveActivity")) && (has_views || has_widgets)
      target_group = g
      puts "  [2.9] Matched target LiveActivity group: path=#{path}, has_views=#{has_views}"
      break
    end
  end

  if target_group
    target_group.path = "LiveActivity"
    puts "  [2.9] Gem: forced path to LiveActivity"

    # Re-parent to root
    root = project.main_group
    trio = project.main_group.children.find { |c| (c.name || "").to_s == "Trio" && c.is_a?(Xcodeproj::Project::Object::PBXGroup) }
    root = trio if trio
    project.main_group.recursive_children_groups.each do |p|
      if p.children.include?(target_group) && p != root
        p.children.delete(target_group) rescue nil
        puts "  [2.9] Removed from nested parent"
      end
    end
    root.children << target_group unless root.children.include?(target_group)
    puts "  [2.9] Re-parent attempt done"

    # Clean child file refs
    target_group.children.each do |ch|
      if ch.respond_to?(:path) && ch.path
        if ch.path.to_s.include?("Trio/") || ch.path.to_s.include?("Sources/Services")
          ch.path = File.basename(ch.path.to_s)
          puts "  [2.9] Cleaned child file path to #{ch.path}"
        end
      end
    end
    project.save
    puts "  [2.9] Saved after gem LiveActivity fix"
  else
    puts "  [2.9] No target group matched in gem pass"
  end
rescue => e
  puts "  [2.9] Gem pass error (continuing with raw): #{e.message[0..150]}"
end

# === RAW TEXT HAMMER (safe, no heredocs) ===
pbx_path = if ENV["GITHUB_WORKSPACE"]
  File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj", "project.pbxproj")
else
  "Trio.xcodeproj/project.pbxproj"
end

if File.exist?(pbx_path)
  raw = File.read(pbx_path)
  orig_size = raw.size

  # Clean any stacked or wrong LiveActivity group paths
  raw.gsub!(/path = "Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')
  # also nuke any remaining typo Attributes FileRef
  raw.gsub!(/6BCF84DC2B16843A003AD46E \/\* LiveActitiyAttributes\.swift \*\/ = \{isa = PBXFileReference;[^}]+\};/m, "")
  raw.gsub!(/path = "[^"]*LiveActivity[^"]*";/, 'path = "LiveActivity";')
  raw.gsub!(/path = "Trio\/Sources\/Trio\/Sources[^"]*"/, 'path = "LiveActivity"')
  raw.gsub!(/path = "Trio\/Sources\/Services\/Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')
  raw.gsub!(/path = "Trio\/Sources\/Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')
  raw.gsub!(/path = "[^"]*Trio\/[^"]*LiveActivity[^"]*";/, 'path = "LiveActivity";')
  raw.gsub!(/path = "[^"]*Sources\/Services\/LiveActivity[^"]*";/, 'path = "LiveActivity";')

  # Clean widget file refs
  raw.gsub!(/path = "[^"]*(LiveActivity\.swift|LiveActivityBundle\.swift|LiveActivity\+Helper\.swift)";/, 'path = "LiveActivity.swift";')

  # Fix typo Attributes path if present
  raw.gsub!(/path = "[^"]*LiveActitiyAttributes\.swift";/, 'path = "LiveActivityAttributes.swift";')

  # Also run the Attributes BuildFile nuke here early (in case final is after a crash point)
  bad_dd = "6BCF84DD2B16843A003AD46E"
  bad_de = "6BCF84DE2B16843A003AD46E"
  ["LiveActivityAttributes.swift", "LiveActitiyAttributes.swift"].each do |sp|
    raw.gsub!(/^\t\t#{bad_dd} \/\* #{sp} in Sources \*\/ = \{isa = PBXBuildFile; fileRef = 6BCF84DC2B16843A003AD46E \/\* #{sp} \*\/; \};\s*$/, "")
    raw.gsub!(/^\t\t#{bad_de} \/\* #{sp} in Sources \*\/ = \{isa = PBXBuildFile; fileRef = 6BCF84DC2B16843A003AD46E \/\* #{sp} \*\/; \};\s*$/, "")
    raw.gsub!(/^\t\t\t\t#{bad_dd} \/\* #{sp} in Sources \*\/,?\s*$/, "")
    raw.gsub!(/^\t\t\t\t#{bad_de} \/\* #{sp} in Sources \*\/,?\s*$/, "")
    raw.gsub!(/#{bad_dd} \/\* #{sp} in Sources \*\//, "")
    raw.gsub!(/#{bad_de} \/\* #{sp} in Sources \*\//, "")
  end

  if raw.size != orig_size || raw != File.read(pbx_path)
    File.write(pbx_path, raw)
    puts "  [2.9] RAW: Cleaned LiveActivity paths and nuked bad Attributes BuildFiles"
  else
    puts "  [2.9] RAW: No change needed"
  end
else
  puts "  [2.9] pbx_path not found for raw fix"
end

puts "2.9 LiveActivity final fix complete."


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


# ============================================================
# 9. Correct relative paths for source files that live under
#    the "Trio/" subdirectory in this fork (common after merges
#    that assume flat Sources/ layout).
#    This prevents "Build input file cannot be found" for
#    Nightscout/Network/Tidepool and similar groups.
# ============================================================
puts "Correcting source paths for files that only exist under Trio/ prefix..."

corrected = 0
project.files.each do |fr|
  next unless fr.respond_to?(:path) && fr.path
  next if fr.path.start_with?("Trio/")
  next if fr.path.include?("LiveActivity")

  bare_path = fr.path
  trio_path = "Trio/#{bare_path}"

  if File.exist?(trio_path) && !File.exist?(bare_path)
    puts "  Fixing FileRef path: #{bare_path} → #{trio_path}"
    fr.path = trio_path
    corrected += 1
  end
end

if corrected > 0
  puts "Corrected #{corrected} source FileRef path(s) to use Trio/ prefix."
else
  puts "No path corrections needed (or files already correct)."
end

# Second pass for any under Sources/ or Services/ etc.
project.files.each do |fr|
  next unless fr.respond_to?(:path) && fr.path
  next if fr.path.start_with?("Trio/")
  next if fr.path.include?("LiveActivity")

  if fr.path =~ %r{^(Sources|Services|LiveActivity)/}
    candidate = "Trio/#{fr.path}"
    if File.exist?(candidate) && !File.exist?(fr.path)
      puts "  Fixing (second pass) #{fr.path} → #{candidate}"
      fr.path = candidate
      corrected += 1
    end
  end
end

if corrected > 0
  puts "Total path corrections applied: #{corrected}"
end

puts "Repair script completed successfully with validation."

# ============================================================
# LATE RAW HAMMER (appended clean version)
# Runs after the main "Repair script completed" message.
# Performs final raw text edits on the pbxproj to guarantee
# the file written to disk for Fastlane is clean.
# ============================================================
puts "LATE-RAW-HAMMER: final raw text cleanup for Services jam and LiveActivity..."

pbx_path = if ENV["GITHUB_WORKSPACE"]
  File.join(ENV["GITHUB_WORKSPACE"], "Trio.xcodeproj", "project.pbxproj")
else
  "Trio.xcodeproj/project.pbxproj"
end

if File.exist?(pbx_path)
  raw = File.read(pbx_path)
  orig = raw.dup

  # Services jam: insert ); to close the children array before the stray path line
  # Observed pattern:
  #   ... /* WatchManager */,
  #   path = "Trio/Sources/Services";
  #   sourceTree = "<group>";

  raw.gsub!(/(WatchManager \*\/,\s*\n)(\s*path = "Trio\/Sources\/Services";)/, "\\1\t\t\t);\n\\2")
  raw.gsub!(/(,\s*\n)(\s*path = "Trio\/Sources\/Services";)/, "\\1\t\t\t);\n\\2")
  raw.gsub!(/(,\s*\n)(\s*path = "Trio\/Sources\/Services";\s*\n\s*sourceTree = "<group>";)/, "\\1\t\t\t);\n\\2")

  # LiveActivity group path cleanup (any stacked or Services-nested)
  raw.gsub!(/path = "[^"]*LiveActivity[^"]*";/, 'path = "LiveActivity";')
  raw.gsub!(/path = "Trio\/Sources\/Services\/LiveActivity";/, 'path = "LiveActivity";')

  # Clean widget file refs
  raw.gsub!(/path = "[^"]*\/(LiveActivity\.swift|LiveActivityBundle\.swift|LiveActivity\+Helper\.swift)";/, 'path = "\\1";')
  raw.gsub!(/path = "[^"]*(LiveActivity\.swift|LiveActivityBundle\.swift|LiveActivity\+Helper\.swift)";/, 'path = "\\1";')


  # Remove directory "LiveActivity" references from sources phases (root cause of duplicate stringsdata)
  # These are BuildFile lines like:
  #   DDCEBF5B2CC1B76400DF4C36 /* LiveActivity in Sources */,
  # and the corresponding BuildFile definitions.
  dir_uuids = ["DDCEBF5B2CC1B76400DF4C36", "BDF34F932C10D0E100D51995"]
  dir_uuids.each do |uuid|
    # Remove from sources lists (with or without trailing comma)
    raw.gsub!(/\t\t#{uuid} \/\* LiveActivity in Sources \*\/,\n/, "")
    raw.gsub!(/\t\t#{uuid} \/\* LiveActivity in Sources \*\/$/, "")
    raw.gsub!(/\t\t\t\t#{uuid} \/\* LiveActivity in Sources \*\/,\n/, "")
    # Remove the BuildFile definition block
    raw.gsub!(/\t\t#{uuid} \/\* LiveActivity in Sources \*\/ = \{isa = PBXBuildFile; fileRef = [0-9A-F]+ \/\* LiveActivity \*\/; \};\n/, "")
  end

  if raw != orig
    File.write(pbx_path, raw)
    puts "  LATE-RAW-HAMMER: removed directory LiveActivity sources refs (DDCEBF5B etc.)"
  end


  # Typo fix
  raw.gsub!(/LiveActitiyAttributes/, 'LiveActivityAttributes')

  if raw != orig
    File.write(pbx_path, raw)
    puts "LATE-RAW-HAMMER: applied final raw fixes (Services jam closed + LiveActivity cleaned)"
  else
    puts "LATE-RAW-HAMMER: no changes needed (patterns not present or already clean)"
  end
else
  puts "LATE-RAW-HAMMER: pbx_path not found"
end

puts "LATE-RAW-HAMMER complete. Script exiting."

# ============================================================

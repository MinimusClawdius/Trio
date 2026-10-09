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

# === FORCED EARLY FIX FOR LIVEACTIVITY SHARED FILES (run very early on raw) ===
# Force the exact correct paths on the shared Attributes and Manager.
# Strip any "path = LiveActivity" from the organizational shared group.
# Normalize any duplicated "Trio/Sources/" stacking that previous passes may have created.
raw.gsub!(/(6BCF84DC2B16843A003AD46E \/\* LiveActivityAttributes\.swift \*\/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; )path = [^;]+;/, '\1path = "Trio/Sources/Services/LiveActivity/LiveActivityAttributes.swift";')
raw.gsub!(/(6B1A8D2D2B156EEF00E76752 \/\* LiveActivityManager\.swift \*\/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; )path = [^;]+;/, '\1path = "Trio/Sources/Services/LiveActivity/LiveActivityManager.swift";')
raw.gsub!(/(6B1A8D2C2B156EC100E76752 \/\* LiveActivity \*\/ = \{[^}]*?)path = LiveActivity;\s*/, '\1')
raw.gsub!(/(Trio\/Sources\/)+/, 'Trio/Sources/')
raw.gsub!(/path = "Trio\/Sources\/Trio\/Sources\//, 'path = "Trio/Sources/')


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

  
  # Early removal of bad Attributes BuildFiles DISABLED.
  # This was too aggressive and removed legitimate BuildFiles for the
  # LiveActivityExtension. Correct addition is handled by ensure block + final force.
  puts "EARLY-ATTRIBUTES-NUKE: DISABLED (attributes will be added to extension by later logic)"

# Early explicit removal of the known bad/orphan helper BuildFile (A522...)
# This UUID has been a persistent source of "cannot be found" because its FileRef was deleted but BuildFile lingered.
raw.gsub!(/\t\t[0-9A-F]+ \/\* LiveActivityAttributes\+Helper\.swift in Sources \*\/ = \{isa = PBXBuildFile; fileRef = A522228ECDADC08A694CEDD1 [^}]*\};?\s*\n/, '')
raw.gsub!(/\t\t\t\t[0-9A-F]+ \/\* LiveActivityAttributes\+Helper\.swift in Sources \*\/,\s*\n/, '')
raw.gsub!(/A522228ECDADC08A694CEDD1 \/\* LiveActivityAttributes\+Helper\.swift \*\/ = \{isa = PBXFileReference; [^}]*\};?\s*\n/, '')


# === STRUCTURAL FIX FOR SHARED LIVEACTIVITY GROUP ===
# The "LiveActivity" group holding Manager + Attributes must NOT have path = "LiveActivity"
# (that conflicts with the widget extension's LiveActivity/ folder at root).
# Force full paths on the refs so they resolve from project root.
raw.gsub!(/6B1A8D2C2B156EC100E76752 \/\* LiveActivity \*\/ = \{([^}]*?)path = LiveActivity;\s*/, '6B1A8D2C2B156EC100E76752 /* LiveActivity */ = {')
raw.gsub!(/(6B1A8D2D2B156EEF00E76752 \/\* LiveActivityManager\.swift \*\/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; )path = [^;]+;/, 'path = "Trio/Sources/Services/LiveActivity/LiveActivityManager.swift";')
raw.gsub!(/(6BCF84DC2B16843A003AD46E \/\* LiveActivityAttributes\.swift \*\/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode\.swift; )path = [^;]+;/, 'path = "Trio/Sources/Services/LiveActivity/LiveActivityAttributes.swift";')

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
    # Only clean group/dir references to LiveActivity, never .swift files or full paths
    r.gsub!(/path = "LiveActivity";/, 'path = "LiveActivity";')  # no-op, but structure
    r.gsub!(/path = "([^"]*\/)?LiveActivity";/, 'path = "LiveActivity";')  # dir only
    # Do not touch paths that contain .swift or full Services paths
    if r != o
      File.write(pbx_early, r)
      puts "  EARLY-RAW: cleaned LiveActivity group paths (dir only)"
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

  # === Ensure LiveActivityAttributes (and +Helper) are present for the widget extension ===
  # Widget Views (in LiveActivity/Views/WidgetItems) use LiveActivityAttributes type.
  # The rich definition now lives at Trio/Sources/Services/LiveActivity/LiveActivityAttributes.swift
  # (after cleaning the previous typo "LiveActitiy").
  
        if ref && source_phase
          # dedup
          source_phase.files.select { |bf| bf.file_ref == ref }.each do |bf|
            source_phase.remove_file_reference(ref) rescue nil
          end
          has_it = source_phase.files.any? { |bf| bf.file_ref == ref }
          unless has_it
            source_phase.add_file_reference(ref, true)
            puts "  FINAL FORCE: added #{fname} to LiveActivityExtension sources"
          else
            puts "  FINAL: #{fname} already present in extension sources"
          end
        end
      end
      project.save
      puts "  FINAL: project re-saved after attributes force"
    end
  else
    puts "  FINAL: no live_target found"
  end
rescue => e
  puts "  FINAL force error: #{e.message}"
end

puts "LATE-RAW-HAMMER complete. Script exiting."

# ============================================================

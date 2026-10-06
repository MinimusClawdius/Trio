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

project = Xcodeproj::Project.open(project_path)

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
# 4. Pebble integration using proper xcodeproj API (repairs any text-edit damage from add script)
# ============================================================
puts "Ensuring Pebble groups and files are correctly attached via API..."

services_group = project.main_group.recursive_children_groups.find do |g|
  (g.path && g.path == "Services") || (g.name && g.name == "Services")
end

if services_group
  puts "Found Services group"

  pm_group = services_group.children.find { |c| (c.respond_to?(:path) && c.path == "PebbleManager") || (c.respond_to?(:name) && c.name == "PebbleManager") }
  if pm_group.nil?
    pm_group = project.new_group("PebbleManager", "PebbleManager")
    services_group.children << pm_group
    puts "Created PebbleManager subgroup"
  end

  ps_group = services_group.children.find { |c| (c.respond_to?(:path) && c.path == "PebbleService") || (c.respond_to?(:name) && c.name == "PebbleService") }
  if ps_group.nil?
    ps_group = project.new_group("PebbleService", "PebbleService")
    services_group.children << ps_group
    puts "Created PebbleService subgroup"
  end

  pebble_files = [
    "Trio/Sources/Services/PebbleManager/PebbleManager.swift",
    "Trio/Sources/Services/PebbleManager/PebbleDataBridge.swift",
    "Trio/Sources/Services/PebbleManager/PebbleCommandManager.swift",
    "Trio/Sources/Services/PebbleManager/PebbleCommandConfirmationView.swift",
    "Trio/Sources/Services/PebbleManager/PebbleLocalAPIServer.swift",
    "Trio/Sources/Services/PebbleManager/PebbleAppMessageKeys.swift",
    "Trio/Sources/Services/PebbleManager/PebbleBLEBridge.swift",
    "Trio/Sources/Services/PebbleService/PebbleService.swift",
    "Trio/Sources/Services/PebbleService/PebbleServiceManager.swift",
    "Trio/Sources/Services/PebbleService/PebbleServiceFormView.swift",
    "Trio/Sources/Services/PebbleService/PebbleService+UI.swift"
  ]

  main_target = project.targets.find { |t| t.name.to_s == "Trio" }
  source_phase = main_target&.source_build_phase

  pebble_files.each do |rel|
    next unless File.exist?(rel)
    basename = File.basename(rel)
    file_ref = project.files.find { |f| f.path && f.path.end_with?(basename) }
    target_group = rel.include?("PebbleManager") ? pm_group : ps_group

    if file_ref.nil?
      file_ref = project.add_file(rel, target_group)
      puts "Added fresh FileRef #{basename}"
    else
      unless target_group.children.include?(file_ref)
        target_group.children << file_ref
        puts "Moved #{basename} into correct Pebble group"
      end
    end

    if source_phase && file_ref
      unless source_phase.files.any? { |bf| bf.file_ref == file_ref rescue false }
        source_phase.add_file_reference(file_ref, true)
        puts "Wired #{basename} to Trio source phase"
      end
    end
  end
else
  puts "WARNING: Services group not found for Pebble"
end

puts "Pebble API repair done."


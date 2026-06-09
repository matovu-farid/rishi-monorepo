#!/usr/bin/env ruby
# Register Phase 3 app-target files (AppDependencies.swift + DebugAuthView.swift)
# in the rishi target's Sources build phase.
#
# As of Xcode 16, the `rishi` target uses a PBXFileSystemSynchronizedRootGroup
# pointing at the `rishi/rishi/` directory — any `.swift` file dropped into
# that directory is AUTOMATICALLY a member of the target's Sources build phase.
# No explicit PBXFileReference or PBXBuildFile entry is needed (or possible:
# `xcodeproj`'s `new_reference` rejects synchronized root groups).
#
# This script therefore:
#   1. Detects whether the rishi group is file-system-synchronized
#   2. If yes (current state) — verifies the expected files exist on disk and
#      exits 0 with a "nothing to do" message. Anyone running it later who
#      converts the group back to a regular PBXGroup will get the explicit
#      file references added via the fallback path.
#   3. If no — falls back to the classic add-PBXFileReference +
#      add-to-source_build_phase pattern (mirroring wire-rishi-auth.rb).
#
# Idempotent in both modes.

require 'xcodeproj'

PROJ_PATH = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
APP_SRC_DIR = File.expand_path('../rishi/rishi', __dir__)
FILES = %w[AppDependencies.swift DebugAuthView.swift]

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == 'rishi' } \
  or abort "FATAL: rishi target not found in #{PROJ_PATH}"

# Detect file-system-synchronized root group on the rishi target.
sync_group = nil
if app_target.respond_to?(:file_system_synchronized_groups)
  sync_group = app_target.file_system_synchronized_groups.find { |g| g.path == 'rishi' }
end

if sync_group
  puts "[wire-app-auth-files] rishi target uses PBXFileSystemSynchronizedRootGroup"
  puts "[wire-app-auth-files] Source files are auto-discovered from #{APP_SRC_DIR}"
  missing = FILES.reject { |f| File.exist?(File.join(APP_SRC_DIR, f)) }
  if missing.empty?
    FILES.each do |f|
      puts "[wire-app-auth-files] #{f} present on disk — auto-included in target"
    end
    puts "[wire-app-auth-files] No pbxproj edits needed; exiting 0"
    exit 0
  else
    abort "FATAL: expected files missing from #{APP_SRC_DIR}: #{missing.join(', ')}"
  end
end

# Fallback path: explicit PBXGroup membership.
puts "[wire-app-auth-files] rishi target uses classic PBXGroup; adding explicit file refs"

existing_app_swift_ref = project.files.find { |f| f.path&.end_with?('rishiApp.swift') }
parent_group = existing_app_swift_ref&.parent \
  || project.main_group.find_subpath('rishi', false) \
  || project.main_group

FILES.each do |filename|
  ref = project.files.find { |f| f.path&.end_with?(filename) }
  if ref.nil?
    ref = parent_group.new_reference(filename)
    puts "[wire-app-auth-files] Added file reference for #{filename}"
  else
    puts "[wire-app-auth-files] File reference for #{filename} already present"
  end

  already_in_sources = app_target.source_build_phase.files.any? do |bf|
    bf.file_ref == ref
  end
  unless already_in_sources
    app_target.source_build_phase.add_file_reference(ref)
    puts "[wire-app-auth-files] Added #{filename} to rishi Sources build phase"
  else
    puts "[wire-app-auth-files] #{filename} already in Sources build phase"
  end
end

project.save
puts "[wire-app-auth-files] Saved #{PROJ_PATH}"

#!/usr/bin/env ruby
# Register Phase 11 Plan 11-06 app-target files in the rishi target.
#
# As of Xcode 16, the `rishi` target uses a PBXFileSystemSynchronizedRootGroup
# pointing at the `rishi/rishi/` directory — any `.swift` file dropped into
# that directory (or a subdirectory) is AUTOMATICALLY a member of the
# target's Sources build phase. No explicit PBXFileReference / PBXBuildFile
# entry is needed (and the `xcodeproj` gem rejects adding refs under a
# synchronized root group).
#
# Mirrors `apps/apple/scripts/wire-app-auth-files.rb` (Phase 3 Plan 03-06):
#   1. Detects whether the rishi group is file-system-synchronized.
#   2. If yes (current state) — verifies the expected files exist on disk
#      and exits 0 with a "nothing to do" message.
#   3. If no — falls back to classic add-PBXFileReference +
#      add-to-source_build_phase pattern.
#
# Idempotent in both modes.

require 'xcodeproj'

PROJ_PATH   = File.expand_path('../rishi/rishi.xcodeproj', __dir__)
APP_SRC_DIR = File.expand_path('../rishi/rishi', __dir__)

# Phase 11 Plan 11-06 new app-layer files. Paths relative to APP_SRC_DIR.
FILES = %w[
  Billing/AppTelemetrySink.swift
  Billing/AppBillingPortalPresenter.swift
  Billing/AppReaderDefaultsBindings.swift
  Onboarding/OnboardingHost.swift
]

project = Xcodeproj::Project.open(PROJ_PATH)
app_target = project.targets.find { |t| t.name == 'rishi' } \
  or abort "FATAL: rishi target not found in #{PROJ_PATH}"

# Detect file-system-synchronized root group on the rishi target.
sync_group = nil
if app_target.respond_to?(:file_system_synchronized_groups)
  sync_group = app_target.file_system_synchronized_groups.find { |g| g.path == 'rishi' }
end

if sync_group
  puts "[wire-rishi-phase11-app-files] rishi target uses PBXFileSystemSynchronizedRootGroup"
  puts "[wire-rishi-phase11-app-files] Source files are auto-discovered from #{APP_SRC_DIR}"
  missing = FILES.reject { |f| File.exist?(File.join(APP_SRC_DIR, f)) }
  if missing.empty?
    FILES.each do |f|
      puts "[wire-rishi-phase11-app-files] #{f} present on disk — auto-included in target"
    end
    puts "[wire-rishi-phase11-app-files] No pbxproj edits needed; exiting 0"
    exit 0
  else
    abort "FATAL: expected files missing from #{APP_SRC_DIR}: #{missing.join(', ')}"
  end
end

# Fallback path: explicit PBXGroup membership.
puts "[wire-rishi-phase11-app-files] rishi target uses classic PBXGroup; adding explicit file refs"

existing_app_swift_ref = project.files.find { |f| f.path&.end_with?('rishiApp.swift') }
parent_group = existing_app_swift_ref&.parent \
  || project.main_group.find_subpath('rishi', false) \
  || project.main_group

FILES.each do |rel|
  filename = File.basename(rel)
  abs_path = File.join(APP_SRC_DIR, rel)
  ref = project.files.find { |f| f.path&.end_with?(rel) || f.path&.end_with?(filename) }
  if ref.nil?
    ref = parent_group.new_reference(abs_path)
    puts "[wire-rishi-phase11-app-files] Added file reference for #{rel}"
  else
    puts "[wire-rishi-phase11-app-files] File reference for #{rel} already present"
  end

  already_in_sources = app_target.source_build_phase.files.any? do |bf|
    bf.file_ref == ref
  end
  unless already_in_sources
    app_target.source_build_phase.add_file_reference(ref)
    puts "[wire-rishi-phase11-app-files] Added #{rel} to rishi Sources build phase"
  else
    puts "[wire-rishi-phase11-app-files] #{rel} already in Sources build phase"
  end
end

project.save
puts "[wire-rishi-phase11-app-files] Saved #{PROJ_PATH}"

#!/usr/bin/env ruby
# Wire the Phase 12 Plan 12-01 Mac Catalyst menu / shortcut Swift files into
# the rishi target's project.pbxproj.
#
# The rishi.xcodeproj uses `PBXFileSystemSynchronizedRootGroup` for both
# `rishi/rishi/` and `rishi/rishiTests/`, so any .swift file dropped under
# those folders is auto-discovered at project-load time. This script is
# therefore a no-op stub kept on disk so the plan's `files_modified` block
# has an artifact to point at, and so future contributors can adapt it if
# the project ever migrates back to explicit PBXFileReference entries.
#
# Idempotent: safe to re-run.

require 'xcodeproj'

PROJ_PATH = File.expand_path('../rishi/rishi.xcodeproj', __dir__)

project = Xcodeproj::Project.open(PROJ_PATH)

synchronized = project.root_object.main_group.children.any? do |child|
  child.is_a?(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup) &&
    (child.path == 'rishi' || child.path == 'rishi/rishi' || child.path == 'rishiTests')
end

if synchronized
  puts '[wire-mac-menu-files] rishi target uses PBXFileSystemSynchronizedRootGroup — Mac/ files auto-discovered.'
  puts '[wire-mac-menu-files] No pbxproj changes required.'
else
  warn '[wire-mac-menu-files] WARNING: rishi target is NOT using synchronized groups.'
  warn '[wire-mac-menu-files] Add explicit file references for:'
  warn '[wire-mac-menu-files]   rishi/rishi/Mac/RishiKeyboardCommands.swift'
  warn '[wire-mac-menu-files]   rishi/rishi/Mac/MacCommandRouter.swift'
  warn '[wire-mac-menu-files]   rishi/rishi/Mac/RishiMenuCommands.swift'
  warn '[wire-mac-menu-files]   rishi/rishiTests/Mac/MacCommandRouterTests.swift'
  warn '[wire-mac-menu-files]   rishi/rishiTests/Mac/RishiMenuCommandsTests.swift'
  exit 1
end

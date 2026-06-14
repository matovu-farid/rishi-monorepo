#!/usr/bin/env ruby
# Phase 25 Plan 25-10 — ensure the RishiSearch SwiftPM package is linked into
# the rishi app target so AppDependencies.swift can construct
# `USearchBookSearch` + `CoreMLMiniLMEmbedder` + the Responder factory.
#
# Idempotent: Plan 25-03 already registered the package via
# `register-rishi-search-25-03.rb`; this script re-runs that one so the
# linkage is asserted in the plan's wave too. Re-runs are safe (the wrapped
# script no-ops when references already exist).

require 'fileutils'

SCRIPT_DIR = File.expand_path(__dir__)
TARGET = File.join(SCRIPT_DIR, 'register-rishi-search-25-03.rb')

abort "[add-rishi-search-25-10] Missing wrapped script: #{TARGET}" unless File.exist?(TARGET)

system('ruby', TARGET) or abort "[add-rishi-search-25-10] Wrapped script failed"
puts "[add-rishi-search-25-10] RishiSearch linkage verified (delegated to register-rishi-search-25-03.rb)"

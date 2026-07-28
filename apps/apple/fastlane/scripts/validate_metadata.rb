#!/usr/bin/env ruby
# Validates fastlane metadata files before `deliver` upload.
#
# Usage:
#   ruby fastlane/scripts/validate_metadata.rb [path-to-apps/apple]
#
# Default path is the apps/apple/ directory two levels above this script
# (apps/apple/fastlane/scripts/.. ..). The script:
#   1. Confirms every required field file in metadata/en-US/ exists and is non-empty.
#   2. Enforces App Store Connect character limits per field.
#   3. Parses every URL field with URI; rejects non-http(s) schemes.
#   4. Confirms every review_information/ file exists and is non-empty.
#
# Exits 0 on pass. Exits 1 on any failure, printing every error to STDERR
# so a CI lane can collect them in one run rather than play whack-a-mole.

require 'uri'

# Apple's hard caps on metadata field length (chars). Source:
# https://docs.fastlane.tools/actions/upload_to_app_store/
LIMITS = {
  'name.txt'             => 30,
  'subtitle.txt'         => 30,
  'description.txt'      => 4000,
  'keywords.txt'         => 100,
  'promotional_text.txt' => 170,
  'release_notes.txt'    => 4000,
}.freeze

# Fields containing URLs. App Store Connect requires http(s).
URL_FIELDS = %w[marketing_url.txt support_url.txt privacy_url.txt].freeze

# Review-team contact fields. All five are required.
REVIEW_FIELDS = %w[first_name.txt last_name.txt email_address.txt
                   phone_number.txt notes.txt].freeze
REVIEW_PHONE_PLACEHOLDERS = [
  '+1 555 0100',
  '555-0100',
  '5550100',
].freeze

def validate(root)
  errors = []

  # Accept either the apps/apple project root OR the fastlane/ directory.
  # When called from the Fastfile we pass apps/apple; when called from the
  # self-test fixture we pass a tmpdir that already has metadata/ at the top.
  fastlane_metadata = File.join(root, 'fastlane', 'metadata')
  root_metadata     = File.join(root, 'metadata')
  metadata_root =
    if File.directory?(fastlane_metadata)
      fastlane_metadata
    else
      root_metadata
    end

  locale_dir = File.join(metadata_root, 'en-US')

  unless File.directory?(locale_dir)
    return ["metadata/en-US/ directory missing"]
  end

  (LIMITS.keys + URL_FIELDS).each do |name|
    path = File.join(locale_dir, name)
    unless File.file?(path)
      errors << "#{name} missing"
      next
    end
    body = File.read(path).strip
    if body.empty?
      errors << "#{name} is empty"
      next
    end
    if (limit = LIMITS[name]) && body.length > limit
      errors << "#{name} exceeds #{limit} char limit (was #{body.length})"
    end
    if URL_FIELDS.include?(name)
      begin
        uri = URI.parse(body)
        unless uri.scheme && %w[http https].include?(uri.scheme)
          scheme_display = uri.scheme ? uri.scheme.inspect : 'nil'
          errors << "#{name} must be http(s) (was #{scheme_display})"
        end
      rescue URI::InvalidURIError
        errors << "#{name} is not a valid URL"
      end
    end
  end

  review_dir = File.join(metadata_root, 'review_information')
  if File.directory?(review_dir)
    REVIEW_FIELDS.each do |name|
      path = File.join(review_dir, name)
      if !File.file?(path) || File.read(path).strip.empty?
        errors << "review_information/#{name} missing or empty"
      elsif name == 'phone_number.txt' && REVIEW_PHONE_PLACEHOLDERS.include?(File.read(path).strip)
        errors << 'review_information/phone_number.txt contains a placeholder number'
      end
    end
  else
    errors << "metadata/review_information/ directory missing"
  end

  errors
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV[0] || File.expand_path('../..', __dir__)
  errors = validate(root)
  if errors.empty?
    puts "[validate_metadata] OK"
    exit 0
  else
    errors.each { |e| warn "[validate_metadata] #{e}" }
    exit 1
  end
end

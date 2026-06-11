#!/usr/bin/env ruby
# Create the Rishi Pro subscription products in App Store Connect via the
# REST API. Idempotent — re-running skips existing entities.
#
# Why not fastlane? Spaceship (the ASC client fastlane bundles) does not
# wrap the subscription endpoints. We hit /v1/subscriptions directly with
# a JWT minted from the .p8 key.
#
# Required env vars:
#   ASC_KEY_ID     — 10-char key id from filename (e.g. H37XG77FHH)
#   ASC_ISSUER_ID  — UUID from ASC API keys page
#   ASC_KEY_PATH   — path to the .p8 file
#
# Run:
#   cd apps/apple && bundle exec ruby scripts/setup_storekit_products.rb

require "spaceship"
require "net/http"
require "json"
require "uri"

BUNDLE_ID   = "org.fidexa.rishi"
GROUP_NAME  = "Rishi Pro"
PRODUCTS    = [
  { product_id: "org.fidexa.rishi.pro.monthly", name: "Rishi Pro Monthly", period: "ONE_MONTH" },
  { product_id: "org.fidexa.rishi.pro.annual",  name: "Rishi Pro Annual",  period: "ONE_YEAR"  }
]
# Apple caps subscription localization description at 55 chars. This is
# the one-liner shown on the paywall sheet, NOT the App Store page description.
DESCRIPTION = "AI chat, voice, premium TTS, library sync."

ASC_BASE = "https://api.appstoreconnect.apple.com"

def fail!(msg); puts "ERROR: #{msg}"; exit 1; end

key_id    = ENV["ASC_KEY_ID"]    || fail!("Set ASC_KEY_ID")
issuer_id = ENV["ASC_ISSUER_ID"] || fail!("Set ASC_ISSUER_ID")
key_path  = File.expand_path(ENV["ASC_KEY_PATH"] || fail!("Set ASC_KEY_PATH"))
fail!(".p8 not found at #{key_path}") unless File.exist?(key_path)

token = Spaceship::ConnectAPI::Token.create(
  key_id: key_id, issuer_id: issuer_id, filepath: key_path
)

def asc_call(method, path, token, body = nil)
  uri = URI("#{ASC_BASE}#{path}")
  req = case method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri).tap { |r| r.body = body.to_json; r["Content-Type"] = "application/json" }
        end
  req["Authorization"] = "Bearer #{token.text}"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
  parsed = res.body.empty? ? {} : JSON.parse(res.body)
  [res.code.to_i, parsed]
end

# --- Resolve app ----------------------------------------------------------
code, body = asc_call(:get, "/v1/apps?filter[bundleId]=#{BUNDLE_ID}", token)
fail!("App lookup failed (#{code}): #{body}") if code >= 400
fail!("App #{BUNDLE_ID} not found") if body["data"].empty?
app_id = body["data"][0]["id"]
app_name = body["data"][0]["attributes"]["name"]
puts "App: #{app_name} (id=#{app_id})"

# --- Resolve / create subscription group ---------------------------------
code, body = asc_call(:get, "/v1/apps/#{app_id}/subscriptionGroups", token)
fail!("Group list failed (#{code})") if code >= 400
existing_group = body["data"].find { |g| g["attributes"]["referenceName"] == GROUP_NAME }

if existing_group
  group_id = existing_group["id"]
  puts "Subscription group exists: #{GROUP_NAME} (id=#{group_id})"
else
  group_body = {
    data: {
      type: "subscriptionGroups",
      attributes: { referenceName: GROUP_NAME },
      relationships: { app: { data: { type: "apps", id: app_id } } }
    }
  }
  code, body = asc_call(:post, "/v1/subscriptionGroups", token, group_body)
  fail!("Group create failed (#{code}): #{body}") if code >= 400
  group_id = body["data"]["id"]
  puts "Created subscription group: #{GROUP_NAME} (id=#{group_id})"

  # Add en-US localization for the group display name (App Store requires)
  glocal_body = {
    data: {
      type: "subscriptionGroupLocalizations",
      attributes: { name: GROUP_NAME, locale: "en-US", customAppName: nil },
      relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: group_id } } }
    }
  }
  asc_call(:post, "/v1/subscriptionGroupLocalizations", token, glocal_body)
end

# --- Resolve / create products + en-US localizations ---------------------
code, body = asc_call(:get, "/v1/subscriptionGroups/#{group_id}/subscriptions?limit=200", token)
fail!("Subscription list failed (#{code})") if code >= 400
existing_subs = body["data"].each_with_object({}) { |s, h| h[s["attributes"]["productId"]] = s }

PRODUCTS.each do |p|
  existing = existing_subs[p[:product_id]]
  if existing
    sub_id = existing["id"]
    puts "Product exists: #{p[:product_id]} (id=#{sub_id})"
  else
    sub_body = {
      data: {
        type: "subscriptions",
        attributes: {
          name: p[:name],
          productId: p[:product_id],
          subscriptionPeriod: p[:period],
          familySharable: false,
          groupLevel: 1
        },
        relationships: { group: { data: { type: "subscriptionGroups", id: group_id } } }
      }
    }
    code, body = asc_call(:post, "/v1/subscriptions", token, sub_body)
    if code >= 400
      puts "  Product create failed (#{code}): #{body}"
      next
    end
    sub_id = body["data"]["id"]
    puts "Created product: #{p[:product_id]} (id=#{sub_id})"
  end

  # en-US localization
  code, body = asc_call(:get, "/v1/subscriptions/#{sub_id}/subscriptionLocalizations", token)
  has_en_us = body["data"]&.any? { |l| l["attributes"]["locale"] == "en-US" }
  if has_en_us
    puts "  en-US localization exists"
  else
    loc_body = {
      data: {
        type: "subscriptionLocalizations",
        attributes: { name: p[:name], description: DESCRIPTION, locale: "en-US" },
        relationships: { subscription: { data: { type: "subscriptions", id: sub_id } } }
      }
    }
    code, body = asc_call(:post, "/v1/subscriptionLocalizations", token, loc_body)
    if code >= 400
      puts "  en-US localization create failed (#{code}): #{body}"
    else
      puts "  Added en-US localization"
    end
  end
end

puts ""
puts "Done. Three manual steps remain in ASC UI:"
puts "  1. Set price: $6.99/mo and $74.99/yr"
puts "  2. Add 7-day free-trial intro offers (new subscribers only)"
puts "  3. Upload App Review screenshot per product (after sandbox smoke)"
puts ""
puts "ASC link: https://appstoreconnect.apple.com/apps/#{app_id}/distribution/subscriptions"

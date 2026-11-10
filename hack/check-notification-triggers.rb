#!/usr/bin/env ruby
# Parse every Argo CD notification trigger and template in platform/argocd/values.yaml the way the
# notifications controller does: each `trigger.*` value is a YAML document of its own, stored as a
# string inside the ConfigMap.
#
# Why it exists: `helm template` only checks the OUTER yaml. An unquoted `oncePer: a ? b : c`
# (the `: ` of the ternary starts a mapping key) rendered fine, passed CI and was merged (PR #21),
# but the controller then failed to load the whole trigger list and sent NOTHING (no deployed
# message, no failure message) until it was found in the controller log on 2026-11-10.
#
# Used by .github/workflows/ci.yaml (job argocd-values); run by hand from the repository root:
#   ruby hack/check-notification-triggers.rb
require "yaml"

notifications = YAML.load_file("platform/argocd/values.yaml").fetch("notifications")
failures = 0

(notifications["triggers"] || {}).each do |key, text|
  begin
    list = YAML.safe_load(text)
    raise "not a list of {when, send} entries" unless list.is_a?(Array) && list.all? { |e| e["when"] && e["send"] }
    puts "ok   #{key}"
  rescue StandardError => e
    failures += 1
    puts "FAIL #{key}: #{e.message}"
  end
end

(notifications["templates"] || {}).each do |key, text|
  begin
    YAML.safe_load(text)
    puts "ok   #{key}"
  rescue StandardError => e
    failures += 1
    puts "FAIL #{key}: #{e.message}"
  end
end

abort "#{failures} notification entries do not parse" if failures.positive?

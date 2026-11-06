#!/usr/bin/env ruby
# Render every Helm chart that an Application in bootstrap/ installs, with the exact version
# and the values file the Application names. If a values key is misspelled in a way the chart
# rejects, or a version does not exist, this fails BEFORE the pull request is merged, instead
# of Argo CD showing a red application in the cluster.
#
# It reads the Applications themselves, so there is no second list to keep in sync: adding
# bootstrap/foo.yaml with a chart source adds it to the check automatically.
#
# Used by .github/workflows/ci.yaml (job argocd-values) and runnable by hand from the
# repository root:   ruby hack/render-charts.rb
#
# Handles both source styles in this repository:
#   classic repository   repoURL https://...        -> helm template NAME CHART --repo URL
#   OCI registry         repoURL public.ecr.aws/... -> helm template NAME oci://REPO/CHART
# and honours helm.releaseName, helm.skipCrds, destination.namespace and valueFiles written
# as $values/<path> (the file in the second, Git source). Ruby is on the CI runner and on macOS.
require "yaml"
require "open3"

failures = 0
Dir["bootstrap/*.yaml"].sort.each do |file|
  YAML.load_stream(File.read(file)).compact.each do |doc|
    next unless doc["kind"] == "Application"

    spec = doc["spec"]
    sources = spec["sources"] || [spec["source"]]
    chart_src = sources.find { |s| s["chart"] }
    next unless chart_src # a Git-path application, nothing to render

    name = doc["metadata"]["name"]
    helm = chart_src["helm"] || {}
    cmd = ["helm", "template", helm["releaseName"] || name]
    if chart_src["repoURL"].start_with?("http")
      cmd += [chart_src["chart"], "--repo", chart_src["repoURL"]]
    else
      cmd += ["oci://#{chart_src["repoURL"]}/#{chart_src["chart"]}"]
    end
    cmd += ["--version", chart_src["targetRevision"].to_s,
            "--namespace", spec["destination"]["namespace"]]
    cmd << "--skip-crds" if helm["skipCrds"]
    (helm["valueFiles"] || []).each do |vf|
      path = vf.sub("$values/", "")
      cmd += ["-f", path]
    end

    out, status = Open3.capture2e(*cmd)
    if status.success?
      puts "ok   #{name}  #{chart_src["chart"]} #{chart_src["targetRevision"]}  (#{out.scan(/^kind:/).size} objects)"
    else
      failures += 1
      puts "FAIL #{name}  #{chart_src["chart"]} #{chart_src["targetRevision"]}\n#{out.lines.first(15).join}"
    end
  end
end
exit(failures.zero? ? 0 : 1)

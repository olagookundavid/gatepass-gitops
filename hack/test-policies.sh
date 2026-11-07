#!/usr/bin/env bash
# Run the policy unit tests (policy-tests/) against platform/policies/. Used by CI (job
# policy-tests) and by hand: `hack/test-policies.sh` (needs the `kyverno` CLI, `brew install kyverno`).
#
# WHY A WRAPPER. Every policy is scoped with `matchConstraints.namespaceSelector` (label
# gatepass.dev/workloads=true), so the API server only calls Kyverno for our namespaces and a
# Kyverno outage can never block kube-system. The `kyverno test` CLI does not evaluate that
# selector: it marks every Pod "Excluded", reports a green pass and tests nothing (seen on
# 2026-11-07). So the script (1) checks that every policy really has the selector, then (2) tests
# a COPY of the policies with the selector removed. The live files are never touched.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/platform/policies"
cp -R policy-tests "$work/policy-tests"

python3 - "$work" <<'PY'
import glob, os, re, sys
work = sys.argv[1]
selector = re.compile(r'^    namespaceSelector:\n      matchLabels:\n        gatepass\.dev/workloads: "true"\n', re.M)
bad = []
for path in sorted(glob.glob('platform/policies/*.yaml')):
    text = open(path).read()
    if not selector.search(text):
        bad.append(path)
    open(os.path.join(work, path), 'w').write(selector.sub('', text))
if bad:
    sys.exit('policy without the gatepass.dev/workloads namespaceSelector: ' + ', '.join(bad))
PY

kyverno test "$work/policy-tests"

# Second gate: the pods the generic chart really renders (Deployment, migration Job, smoke-test
# Job) must satisfy the policies. The hand-written `good` Pod above could drift from the chart;
# this cannot. (The signature policy is not run: it needs the network and a real signature.)
rm -f "$work/platform/policies/signed-images.yaml"
printf 'image:\n  tag: sha-0000000\n  digest: sha256:%064d\n' 0 > "$work/pin.yaml"
helm template skeleton charts/gatepass-service -f apps/skeleton/values.yaml -f "$work/pin.yaml" \
  --set image.registry=000000000000.dkr.ecr.us-east-1.amazonaws.com --set migration.enabled=true \
  > "$work/rendered.yaml"
echo "== policies applied to the rendered chart"
kyverno apply "$work"/platform/policies/*.yaml --resource "$work/rendered.yaml"

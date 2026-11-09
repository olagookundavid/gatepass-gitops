#!/usr/bin/env bash
# Run the database bootstrap SQL twice against a real PostgreSQL 17 (a throwaway Docker container) and
# check the result. Used by CI (job bootstrap-sql) and by hand: `hack/test-bootstrap-sql.sh`.
#
# The SQL is taken from platform/data-bootstrap/configmap.yaml, the file that is DEPLOYED, so the test
# cannot pass on a copy that differs. A local stand-in role `rds_iam` is created first (on RDS that role
# exists already). Checks: both runs succeed (idempotent), the two databases exist, the three IAM roles
# are members of rds_iam and the two password roles are not.
set -euo pipefail
cd "$(dirname "$0")/.."

# A copy of the Docker config WITHOUT stored logins: the public registry allows anonymous pulls, and a
# stale login (an expired token for public.ecr.aws in ~/.docker/config.json or the keychain) would make
# the pull fail with "denied". The copy keeps the contexts, so Docker still finds its daemon socket.
export DOCKER_CONFIG="$(mktemp -d)"
if [[ -d "$HOME/.docker" ]]; then
  cp -R "$HOME/.docker/." "$DOCKER_CONFIG/" 2>/dev/null || true
  ruby -rjson -e 'f = File.join(ENV["DOCKER_CONFIG"], "config.json"); c = File.exist?(f) ? JSON.parse(File.read(f)) : {}; c.delete("auths"); c.delete("credsStore"); c.delete("credHelpers"); File.write(f, JSON.generate(c))'
fi

name="pgtest-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$DOCKER_CONFIG"' EXIT
sql="$(mktemp)"
ruby -ryaml -e 'puts YAML.load_file("platform/data-bootstrap/configmap.yaml")["data"]["bootstrap.sql"]' > "$sql"

# The same official image from two places: the public ECR mirror (what the cluster uses, no rate
# limit) and Docker Hub (fallback: some local Docker setups cannot pull anonymously from public ECR).
image=public.ecr.aws/docker/library/postgres:17-alpine
docker pull "$image" >/dev/null 2>&1 || image=postgres:17-alpine
echo "== image: $image"
docker run -d --name "$name" -e POSTGRES_PASSWORD=test "$image" >/dev/null
for _ in $(seq 1 40); do docker exec "$name" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec "$name" psql -U postgres -q -c "CREATE ROLE rds_iam" >/dev/null

for run in 1 2; do
  echo "== bootstrap run $run"
  docker exec -i "$name" psql -U postgres -q -v ON_ERROR_STOP=1 -v app_pw="pw'with\"chars" -v migrator_pw=m1 < "$sql" >/dev/null
done

q() { docker exec "$name" psql -U postgres -At -c "$1"; }
[[ "$(q "select count(*) from pg_database where datname in ('catalog','orders')")" == "2" ]] || { echo "!! databases missing"; exit 1; }
iam="$(q "select string_agg(rolname, ',' order by rolname) from pg_roles where rolname ~ '^(catalog|orders)_' and pg_has_role(rolname,'rds_iam','member')")"
[[ "$iam" == "catalog_app,catalog_migrator,orders_report" ]] || { echo "!! rds_iam members: $iam"; exit 1; }
echo "ok: 2 databases, rds_iam members = $iam, password roles = orders_app, orders_migrator"

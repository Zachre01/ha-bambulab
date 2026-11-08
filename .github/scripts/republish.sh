#!/usr/bin/env bash
# Republish the newest stable greghesp/ha-bambulab release for HACS.
# HACS 2.0.5 downloads releases/download/<ref>/bambu_lab.zip. A raw commit
# or the bare default branch name 404s. The ref must be the release tag, and
# the default branch HEAD must be that same commit. This job commits, tags,
# uploads the upstream zip, and moves the default branch before it exits.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

UPSTREAM="${UPSTREAM:-greghesp/ha-bambulab}"
ASSET_NAME="${ASSET_NAME:-bambu_lab.zip}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  DEFAULT_BRANCH="$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)"
fi

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "GITHUB_TOKEN is required" >&2
    exit 1
  fi
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git config commit.gpgsign false
  git config tag.gpgsign false
fi

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

reject_if_forbidden() {
  local err_file="$1"
  if grep -Eq 'HTTP 403|403 Forbidden|Permission to .* denied|Write access to repository not granted|not granted' "$err_file"; then
    echo "Push was rejected with 403. Token repository list:" >&2
    gh api installation/repositories --jq '.repositories[].full_name' >&2 || true
    exit 1
  fi
}

git_push() {
  local refspec="$1"
  shift
  local err_file attempt
  err_file="$(mktemp)"
  for attempt in 1 2 3 4 5; do
    if git push "$@" origin "$refspec" >"$err_file" 2>&1; then
      cat "$err_file" >&2
      rm -f "$err_file"
      return 0
    fi
    cat "$err_file" >&2
    reject_if_forbidden "$err_file"
    if [[ "$attempt" -eq 5 ]]; then
      rm -f "$err_file"
      die "git push failed: ${refspec}"
    fi
    sleep $((2 ** attempt))
  done
}

newest_stable_tag() {
  local page=1 body tag count
  while [[ "$page" -le 5 ]]; do
    body="$(gh api "repos/${UPSTREAM}/releases?per_page=100&page=${page}")"
    count="$(jq 'length' <<<"$body")"
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    tag="$(jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty' <<<"$body")"
    if [[ -n "$tag" ]]; then
      printf '%s\n' "$tag"
      return 0
    fi
    page=$((page + 1))
  done
  return 1
}

assert_stable_release() {
  local body prerelease draft
  body="$(gh api "repos/${UPSTREAM}/releases/tags/${TAG}")"
  prerelease="$(jq -r .prerelease <<<"$body")"
  draft="$(jq -r .draft <<<"$body")"
  if [[ "$prerelease" != "false" || "$draft" != "false" ]]; then
    die "refusing to publish draft or prerelease ${TAG}"
  fi
  printf '%s\n' "$body" >"${WORKDIR}/upstream-release.json"
}

download_upstream_zip() {
  local expected actual
  gh release download "$TAG" --repo "$UPSTREAM" --pattern "$ASSET_NAME" --dir "$WORKDIR" --clobber
  ZIP="${WORKDIR}/${ASSET_NAME}"
  [[ -f "$ZIP" ]] || die "upstream asset ${ASSET_NAME} was not downloaded"
  python3 - "$ZIP" <<'PY'
import sys
import zipfile

archive = zipfile.ZipFile(sys.argv[1])
for name in archive.namelist():
    parts = name.split("/")
    if name.startswith("/") or name.startswith("\\") or ".." in parts or "\\" in name:
        raise SystemExit(f"unsafe zip path: {name}")
PY
  actual="sha256:$(sha256sum "$ZIP" | awk '{ print $1 }')"
  expected="$(jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .digest // empty' "${WORKDIR}/upstream-release.json")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    die "upstream ${ASSET_NAME} digest ${actual} != ${expected}"
  fi
  printf '%s\n' "$actual" >"${WORKDIR}/zip.digest"
}

download_upstream_hacs_json() {
  gh api -H "Accept: application/vnd.github.raw" \
    "repos/${UPSTREAM}/contents/hacs.json?ref=${TAG}" >"${WORKDIR}/hacs.json"
  jq -e '.zip_release == true and .filename == "bambu_lab.zip" and (.homeassistant | type == "string" and length > 0)' \
    "${WORKDIR}/hacs.json" >/dev/null || die "upstream hacs.json is missing zip_release, filename, or homeassistant"
}

write_readme() {
  cat >README.md <<EOF
# Bambu Lab

This repository republishes [greghesp/ha-bambulab](https://github.com/${UPSTREAM}) releases for HACS.

Upstream: https://github.com/${UPSTREAM}
EOF
}

write_license() {
  if gh api -H "Accept: application/vnd.github.raw" \
    "repos/${UPSTREAM}/contents/LICENSE?ref=${TAG}" >"${WORKDIR}/LICENSE"; then
    cp "${WORKDIR}/LICENSE" LICENSE
  fi
}

prepare_tree() {
  download_upstream_zip
  download_upstream_hacs_json
  cp "${WORKDIR}/hacs.json" hacs.json
  write_readme
  write_license
  rm -rf custom_components/bambu_lab
  mkdir -p custom_components/bambu_lab
  unzip -q -o "$ZIP" -d custom_components/bambu_lab
  local manifest_version tag_version
  manifest_version="$(jq -r .version custom_components/bambu_lab/manifest.json)"
  tag_version="${TAG#v}"
  if [[ "$manifest_version" != "$tag_version" && "$manifest_version" != "$TAG" ]]; then
    die "manifest version ${manifest_version} does not match tag ${TAG}"
  fi
  [[ -f .github/workflows/republish.yml ]] || die "workflow file is missing"
  [[ -f .github/scripts/republish.sh ]] || die "publish script is missing"
}

commit_tree() {
  git add -A -- hacs.json README.md custom_components .github
  if [[ -f LICENSE ]]; then
    git add -A -- LICENSE
  fi
  if git diff --cached --name-only | grep -Eq '(^|/)bambu_lab\.zip$'; then
    die "refusing to commit ${ASSET_NAME}"
  fi
  if git diff --cached --quiet; then
    return 0
  fi
  git commit -m "Publish ${UPSTREAM} ${TAG}" \
    -m "Republish the upstream stable release for HACS. This commit is the release tag, and the default branch moves to it in the same publish."
}

ensure_lightweight_tag() {
  local existing
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    existing="$(git rev-parse "refs/tags/${TAG}^{}")"
    if [[ "$existing" != "$COMMIT_SHA" ]]; then
      die "local tag ${TAG} points at ${existing}, not ${COMMIT_SHA}"
    fi
    if [[ "$(git cat-file -t "refs/tags/${TAG}")" != "commit" ]]; then
      die "local tag ${TAG} is not lightweight"
    fi
  else
    git -c tag.gpgsign=false tag "$TAG" "$COMMIT_SHA"
  fi
  if [[ "$(git cat-file -t "refs/tags/${TAG}")" != "commit" ]]; then
    die "tag ${TAG} is not a lightweight tag"
  fi
}

release_has_asset() {
  gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fxq "$ASSET_NAME"
}

create_or_upload_release() {
  download_upstream_zip
  cat >"${WORKDIR}/notes.md" <<EOF
Republish of https://github.com/${UPSTREAM}/releases/tag/${TAG} for HACS.

The \`${ASSET_NAME}\` asset is the upstream release asset, unchanged.
EOF
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    if release_has_asset; then
      verify_asset_bytes
      return 0
    fi
    gh release upload "$TAG" "$ZIP" --repo "$REPO"
  else
    gh release create "$TAG" "$ZIP" \
      --repo "$REPO" \
      --title "$TAG" \
      --notes-file "${WORKDIR}/notes.md" \
      --verify-tag
  fi
  verify_asset_bytes
}

verify_asset_bytes() {
  local got
  got="$(mktemp -d)"
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET_NAME" --dir "$got" --clobber
  cmp "$ZIP" "${got}/${ASSET_NAME}" || die "published ${ASSET_NAME} bytes differ from upstream"
  rm -rf "$got"
}

move_default_branch() {
  local dest_sha="$1"
  local expected="$2"
  if [[ "$expected" == "$dest_sha" ]]; then
    echo "default branch ${DEFAULT_BRANCH} already at ${dest_sha}"
    return 0
  fi
  git_push "${dest_sha}:refs/heads/${DEFAULT_BRANCH}" \
    --force-with-lease="refs/heads/${DEFAULT_BRANCH}:${expected}"
}

verify_remote() {
  local attempt main_sha tag_type tag_sha
  for attempt in 1 2 3 4 5; do
    main_sha="$(gh api "repos/${REPO}/commits/${DEFAULT_BRANCH}" --jq .sha)"
    tag_type="$(gh api "repos/${REPO}/git/ref/tags/${TAG}" --jq .object.type)"
    tag_sha="$(gh api "repos/${REPO}/git/ref/tags/${TAG}" --jq .object.sha)"
    if [[ "$main_sha" == "$tag_sha" && "$tag_type" == "commit" ]]; then
      echo "verified ${DEFAULT_BRANCH} ${main_sha} equals lightweight tag ${TAG}"
      return 0
    fi
    sleep $((attempt * 2))
  done
  die "default branch ${main_sha} does not equal lightweight tag ${tag_sha} (${tag_type})"
}

TAG="$(newest_stable_tag)" || die "no stable upstream release found"
[[ -n "$TAG" && "$TAG" != "null" ]] || die "no stable upstream release found"
echo "newest stable upstream tag: ${TAG}"
assert_stable_release

git fetch origin --tags --prune --quiet

REMOTE_MAIN_SHA="$(git rev-parse "origin/${DEFAULT_BRANCH}")"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  if [[ "$(git cat-file -t "refs/tags/${TAG}")" != "commit" ]]; then
    die "tag ${TAG} is not a lightweight tag"
  fi
  # ls-remote peels only annotated tags, so resolve the lightweight tag locally.
  REMOTE_TAG_SHA="$(git rev-parse "refs/tags/${TAG}^{}")"
else
  REMOTE_TAG_SHA=""
fi

if [[ -n "$REMOTE_TAG_SHA" ]]; then
  echo "tag ${TAG} already exists at ${REMOTE_TAG_SHA}"
  create_or_upload_release
  move_default_branch "$REMOTE_TAG_SHA" "$REMOTE_MAIN_SHA"
  verify_remote
  exit 0
fi

HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$REMOTE_MAIN_SHA" ]]; then
  die "HEAD ${HEAD_SHA} is not ${DEFAULT_BRANCH} ${REMOTE_MAIN_SHA}"
fi

prepare_tree
commit_tree
COMMIT_SHA="$(git rev-parse HEAD)"
ensure_lightweight_tag
git_push "refs/tags/${TAG}:refs/tags/${TAG}"
create_or_upload_release
move_default_branch "$COMMIT_SHA" "$REMOTE_MAIN_SHA"
verify_remote

#!/bin/sh
# Renders Octomaton's deployment the way this repository's Applications deploy it, so a change here or in Octomaton's
# deploy/ that no longer fits is caught before Argo CD syncs it (docs/delivery/designs/octomaton.md). For every
# Application under apps/ and platform/ whose source is arikkfir-org/octomaton, it fetches that repository at the
# Application's targetRevision and renders the source path with the Application's kustomize options as Argo CD 3.5
# applies them (util/kustomize/kustomize.go): images (environment variables substituted), then its patches appended to
# kustomization.yaml, each of which must match something. Runs in docker.io/alpine/k8s, whose kustomize is Argo CD's.
#
#   .tekton/octomaton-manifests.sh OUT
#
# OCTOMATON=<directory> renders that checkout of arikkfir-org/octomaton instead of fetching the revision.
set -eu

out="${1:?usage: .tekton/octomaton-manifests.sh OUT}"
octomaton=https://github.com/arikkfir-org/octomaton

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${out}" "${work}/render"
failures=0

# Every Application that deploys from Octomaton's repository, one per line as JSON: its name, revision, path and
# kustomize options. Only the files that name the repository are read.
find apps platform -name '*.yaml' > "${work}/files"
: > "${work}/sources.json"
while read -r file; do
  status=0
  grep -q -F "${octomaton}" "${file}" || status=$?
  case "${status}" in
    0) ;;
    1) continue ;;
    *)
      echo "could not read ${file}" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac
  # Per document, and only through the context: yq evaluates a variable even where a select left nothing.
  if ! yq e -o=json -I=0 '
    select(.kind == "Application")
    | {"name": .metadata.name, "source": (.spec.sources // [.spec.source])[]}
    | select(.source.repoURL == "'"${octomaton}"'")
    | {"name": .name, "revision": .source.targetRevision, "path": .source.path, "kustomize": (.source.kustomize // {})}
  ' "${file}" >> "${work}/sources.json"; then
    echo "could not read ${file}" >&2
    failures=$((failures + 1))
  fi
done < "${work}/files"

# checkout REVISION puts Octomaton's repository at REVISION in WORK/repo/REVISION, once per revision, and prints
# the commit, which is what Argo CD substitutes in the images.
checkout() {
  dir="${work}/repo/$1"
  if [ -n "${OCTOMATON:-}" ]; then
    dir="${OCTOMATON}"
  elif [ ! -d "${dir}" ]; then
    mkdir -p "${dir}" || return 1
    git -C "${dir}" init -q . || return 1
    git -C "${dir}" remote add origin "${octomaton}" || return 1
    git -C "${dir}" fetch -q --depth=1 origin "$1" || return 1
    git -C "${dir}" checkout -q --detach FETCH_HEAD || return 1
  fi
  git -C "${dir}" rev-parse HEAD || return 1
}

# render NAME SOURCE OPTIONS renders a copy of the kustomization SOURCE with the kustomize options in the file OPTIONS
# into OUT/NAME.yaml, working under WORK/render, apart from the clones. It runs where set -e doesn't apply, so every
# step returns on failure.
render() {
  name="$1"
  source="$2"
  options="$3"
  # Only the options this applies: with any other, Argo CD would render something else.
  others="$(yq '[keys[] | select(. != "images" and . != "patches")] | join(", ")' "${options}")" || return 1
  if [ -n "${others}" ]; then
    echo "${name}: kustomize options this script doesn't apply: ${others}" >&2
    return 1
  fi
  images="$(yq '.images[]? | envsubst(nu)' "${options}")" || return 1
  patches="$(yq '.patches // [] | length' "${options}")" || return 1

  # kustomize skips a patch whose target matches nothing, and Argo CD would deploy without it: a rename on either side.
  # So each target is probed where Argo CD applies its patch, after the patches before it: a marker patch with the same
  # target, which kustomize matches as it would the patch (group, version, kind, name, namespace, selectors), must mark
  # something. An untargeted patch that matches nothing fails the build by itself.
  i=0
  while [ "${i}" -lt "${patches}" ]; do
    targeted="$(I="${i}" yq '.patches[env(I)] | has("target")' "${options}")" || return 1
    if [ "${targeted}" = "true" ]; then
      probe="${work}/render/${name}.probe-${i}"
      cp -R "${source}" "${probe}" || return 1
      I="${i}" OPTIONS="${options}" yq -i '
        load(env(OPTIONS)).patches as $patches
        | .patches += ($patches | to_entries | map(select(.key < env(I)) | .value))
        | .patches += [{
            "target": $patches[env(I)].target,
            "patch": "[{\"op\": \"add\", \"path\": \"/metadata/annotations\", \"value\": {\"octomaton-manifests.sh/probe\": \"matched\"}}]"
          }]
      ' "${probe}/kustomization.yaml" || return 1
      kustomize build "${probe}" > "${probe}.yaml" || return 1
      yq -N 'select(.metadata.annotations["octomaton-manifests.sh/probe"] == "matched") | .kind' "${probe}.yaml" \
        > "${probe}.matched" || return 1
      if [ ! -s "${probe}.matched" ]; then
        target="$(I="${i}" yq -o=json -I=0 '.patches[env(I)].target' "${options}")" || return 1
        echo "${name}: patch ${i}'s target ${target} matches nothing in ${source#"${work}/"}" >&2
        return 1
      fi
    fi
    i=$((i + 1))
  done

  cp -R "${source}" "${work}/render/${name}" || return 1
  (
    cd "${work}/render/${name}" || exit 1
    for image in ${images}; do
      kustomize edit set image "${image}" || exit 1
    done
    if [ "${patches}" -gt 0 ]; then
      OPTIONS="${options}" yq -i '.patches += load(env(OPTIONS)).patches' kustomization.yaml || exit 1
    fi
  ) || return 1
  kustomize build "${work}/render/${name}" > "${out}/${name}.yaml" || return 1
  echo "Octomaton as Application ${name} deploys it: ${out}/${name}.yaml"
}

sources=0
while read -r source; do
  sources=$((sources + 1))
  name="$(printf '%s' "${source}" | yq -p=json '.name')"
  revision="$(printf '%s' "${source}" | yq -p=json '.revision')"
  path="$(printf '%s' "${source}" | yq -p=json '.path')"
  printf '%s' "${source}" | yq -p=json -o=yaml '.kustomize' > "${work}/render/${name}.options.yaml"
  if ! commit="$(checkout "${revision}")"; then
    echo "could not fetch ${octomaton} at ${revision} for Application ${name}" >&2
    failures=$((failures + 1))
    continue
  fi
  if [ -n "${OCTOMATON:-}" ]; then
    dir="${OCTOMATON}"
  else
    dir="${work}/repo/${revision}"
  fi
  # What Argo CD substitutes in images.
  export ARGOCD_APP_REVISION="${commit}"
  ARGOCD_APP_REVISION_SHORT="$(printf '%s' "${commit}" | cut -c1-7)"
  ARGOCD_APP_REVISION_SHORT_8="$(printf '%s' "${commit}" | cut -c1-8)"
  export ARGOCD_APP_REVISION_SHORT ARGOCD_APP_REVISION_SHORT_8
  if ! render "${name}" "${dir}/${path}" "${work}/render/${name}.options.yaml"; then
    echo "could not render Octomaton as Application ${name} deploys it" >&2
    failures=$((failures + 1))
  fi
done < "${work}/sources.json"
# The hub runs Octomaton from this repository: finding no Application means this check lost track of it.
if [ "${sources}" -eq 0 ]; then
  echo "no Application deploys from ${octomaton}" >&2
  failures=$((failures + 1))
fi

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s) above" >&2
  exit 1
fi

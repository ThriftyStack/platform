#!/usr/bin/env bash
# Mint a new 24h token with the current one, check whoami, then swap the file.
# The token is never printed. An expired current token exits non-zero.
set -euo pipefail
set +x

dir=/home/box/.kube/mgmt-reader
kubeconfig=${dir}/config
token_file=${dir}/token
ca_file=${dir}/ca.crt
umask 077

tmp=
verify_cfg=
err=
cleanup() {
  if [[ -n ${tmp} ]]; then
    rm -f "${tmp}"
  fi
  if [[ -n ${verify_cfg} ]]; then
    rm -f "${verify_cfg}"
  fi
  if [[ -n ${err} ]]; then
    rm -f "${err}"
  fi
}
trap cleanup EXIT

if [[ ! -f ${kubeconfig} || ! -f ${token_file} || ! -f ${ca_file} ]]; then
  echo "renew: missing kubeconfig, token, or CA; Egor must re-mint from the Mac" >&2
  exit 1
fi
mode=$(stat -c '%a' "${token_file}")
if [[ ${mode} != "600" ]]; then
  echo "renew: ${token_file} must be mode 600" >&2
  exit 1
fi

err=$(mktemp "${dir}/renew-err.XXXXXX")
tmp=$(mktemp "${dir}/token.XXXXXX")
chmod 600 "${err}" "${tmp}"

if ! kubectl --kubeconfig="${kubeconfig}" create token box-reader \
  -n operator-access \
  --duration=24h \
  --bound-object-kind=Secret \
  --bound-object-name=box-reader-anchor \
  >"${tmp}" 2>"${err}"; then
  if grep -Eiq 'unauthorized|expired|provide credentials|logged in' "${err}"; then
    echo "renew: box-reader token is expired; Egor must re-mint it from the Mac" >&2
  else
    echo "renew: failed to mint a replacement token" >&2
  fi
  exit 1
fi
if [[ ! -s ${tmp} ]]; then
  echo "renew: minted token was empty" >&2
  exit 1
fi

verify_cfg=$(mktemp "${dir}/kubeconfig.XXXXXX")
chmod 600 "${verify_cfg}"
cat > "${verify_cfg}" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: management
  cluster:
    certificate-authority: ${ca_file}
    server: https://10.0.10.83:6443
contexts:
- name: box-reader
  context:
    cluster: management
    user: box-reader
current-context: box-reader
users:
- name: box-reader
  user:
    tokenFile: ${tmp}
EOF

who=
if ! who=$(kubectl --kubeconfig="${verify_cfg}" auth whoami -o json 2>"${err}"); then
  echo "renew: replacement token was rejected by the API" >&2
  exit 1
fi
if ! printf '%s' "${who}" | python3 -c 'import json,sys; body=json.load(sys.stdin); user=(body.get("status") or {}).get("userInfo") or {}; raise SystemExit(0 if user.get("username")=="system:serviceaccount:operator-access:box-reader" else 1)'; then
  echo "renew: whoami did not return system:serviceaccount:operator-access:box-reader" >&2
  exit 1
fi
unset who

chmod 600 "${tmp}"
mv -f "${tmp}" "${token_file}"
tmp=
chmod 600 "${token_file}"
echo "renew: replaced box-reader token" >&2

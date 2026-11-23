#!/usr/bin/env bash
# Start warp-svc in the background and wait until the management API answers.
# The enroll file is mode 600 and is never printed.
set -euo pipefail
set +x

dir=/home/box/.kube/mgmt-reader
env_file=${dir}/warp-enroll.env
log=${dir}/warp.log
pid_file=${dir}/warp.pid
api_host=10.0.10.83
api_port=6443

if [[ ! -f ${env_file} ]]; then
  echo "warp-up: missing ${env_file}" >&2
  exit 1
fi
mode=$(stat -c '%a' "${env_file}")
if [[ ${mode} != "600" ]]; then
  echo "warp-up: ${env_file} must be mode 600" >&2
  exit 1
fi

while IFS= read -r line || [[ -n ${line} ]]; do
  [[ -z ${line} || ${line} == \#* ]] && continue
  if [[ ${line} == export\ * ]]; then
    line=${line#export }
  fi
  if [[ ! ${line} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "warp-up: ${env_file} must contain KEY=VALUE lines" >&2
    exit 1
  fi
  key=${line%%=*}
  value=${line#*=}
  if [[ ${value} == \"*\" ]]; then
    value=${value#\"}
    value=${value%\"}
  elif [[ ${value} == \'*\' ]]; then
    value=${value#\'}
    value=${value%\'}
  fi
  export "${key}=${value}"
done < "${env_file}"

running=0
if [[ -f ${pid_file} ]]; then
  pid=$(<"${pid_file}")
  if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    running=1
  fi
fi

if [[ ${running} -eq 0 ]]; then
  if ! command -v warp-svc >/dev/null 2>&1; then
    echo "warp-up: warp-svc is not installed" >&2
    exit 1
  fi
  nohup warp-svc >>"${log}" 2>&1 &
  pid=$!
  disown "${pid}" 2>/dev/null || true
  sleep 0.2
  if ! kill -0 "${pid}" 2>/dev/null; then
    echo "warp-up: warp-svc did not stay running" >&2
    exit 1
  fi
  printf '%s\n' "${pid}" > "${pid_file}"
  chmod 600 "${pid_file}"
fi

api_open() {
  timeout 2 bash -c "exec 3<>/dev/tcp/${api_host}/${api_port}" 2>/dev/null
}

deadline=$((SECONDS + 60))
until api_open; do
  if (( SECONDS >= deadline )); then
    echo "warp-up: ${api_host}:${api_port} is not reachable" >&2
    exit 1
  fi
  sleep 1
done

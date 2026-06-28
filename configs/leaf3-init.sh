#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Host-specific values
# ------------------------------------------------------------
# 別の leaf へ流用する場合は、基本的に NODE_NAME だけを変更する。
# 例: leaf4 なら NODE_NAME=leaf4 とし、/configs/leaf4-linux.sh と
#     /configs/leaf4-frr.conf を用意する。
# ============================================================
NODE_NAME="leaf3"

# ラボ操作用ユーザー。containerlab の管理アクセス確認に使う。
ADMIN_USER="admin"
ADMIN_PASSWORD="admin"

# NODE_NAME から派生する設定ファイル。
LINUX_CONFIG="/configs/${NODE_NAME}-linux.sh"
FRR_CONFIG="/configs/${NODE_NAME}-frr.conf"

# config vlan / config vxlan を投入する前に必要な SONiC manager。
SONIC_MANAGER_SERVICES="portmgrd intfmgrd vlanmgrd vxlanmgrd"

# このラボで使う FRR daemon。mgmtd は vtysh -f が詰まることがあるため停止する。
FRR_DAEMONS_ENABLE="zebra bgpd ospfd"
FRR_DAEMONS_DISABLE="mgmtd staticd"

# 起動待ちの最大時間。
SONIC_MANAGER_WAIT_RETRIES="60"
VTYSH_WAIT_RETRIES="60"

# BGP sessions that should be ready after FRR config is applied.
# The retry loop uses only local clears on this SONiC leaf; spines are not touched.
BGP_UNDERLAY_NEIGHBORS="Ethernet0 Ethernet4"
BGP_EVPN_NEIGHBORS="10.255.0.101 10.255.0.102"
BGP_WAIT_RETRIES="24"
BGP_WAIT_INTERVAL="5"

# ConfigDB を保存するかどうか。再起動後の再現性を優先して標準は保存する。
SAVE_CONFIG_DB="1"

log() {
  echo "[${NODE_NAME}-init] $*"
}

install_lab_packages() {
  # SONiC VS コンテナ内で診断しやすいよう、ラボ用の最小ツールを入れる。
  log "install lab packages"
  export DEBIAN_FRONTEND=noninteractive

  if ! apt update || ! apt install -y sudo openssh-server traceroute iputils-tracepath iputils-ping tcpdump; then
    log "WARNING: package install failed, continue with existing packages"
  fi
}

setup_admin_user() {
  # SSH で入って状態確認できるよう、ラボ用 admin ユーザーを用意する。
  log "setup ${ADMIN_USER} user"
  id "${ADMIN_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${ADMIN_USER}"

  echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
  echo "root:${ADMIN_PASSWORD}" | chpasswd
  usermod -aG sudo,frrvty,frr "${ADMIN_USER}" || true

  cat >"/etc/sudoers.d/${ADMIN_USER}" <<EOF
${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "/etc/sudoers.d/${ADMIN_USER}"
  visudo -cf "/etc/sudoers.d/${ADMIN_USER}" >/dev/null
}

start_sshd() {
  # containerlab の管理ネットワークからログインできるよう sshd を起動する。
  log "start sshd"
  mkdir -p /run/sshd
  /usr/sbin/sshd || true
}


install_dummy_docker_command() {
  # SONiC VS コンテナ内の補完や一部 CLI が docker コマンドを探すことがある。
  # ラボではコンテナ内から Docker を操作しないため、空実装を置いて警告だけを抑える。
  log "install dummy docker command"

  cat >/usr/bin/docker <<'EOF'
#!/usr/bin/env bash
# Dummy docker command for sonic-vs lab shells and completion hooks.
exit 0
EOF

  chmod 755 /usr/bin/docker
}


ensure_mgmt_interface() {
  # SONiC manager 起動後に management interface eth0 が DOWN になることがある。
  # containerlab の管理ネットワークから SSH できるよう、最後に必ず eth0 を上げる。
  log "ensure management interface eth0 is up"
  ip link set eth0 up || true
  ip -br addr show eth0 || true
}

start_sonic_managers() {
  # vlanmgrd / vxlanmgrd が起動する前に config を入れると、
  # Vlan100 -> VNI 10100 が実デバイスへ反映されないことがある。
  log "start SONiC managers: ${SONIC_MANAGER_SERVICES}"

  for svc in ${SONIC_MANAGER_SERVICES}; do
    supervisorctl start "${svc}" || true
  done
}

wait_for_sonic_managers() {
  # supervisor 上で対象 manager が RUNNING になるまで待つ。
  log "wait for SONiC managers"

  for i in $(seq 1 "${SONIC_MANAGER_WAIT_RETRIES}"); do
    all_running=1

    for svc in ${SONIC_MANAGER_SERVICES}; do
      if ! supervisorctl status "${svc}" 2>/dev/null | grep -q RUNNING; then
        all_running=0
      fi
    done

    if [ "${all_running}" -eq 1 ]; then
      log "SONiC managers ready"
      return 0
    fi

    log "waiting SONiC managers... ${i}"
    sleep 2
  done

  log "ERROR: SONiC managers are not ready"
  supervisorctl status ${SONIC_MANAGER_SERVICES} || true
  return 1
}

apply_linux_config() {
  # Interface / IP / MTU / sysctl / VLAN / VXLAN など、
  # Linux と SONiC ConfigDB 側の設定は node 別ファイルへ分離する。
  if [ ! -f "${LINUX_CONFIG}" ]; then
    log "${LINUX_CONFIG} not found, skip Linux/SONiC config"
    return 0
  fi

  log "apply ${LINUX_CONFIG}"
  timeout 120 bash "${LINUX_CONFIG}" >/tmp/"${NODE_NAME}"-linux-apply.log 2>&1
  rc=$?

  log "${LINUX_CONFIG} return code: ${rc}"
  cat /tmp/"${NODE_NAME}"-linux-apply.log || true

  if [ "${rc}" -ne 0 ]; then
    log "ERROR: failed to apply ${LINUX_CONFIG}"
    return "${rc}"
  fi
}

set_frr_daemon() {
  local name="$1"
  local value="$2"

  if grep -q "^${name}=" /etc/frr/daemons; then
    sed -i "s/^${name}=.*/${name}=${value}/" /etc/frr/daemons
  else
    echo "${name}=${value}" >>/etc/frr/daemons
  fi
}

configure_frr_daemons() {
  # 必要な daemon だけを有効化し、ラボで不要または邪魔になる daemon を止める。
  if [ ! -f /etc/frr/daemons ]; then
    log "/etc/frr/daemons not found, skip daemon config"
    return 0
  fi

  log "configure FRR daemons"

  for daemon in ${FRR_DAEMONS_ENABLE}; do
    set_frr_daemon "${daemon}" yes
  done

  for daemon in ${FRR_DAEMONS_DISABLE}; do
    set_frr_daemon "${daemon}" no
  done

  grep -E "^(zebra|bgpd|ospfd|mgmtd|staticd)=" /etc/frr/daemons || true
}

restart_frr() {
  # daemon 設定を反映するため FRR を再起動する。
  log "restart FRR"
  service frr restart || /usr/lib/frr/frrinit.sh restart
}

wait_for_vtysh() {
  # FRR 設定投入前に vtysh が応答するまで待つ。
  log "wait for vtysh"

  for i in $(seq 1 "${VTYSH_WAIT_RETRIES}"); do
    if timeout 5 vtysh -c "show version" >/tmp/"${NODE_NAME}"-vtysh.out 2>/tmp/"${NODE_NAME}"-vtysh.err; then
      log "vtysh ready"
      return 0
    fi

    log "waiting vtysh... ${i}"
    cat /tmp/"${NODE_NAME}"-vtysh.err || true
    sleep 5
  done

  log "ERROR: vtysh is not ready"
  ps -ef | grep -E "watchfrr|mgmtd|zebra|bgpd|ospfd|staticd" | grep -v grep || true
  ls -l /var/run/frr || true
  return 1
}

apply_frr_config() {
  # FRR の BGP/EVPN 設定を投入する。
  # write memory は sonic-vs 上で詰まることがあるため、投入時だけ除外する。
  if [ ! -f "${FRR_CONFIG}" ]; then
    log "${FRR_CONFIG} not found, skip FRR config"
    return 0
  fi

  log "apply ${FRR_CONFIG}"
  awk '
    /^[[:space:]]*write memory[[:space:]]*$/ { next }
    { print }
  ' "${FRR_CONFIG}" >/tmp/"${NODE_NAME}"-frr.apply.conf

  timeout 60 vtysh -f /tmp/"${NODE_NAME}"-frr.apply.conf >/tmp/"${NODE_NAME}"-frr-apply.log 2>&1
  rc=$?

  log "vtysh -f return code: ${rc}"
  cat /tmp/"${NODE_NAME}"-frr-apply.log || true

  if [ "${rc}" -ne 0 ]; then
    log "ERROR: failed to apply ${FRR_CONFIG}"
    vtysh -c "show running-config" || true
    return "${rc}"
  fi
}


bgp_neighbor_established() {
  local neighbor="$1"

  vtysh -c "show bgp neighbors ${neighbor}" 2>/dev/null | grep -q "BGP state = Established"
}

wait_for_bgp_sessions() {
  # In sonic-vs, FRR interface neighbors may need a short time for link-local
  # NHT after FRR config is applied. Do not repeatedly clear neighbors here;
  # repeated clears can keep BGP from settling. This waits and reports state only.
  local attempt neighbor all_established

  log "wait for BGP sessions"

  for attempt in $(seq 1 "${BGP_WAIT_RETRIES}"); do
    all_established=1

    for neighbor in ${BGP_UNDERLAY_NEIGHBORS} ${BGP_EVPN_NEIGHBORS}; do
      if ! bgp_neighbor_established "${neighbor}"; then
        all_established=0
        log "waiting BGP ${neighbor}... ${attempt}/${BGP_WAIT_RETRIES}"
      fi
    done

    if [ "${all_established}" -eq 1 ]; then
      log "BGP sessions ready"
      vtysh -c "show bgp ipv4 unicast summary" -c "show bgp l2vpn evpn summary" || true
      return 0
    fi

    sleep "${BGP_WAIT_INTERVAL}"
  done

  log "WARNING: some BGP sessions are not established yet"
  vtysh -c "show bgp ipv4 unicast summary" -c "show bgp l2vpn evpn summary" || true
  return 0
}


save_config_db() {
  # ConfigDB に投入した VLAN/VXLAN 設定を保存する。
  if [ "${SAVE_CONFIG_DB}" = "1" ]; then
    log "save ConfigDB"
    config save -y || true
  fi
}

show_final_state() {
  # 最後にインターフェース状態だけを軽く出して、起動ログで確認しやすくする。
  log "interface summary"
  ip -br link || true
  ip -br addr || true
}

main() {
  log "start"

  install_lab_packages
  setup_admin_user
  start_sshd
  ensure_mgmt_interface
  install_dummy_docker_command

  start_sonic_managers
  wait_for_sonic_managers

  apply_linux_config

  configure_frr_daemons
  restart_frr
  wait_for_vtysh
  apply_frr_config
  wait_for_bgp_sessions

  save_config_db
  ensure_mgmt_interface
  show_final_state

  log "done"
}

main "$@"

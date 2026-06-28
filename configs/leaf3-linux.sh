#!/usr/bin/env bash
set -u

# ============================================================
# Host-specific values
# ------------------------------------------------------------
# 別 leaf へ流用する場合は、このブロックを最小限変更する。
# NODE_NAME はログ用、VTEP_IP は leaf の Loopback0 / VTEP IP。
# ============================================================

NODE_NAME="leaf3"
UNDERLAY_IFS="Ethernet0 Ethernet4"
ACCESS_IF="Ethernet8"
LOOPBACK_IF="Loopback0"
VTEP_IP="10.255.0.3"
VLAN_ID="100"
VNI_ID="10100"
VTEP_NAME="vtep"
NVO_NAME="nvo"
BRIDGE_IF="Bridge"
VXLAN_IF="vxlan${VNI_ID}"

log() {
  echo "[${NODE_NAME}-linux] $*"
}

run_quiet() {
  # 冪等に再実行するため、既存設定エラーはログへ出さず無視する。
  "$@" >/dev/null 2>&1 || true
}

bring_up_interfaces() {
  # containerlab が接続した underlay / access port を有効化する。
  # UNDERLAY_IFS は spine1/spine2 向けの複数ポートを想定する。
  log "bring up interfaces"
  sleep 1
  for ifname in ${UNDERLAY_IFS}; do
    ip link set "${ifname}" up 2>/dev/null || true
    run_quiet config interface startup "${ifname}"
  done
  ip link set "${ACCESS_IF}" up || true
  run_quiet config interface startup "${ACCESS_IF}"
}


enable_forwarding() {
  # IPv4 unicast を IPv6 link-local underlay で運ぶため、IPv6 forwarding も明示する。
  log "enable IPv4/IPv6 forwarding"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
  for ifname in ${UNDERLAY_IFS}; do
    sysctl -w "net.ipv6.conf.${ifname}.forwarding=1" >/dev/null 2>&1 || true
  done
}

configure_loopback() {
  # BGP router-id / VTEP source として使う Loopback0 を用意する。
  log "configure ${LOOPBACK_IF}"
  run_quiet config loopback add "${LOOPBACK_IF}"
  run_quiet config interface ip add "${LOOPBACK_IF}" "${VTEP_IP}/32"

  # sonic-vs で config コマンドが実 Linux IF を作らない場合の補強。
  if ! ip link show "${LOOPBACK_IF}" >/dev/null 2>&1; then
    log "${LOOPBACK_IF} not found, create Linux dummy"
    ip link add "${LOOPBACK_IF}" type dummy || true
  fi

  ip link set "${LOOPBACK_IF}" up || true

  if ! ip addr show dev "${LOOPBACK_IF}" | grep -q "${VTEP_IP}/32"; then
    ip addr add "${VTEP_IP}/32" dev "${LOOPBACK_IF}" || true
  fi
}

configure_vlan_and_vxlan_configdb() {
  # SONiC ConfigDB に VLAN / VTEP / VNI mapping を投入する。
  log "configure VLAN${VLAN_ID} and VNI${VNI_ID}"
  run_quiet config vlan add "${VLAN_ID}"
  run_quiet config vlan member add -u "${VLAN_ID}" "${ACCESS_IF}"

  sleep 1
  run_quiet config vxlan add "${VTEP_NAME}" "${VTEP_IP}"
  sleep 1
  run_quiet config vxlan evpn_nvo add "${NVO_NAME}" "${VTEP_NAME}"
  sleep 1
  run_quiet config vxlan map add "${VTEP_NAME}" "${VLAN_ID}" "${VNI_ID}"
}

wait_for_app_db() {
  # vlanmgrd / vxlanmgrd が ConfigDB を処理した痕跡を少し待つ。
  log "wait VLAN/VXLAN in APP_DB"

  APP_DB_READY=0
  for i in $(seq 1 30); do
    if sonic-db-cli APPL_DB keys 'VLAN*' 2>/dev/null | grep -q . || \
       sonic-db-cli APPL_DB keys 'VXLAN*' 2>/dev/null | grep -q . || \
       sonic-db-cli APPL_DB keys 'TUNNEL*' 2>/dev/null | grep -q .; then
      log "APP_DB updated"
      sonic-db-cli APPL_DB keys 'VLAN*' || true
      sonic-db-cli APPL_DB keys 'VXLAN*' || true
      sonic-db-cli APPL_DB keys 'TUNNEL*' || true
      APP_DB_READY=1
      break
    fi

    log "waiting APP_DB VLAN/VXLAN... ${i}"
    sleep 2
  done

  if [ "${APP_DB_READY}" -ne 1 ]; then
    log "WARNING: APP_DB VLAN/VXLAN entries were not observed"
  fi
}


ensure_bridge() {
  # SONiC manager が Bridge/Vlan100 を作らない場合に備え、Linux 側で補強する。
  log "ensure ${BRIDGE_IF} and Vlan${VLAN_ID}"

  if ! ip link show "${BRIDGE_IF}" >/dev/null 2>&1; then
    ip link add name "${BRIDGE_IF}" type bridge vlan_filtering 1 || true
  fi
  ip link set "${BRIDGE_IF}" up || true

  if ! ip link show "Vlan${VLAN_ID}" >/dev/null 2>&1; then
    ip link add link "${BRIDGE_IF}" name "Vlan${VLAN_ID}" type vlan id "${VLAN_ID}" || true
  fi
  ip link set "Vlan${VLAN_ID}" up || true
  bridge vlan add dev "${BRIDGE_IF}" vid "${VLAN_ID}" self 2>/dev/null || true
}

ensure_vxlan_linux_fallback() {
  # sonic-vs 202605 では vxlanmgrd が ConfigDB を受けても、Linux の VXLAN IF を
  # 作れないことがある。一方で正常時は vtep-100 のような名前で作られるため、
  # 既存 VNI の IF を優先し、無ければ fallback 名で明示作成する。
  log "ensure VNI${VNI_ID} Linux VXLAN interface"

  for i in $(seq 1 30); do
    if ip link show "${BRIDGE_IF}" >/dev/null 2>&1; then
      EXISTING_VXLAN_IF="$(ip -d -o link show type vxlan 2>/dev/null | awk -v needle="id ${VNI_ID} " '$0 ~ needle { name=$2; sub(/:$/, "", name); print name; exit }')"
      if [ -n "${EXISTING_VXLAN_IF}" ]; then
        VXLAN_IF="${EXISTING_VXLAN_IF}"
      elif ! ip link show "${VXLAN_IF}" >/dev/null 2>&1; then
        ip link add "${VXLAN_IF}" type vxlan id "${VNI_ID}" local "${VTEP_IP}" dstport 4789 nolearning || true
      fi

      ip link set "${VXLAN_IF}" master "${BRIDGE_IF}" || true
      bridge vlan del dev "${VXLAN_IF}" vid 1 2>/dev/null || true
      bridge vlan del dev "${VXLAN_IF}" vid "${VLAN_ID}" 2>/dev/null || true
      bridge vlan add dev "${VXLAN_IF}" vid "${VLAN_ID}" pvid untagged || true
      ip link set "${VXLAN_IF}" up || true
      bridge link set dev "${VXLAN_IF}" learning off 2>/dev/null || true
      bridge link set dev "${VXLAN_IF}" neigh_suppress on 2>/dev/null || true
      return 0
    fi

    log "waiting ${BRIDGE_IF} before adding ${VXLAN_IF}... ${i}"
    sleep 2
  done

  log "WARNING: ${BRIDGE_IF} not found, skip VXLAN fallback"
}

ensure_access_port_bridge_vlan() {
  # sonic-vs では ACCESS_IF が Bridge/VLAN に自動収容されないことがあるため補強する。
  log "ensure ${ACCESS_IF} is in ${BRIDGE_IF} VLAN${VLAN_ID}"

  for i in $(seq 1 30); do
    if ip link show "${BRIDGE_IF}" >/dev/null 2>&1; then
      ip link set "${ACCESS_IF}" master "${BRIDGE_IF}" || true
      bridge vlan del dev "${ACCESS_IF}" vid 1 2>/dev/null || true
      bridge vlan add dev "${ACCESS_IF}" vid "${VLAN_ID}" pvid untagged || true
      ip link set "${ACCESS_IF}" up || true
      return 0
    fi

    log "waiting ${BRIDGE_IF} before adding ${ACCESS_IF}... ${i}"
    sleep 2
  done

  log "WARNING: ${BRIDGE_IF} not found, skip ${ACCESS_IF} VLAN membership"
}

show_state() {
  # 起動ログから最低限の状態を追えるようにする。
  log "check interfaces"
  ip -br link || true

  log "check bridge vlan"
  bridge vlan show || true

  log "check routes"
  ip route show "${VTEP_IP}/32" || true
}

main() {
  log "start"
  bring_up_interfaces
  enable_forwarding
  configure_loopback
  configure_vlan_and_vxlan_configdb
  wait_for_app_db
  ensure_bridge
  ensure_vxlan_linux_fallback
  ensure_access_port_bridge_vlan
  show_state
  log "done"
}

main "$@"

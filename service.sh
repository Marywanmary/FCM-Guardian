#!/system/bin/sh
# ============================================================
# FCM Guardian — service.sh
# 架构:
#   - inotifyd 双监听（文件 + 目录）→ 云控覆盖立即回写
#   - ip monitor route 主事件源 + 30s 差量 tick 兜底
#   - 30s tick 是「差量兜底」，不是死轮询；仅在 VALIDATED 计数变化时触发
# ============================================================

MODDIR=${0%/*}
GUARDIAN_DIR="/data/adb/fcm_guardian"
GSERVICES_DB="/data/data/com.google.android.gsf/databases/gservices.db"
GSF_DB_DIR="/data/data/com.google.android.gsf/databases"
LOG_FILE="/data/local/tmp/fcm_guardian.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service] $*" >> "$LOG_FILE"
}

log "===== FCM Guardian service 启动 ====="

# ============================================================
# 一、厂商省电开关关闭
# ============================================================
disable_vendor_power_save() {
    # 通用 Doze 参数：延后进入 idle，关闭 light doze 早触发
    # 注意：light_after_inactive_to 不要设 0（会立即进 light doze）
    settings put global device_idle_constants \
        "inactive_to=1800000,sensing_to=0,locating_to=0,idle_after_inactive_to=1800000,max_idle_to=3600000" 2>/dev/null

    # MIUI / HyperOS
    settings put secure miui_optimization 0 2>/dev/null
    settings put secure power_center_stop_background 0 2>/dev/null
    settings put global power_kill_policy 0 2>/dev/null

    # ColorOS / realme
    settings put global sleep_standby_optimization 0 2>/dev/null
    settings put secure super_power_save_keep_aod 1 2>/dev/null

    # Funtouch / OriginOS
    settings put global sleep_mode 0 2>/dev/null
    settings put global vivo_background_power_save 0 2>/dev/null

    # 华为 / 荣耀
    settings put global hw_power_genie_enable 0 2>/dev/null

    # 通用省电 / 流量节省
    settings put global low_power 0 2>/dev/null
    settings put global restrict_background_data 0 2>/dev/null
    settings put global data_saver_mode 0 2>/dev/null

    log "厂商省电开关已关闭"
}

# ============================================================
# 二、多用户 UID 获取
# ============================================================
get_active_users() {
    local_users=""
    for d in /data/system/users/*/; do
        u=$(basename "$d")
        case "$u" in ''|*[!0-9]*) continue ;; esac
        [ -d "/data/user/$u" ] || continue
        local_users="$local_users $u"
    done
    [ -z "$local_users" ] && local_users="0"
    echo "$local_users"
}

get_gms_uids_for_user() {
    user_id="$1"
    uids=""
    for pkg in com.google.android.gms \
               com.google.android.gsf \
               com.google.android.apps.gcs \
               com.google.android.gsf.login \
               com.google.android.syncadapters.contacts; do
        # grep 尾随空格，避免匹配 com.google.android.gms.setup 等衍生包
        uid=$(pm list packages --user "$user_id" -U 2>/dev/null | \
              grep "package:${pkg} " | awk '{print $2}' | sed 's/uid://')
        [ -n "$uid" ] && [ "$uid" -gt 0 ] 2>/dev/null && uids="$uids $uid"
    done
    echo "$uids" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# ============================================================
# 三、防火墙清理（iptables + ip6tables + nftables）
# ============================================================
clean_firewall_for_uid() {
    uid="$1"

    # iptables IPv4 — filter 表，逐条删除
    iptables -L OUTPUT -n --line-numbers 2>/dev/null | \
        grep -E "DROP|REJECT" | grep -w "$uid" | \
        awk '{print $1}' | sort -rn | \
        while read -r num; do iptables -D OUTPUT "$num" 2>/dev/null; done

    # iptables IPv4 — mangle 表
    iptables -t mangle -L OUTPUT -n --line-numbers 2>/dev/null | \
        grep -E "DROP|REJECT" | grep -w "$uid" | \
        awk '{print $1}' | sort -rn | \
        while read -r num; do iptables -t mangle -D OUTPUT "$num" 2>/dev/null; done

    # ip6tables IPv6
    ip6tables -L OUTPUT -n --line-numbers 2>/dev/null | \
        grep -E "DROP|REJECT" | grep -w "$uid" | \
        awk '{print $1}' | sort -rn | \
        while read -r num; do ip6tables -D OUTPUT "$num" 2>/dev/null; done

    # nftables (Android 14+)
    if command -v nft >/dev/null 2>&1; then
        for chain in output_output output; do
            nft -a list chain ip filter "$chain" 2>/dev/null | \
                grep -E "drop|reject" | grep "meta skuid $uid" | \
                grep -oE 'handle [0-9]+' | awk '{print $2}' | \
                while read -r handle; do
                    nft delete rule ip filter "$chain" handle "$handle" 2>/dev/null
                done
        done
    fi
}

# ============================================================
# 四、VALIDATED 事件处理
# ============================================================
handle_network_validated() {
    log "网络 VALIDATED — 清理防火墙并广播心跳"

    users=$(get_active_users)
    for user_id in $users; do
        uids=$(get_gms_uids_for_user "$user_id")
        for uid in $uids; do
            clean_firewall_for_uid "$uid"
        done
        log "User $user_id GMS UID 防火墙已清理: $uids"
    done

    # am broadcast --user all (AOSP 官方小写)
    am broadcast --user all \
        -a com.google.android.intent.action.MCS_HEARTBEAT \
        --receiver-permission com.google.android.c2dm.permission.RECEIVE \
        >/dev/null 2>&1

    am broadcast --user all \
        -a com.google.android.c2dm.intent.RECEIVE \
        --es heartbeat 1 \
        --receiver-permission com.google.android.c2dm.permission.RECEIVE \
        >/dev/null 2>&1

    "$GUARDIAN_DIR/inject_gservices.sh" &
}

# ============================================================
# 五、等待 boot_completed
# ============================================================
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done
log "boot_completed 已就绪"

disable_vendor_power_save
"$GUARDIAN_DIR/inject_gservices.sh"
log "二次 SQLite 注入完成"

# ============================================================
# 六、inotifyd 事件监听（零 sleep 重启）
# ============================================================
cat > "$GUARDIAN_DIR/on_db_changed.sh" << 'CALLBACK_EOF'
#!/system/bin/sh
# inotifyd 回调：$1=事件类型 $2=目录 $3=文件名
EVENT="$1"
FILE="$3"
LOG="/data/local/tmp/fcm_guardian.log"

case "$FILE" in
    *-wal|*-shm|*-journal) exit 0 ;;
esac

case "$EVENT" in
    w|m)
        echo "[$(date '+%F %T')] [inotify] event=$EVENT file=$FILE → 重新注入" >> "$LOG"
        /data/adb/fcm_guardian/inject_gservices.sh
        ;;
esac
CALLBACK_EOF

chmod 755 "$GUARDIAN_DIR/on_db_changed.sh"

# 纯事件驱动重启：inotifyd 前台阻塞，退出即重启（无 sleep）
(
    while true; do
        inotifyd "$GUARDIAN_DIR/on_db_changed.sh" \
            "${GSERVICES_DB}:wm" \
            "${GSF_DB_DIR}:wm"
    done
) &
log "inotifyd 双监听已启动"

# ============================================================
# 七、网络监听（路由事件主驱动 + 30s 差量兜底）
# ============================================================
(
    LAST_VALIDATED=""

    NET_FIFO="$GUARDIAN_DIR/net_events.fifo"
    rm -f "$NET_FIFO"; mkfifo "$NET_FIFO"

    # 主事件源：路由变化
    # ip monitor 若退出（内核不支持 / 被 kill）立即重启
    (
        while true; do
            ip monitor route 2>/dev/null | while read -r _; do
                echo "route" > "$NET_FIFO"
            done
        done
    ) &

    # 兜底源：30s tick（仅做 VALIDATED 计数差量）
    (
        while true; do
            sleep 30
            echo "tick" > "$NET_FIFO"
        done
    ) &

    # 统一消费
    while read -r event; do
        # 优先用 dumpsys --short（轻量），失败回退全量
        state=$(dumpsys connectivity --short 2>/dev/null | grep -c "VALIDATED")
        [ -z "$state" ] && state=0

        if [ "$state" != "$LAST_VALIDATED" ]; then
            if [ "$state" -gt 0 ]; then
                handle_network_validated
            fi
            LAST_VALIDATED="$state"
        fi
    done < "$NET_FIFO"
) &
log "网络监听器已启动（route 主驱动 + 30s tick 差量兜底）"

log "===== FCM Guardian service 初始化完成 ====="
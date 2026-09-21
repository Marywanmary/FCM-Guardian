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
log "===== FCM Guardian service 初始化完成 ====="

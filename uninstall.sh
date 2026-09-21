#!/system/bin/sh
# ============================================================
# FCM Guardian — uninstall.sh
# 卸载时清理运行期产生的数据
# ============================================================

# 清理持久化工作目录
rm -rf /data/adb/fcm_guardian

# 清理日志
rm -f /data/local/tmp/fcm_guardian.log

# 清理注入锁（防止残留导致下次安装后首次注入被锁）
rmdir /data/local/tmp/.gservices_inject_lock 2>/dev/null

# 恢复 settings 中被修改的项
settings delete global device_idle_constants 2>/dev/null
settings delete secure miui_optimization 2>/dev/null
settings delete secure power_center_stop_background 2>/dev/null
settings delete global power_kill_policy 2>/dev/null
settings delete global sleep_standby_optimization 2>/dev/null
settings delete global sleep_mode 2>/dev/null
settings delete global vivo_background_power_save 2>/dev/null
settings delete global hw_power_genie_enable 2>/dev/null

echo "FCM Guardian 已卸载，运行期数据已清理"

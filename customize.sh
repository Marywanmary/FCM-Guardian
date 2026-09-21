#!/system/bin/sh
# ============================================================
# FCM Guardian — customize.sh
# 安装时执行：校验环境、准备目录、提示用户
# ============================================================

SKIPMOUNT=false      # 是否需要挂载 system/ 目录（我们通过 post-fs-data 手动 bind mount，设为 false）
PROPFILE=false       # 是否使用 system.prop 文件
POSTFSDATA=true      # 是否启用 post-fs-data.sh
LATESTARTSERVICE=true # 是否启用 service.sh

ui_print "*******************************"
ui_print "  FCM Guardian v1.2.0"
ui_print "  GMS/FCM 事件驱动守护模块"
ui_print "*******************************"

# 检测 GMS 是否存在
if ! pm list packages 2>/dev/null | grep -q "com.google.android.gms"; then
    ui_print "! 警告：未检测到 GMS（com.google.android.gms）"
    ui_print "! 本模块专为装有 GMS 的设备设计"
    ui_print "! 继续安装，但功能可能无效"
fi

# 检测 sqlite3 可用性
if ! command -v sqlite3 >/dev/null 2>&1 && [ ! -x /data/adb/ksu/bin/sqlite3 ]; then
    ui_print "! 警告：未找到 sqlite3"
    ui_print "! 请安装含 sqlite3 的 BusyBox，或确认 KernelSU 已带 sqlite3"
fi

# 首次安装时准备持久化目录
mkdir -p /data/adb/fcm_guardian
chmod 755 /data/adb/fcm_guardian

ui_print "- 安装完成，重启后生效"
ui_print "- 日志：/data/local/tmp/fcm_guardian.log"

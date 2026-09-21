#!/system/bin/sh
# ============================================================
# FCM Guardian — post-fs-data.sh
# 阶段: post-fs-data (/data 已挂载，system 服务未起)
# 职责:
#   1. 部署持久化工作目录与注入脚本
#   2. 尝试首次 SQLite 注入（FBE 未解密时静默失败，service.sh 兜底）
#   3. bind mount sysconfig 白名单 XML
# ============================================================

MODDIR=${0%/*}
GUARDIAN_DIR="/data/adb/fcm_guardian"
GSERVICES_DB="/data/data/com.google.android.gsf/databases/gservices.db"
LOG_FILE="/data/local/tmp/fcm_guardian.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-fs-data] $*" >> "$LOG_FILE"
}

log "===== FCM Guardian post-fs-data 启动 ====="

mkdir -p "$GUARDIAN_DIR"
chmod 755 "$GUARDIAN_DIR"

# ---------- 部署注入脚本（post-fs-data 与 inotifyd 回调共用） ----------
cat > "$GUARDIAN_DIR/inject_gservices.sh" << 'INJECT_EOF'
#!/system/bin/sh
# SQLite 注入：main + overrides 双表；含 WAL 清理与权限修复
# 幂等，可被反复调用
DB="/data/data/com.google.android.gsf/databases/gservices.db"
LOCK="/data/local/tmp/.gservices_inject_lock"
LOG="/data/local/tmp/fcm_guardian.log"

if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 等待 DB 就绪（仅 post-fs-data 早期会有等待）
i=0
while [ ! -f "$DB" ] && [ "$i" -lt 30 ]; do
    sleep 1
    i=$((i+1))
done
[ -f "$DB" ] || { echo "[$(date '+%F %T')] [inject] DB 未就绪，跳过" >> "$LOG"; exit 1; }

# 定位 sqlite3
SQLITE3=$(command -v sqlite3 2>/dev/null)
[ -z "$SQLITE3" ] && SQLITE3="/data/adb/ksu/bin/sqlite3"
[ -x "$SQLITE3" ] || {
    SQLITE3=$(find /system/bin /system/xbin /vendor/bin -name sqlite3 2>/dev/null | head -1)
}
[ -n "$SQLITE3" ] || { echo "[$(date '+%F %T')] [inject] sqlite3 未找到" >> "$LOG"; exit 1; }

# 双表注入
"$SQLITE3" "$DB" << 'SQL'
INSERT OR REPLACE INTO main (name, value) VALUES
  ('mtalk.google.com:5228:heartbeat_ms_wifi',   '240000'),
  ('mtalk.google.com:5228:heartbeat_ms_mobile', '240000'),
  ('mtalk.google.com:5228:heartbeat_ms_other',  '240000'),
  ('mtalk.google.com:5228:heartbeat_ms',        '240000');

INSERT OR REPLACE INTO overrides (name, value) VALUES
  ('mtalk.google.com:5228:heartbeat_ms_wifi',   '240000'),
  ('mtalk.google.com:5228:heartbeat_ms_mobile', '240000'),
  ('mtalk.google.com:5228:heartbeat_ms_other',  '240000'),
  ('mtalk.google.com:5228:heartbeat_ms',        '240000');
SQL

# 强制 WAL 落盘，清理残留
"$SQLITE3" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null
rm -f "${DB}-wal" "${DB}-shm" 2>/dev/null

# 恢复属主与 mode
GSF_UID=$(stat -c '%u:%g' /data/data/com.google.android.gsf 2>/dev/null)
[ -n "$GSF_UID" ] && chown "$GSF_UID" "$DB" 2>/dev/null
chmod 600 "$DB" 2>/dev/null

echo "[$(date '+%F %T')] [inject] 注入完成 (main+overrides, wifi=240000 mobile=240000)" >> "$LOG"
INJECT_EOF

chmod 755 "$GUARDIAN_DIR/inject_gservices.sh"

# 首次注入（后台，不阻塞启动）
"$GUARDIAN_DIR/inject_gservices.sh" &

# ---------- bind mount sysconfig XML ----------
SYS_CONFIG_SRC="$MODDIR/system/etc/sysconfig/gms_proxy_whitelist.xml"
SYS_CONFIG_DST="/system/etc/sysconfig/gms_proxy_whitelist.xml"

if [ -f "$SYS_CONFIG_SRC" ]; then
    [ -d "/system/etc/sysconfig" ] || mkdir -p /system/etc/sysconfig 2>/dev/null
    if mount -o bind "$SYS_CONFIG_SRC" "$SYS_CONFIG_DST" 2>/dev/null; then
        log "sysconfig 白名单已 bind mount"
    else
        log "sysconfig bind mount 失败（检查 sepolicy sys_admin）"
    fi
fi

log "===== post-fs-data 完成 ====="

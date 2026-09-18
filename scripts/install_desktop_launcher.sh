#!/usr/bin/env bash

set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAUNCHER_PATH="${SCRIPT_DIR}/pcd2pgm_desktop_launcher.sh"

desktop_dir=""
if [[ -n "${PCD2PGM_DESKTOP_DIR:-}" ]]; then
  desktop_dir="${PCD2PGM_DESKTOP_DIR}"
elif command -v xdg-user-dir >/dev/null 2>&1; then
  desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null)"
fi

if [[ -z "${desktop_dir}" ]]; then
  desktop_dir="${HOME}/Desktop"
fi

if [[ ! -d "${desktop_dir}" ]]; then
  printf '桌面目录不存在：%s\n' "${desktop_dir}" >&2
  exit 1
fi

desktop_file="${desktop_dir}/pcd2pgm.desktop"
escaped_launcher="${LAUNCHER_PATH//\\/\\\\}"
escaped_launcher="${escaped_launcher//\"/\\\"}"

printf '%s\n' \
  '[Desktop Entry]' \
  'Type=Application' \
  'Version=1.0' \
  'Name=PCD 转栅格地图' \
  'Comment=选择 PCD 文件并启动 pcd2pgm 和 RViz' \
  "Exec=\"${escaped_launcher}\"" \
  'Icon=applications-engineering' \
  'Terminal=false' \
  'StartupNotify=true' \
  'Categories=Utility;' \
  >"${desktop_file}"

chmod +x "${LAUNCHER_PATH}" "${desktop_file}"

# GNOME 桌面会读取这个元数据；不支持桌面图标的环境可忽略该操作。
if command -v gio >/dev/null 2>&1; then
  gio set "${desktop_file}" metadata::trusted true >/dev/null 2>&1 || true
fi

printf '桌面启动器已创建：%s\n' "${desktop_file}"

#!/usr/bin/env bash

set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly PACKAGE_NAME="pcd2pgm"
readonly EXECUTABLE_PATH="${PROJECT_DIR}/install/${PACKAGE_NAME}/lib/${PACKAGE_NAME}/${PACKAGE_NAME}_node"
readonly PARAMS_FILE="${PROJECT_DIR}/install/${PACKAGE_NAME}/share/${PACKAGE_NAME}/config/${PACKAGE_NAME}.yaml"
readonly RVIZ_CONFIG_FILE="${PROJECT_DIR}/install/${PACKAGE_NAME}/share/${PACKAGE_NAME}/rviz/${PACKAGE_NAME}.rviz"
readonly BUILD_LOG="${PROJECT_DIR}/log/desktop_build.log"
readonly BUILD_STAMP="${PROJECT_DIR}/build/${PACKAGE_NAME}/.desktop_launcher_build_stamp"
readonly ROS_LOG_DIR_PATH="${PROJECT_DIR}/log/ros"

node_pid=""
rviz_pid=""

show_error()
{
  local message="$1"
  message="${message//\\n/$'\n'}"
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --no-markup --title="PCD 转栅格地图" --width=520 --text="${message}"
  else
    printf '错误：%s\n' "${message}" >&2
  fi
}

cleanup_processes()
{
  if [[ -n "${node_pid}" ]] && kill -0 "${node_pid}" 2>/dev/null; then
    kill -INT "${node_pid}" 2>/dev/null || true
    wait "${node_pid}" 2>/dev/null || true
  fi

  if [[ -n "${rviz_pid}" ]] && kill -0 "${rviz_pid}" 2>/dev/null; then
    kill -TERM "${rviz_pid}" 2>/dev/null || true
    wait "${rviz_pid}" 2>/dev/null || true
  fi
}

find_ros_setup()
{
  local candidate=""

  if [[ -n "${PCD2PGM_ROS_SETUP:-}" ]] && [[ -r "${PCD2PGM_ROS_SETUP}" ]]; then
    printf '%s\n' "${PCD2PGM_ROS_SETUP}"
    return 0
  fi

  for candidate in /opt/ros/humble/setup.bash /opt/ros/jazzy/setup.bash; do
    if [[ -r "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

sanitize_library_path()
{
  local entry=""
  local cleaned_path=""
  local -a entries=()

  IFS=':' read -r -a entries <<< "${LD_LIBRARY_PATH:-}"
  for entry in "${entries[@]}"; do
    # 海康 MVS 自带的旧版 libusb 会覆盖 PCL 依赖的系统 libusb。
    if [[ "${entry}" == "/opt/MVS/lib/64" ]] || [[ "${entry}" == "/opt/MVS/lib/32" ]]; then
      continue
    fi
    if [[ -n "${entry}" ]]; then
      cleaned_path="${cleaned_path:+${cleaned_path}:}${entry}"
    fi
  done

  export LD_LIBRARY_PATH="${cleaned_path}"
}

select_pcd_file()
{
  if ! command -v zenity >/dev/null 2>&1; then
    show_error "未找到 zenity，无法显示文件选择窗口。请先安装：sudo apt install zenity"
    return 1
  fi

  zenity \
    --file-selection \
    --title="选择 PCD 点云文件" \
    --file-filter="PCD 点云文件 | *.pcd *.PCD" \
    --file-filter="所有文件 | *"
}

sources_are_newer_than_executable()
{
  local path=""

  if [[ ! -x "${EXECUTABLE_PATH}" ]] || [[ ! -f "${BUILD_STAMP}" ]]; then
    return 0
  fi

  while IFS= read -r path; do
    if [[ "${path}" -nt "${BUILD_STAMP}" ]]; then
      return 0
    fi
  done < <(
    find \
      "${PROJECT_DIR}/src" \
      "${PROJECT_DIR}/include" \
      "${PROJECT_DIR}/launch" \
      "${PROJECT_DIR}/config" \
      "${PROJECT_DIR}/rviz" \
      -type f -print
    printf '%s\n' "${PROJECT_DIR}/CMakeLists.txt" "${PROJECT_DIR}/package.xml"
  )

  return 1
}

build_package()
{
  mkdir -p "${PROJECT_DIR}/log"

  (
    cd "${PROJECT_DIR}" || exit 1
    colcon build \
      --symlink-install \
      --packages-select "${PACKAGE_NAME}" \
      --cmake-args -DCMAKE_BUILD_TYPE=Release \
      >"${BUILD_LOG}" 2>&1
  ) &
  local build_pid=$!

  if command -v zenity >/dev/null 2>&1; then
    while kill -0 "${build_pid}" 2>/dev/null; do
      printf '# 正在编译 pcd2pgm，请稍候……\n'
      sleep 0.5
    done | zenity \
      --progress \
      --pulsate \
      --auto-close \
      --no-cancel \
      --title="PCD 转栅格地图" \
      --text="正在编译 pcd2pgm，请稍候……" \
      >/dev/null 2>&1 || true
  fi

  wait "${build_pid}"
  local build_status=$?
  if [[ ${build_status} -ne 0 ]]; then
    show_error "编译失败。\n\n构建日志：${BUILD_LOG}\n\n$(tail -n 12 "${BUILD_LOG}" 2>/dev/null)"
    return "${build_status}"
  fi

  touch "${BUILD_STAMP}"

  return 0
}

main()
{
  local pcd_file=""
  local ros_setup=""
  local node_log=""
  local rviz_log=""
  local first_status=0

  pcd_file="$(select_pcd_file)"
  local select_status=$?
  if [[ ${select_status} -ne 0 ]]; then
    return 0
  fi

  if [[ ! -f "${pcd_file}" ]] || [[ ! -r "${pcd_file}" ]]; then
    show_error "选择的 PCD 文件不存在或不可读：\n${pcd_file}"
    return 1
  fi

  mkdir -p "${ROS_LOG_DIR_PATH}"
  export ROS_LOG_DIR="${ROS_LOG_DIR_PATH}"

  ros_setup="$(find_ros_setup)"
  if [[ -z "${ros_setup}" ]]; then
    show_error "没有找到 ROS2 Humble 或 Jazzy 环境。请先安装 ROS2。"
    return 1
  fi

  sanitize_library_path

  # 桌面图标启动的进程不会自动加载终端中的 ROS2 环境。
  # shellcheck disable=SC1090
  set +o nounset
  source "${ros_setup}"
  local ros_source_status=$?
  set -o nounset
  if [[ ${ros_source_status} -ne 0 ]]; then
    show_error "ROS2 环境加载失败：\n${ros_setup}"
    return 1
  fi

  if ! command -v colcon >/dev/null 2>&1; then
    show_error "没有找到 colcon。请安装：sudo apt install python3-colcon-common-extensions"
    return 1
  fi

  if sources_are_newer_than_executable; then
    if ! build_package; then
      return 1
    fi
  fi

  if [[ ! -r "${PROJECT_DIR}/install/setup.bash" ]]; then
    show_error "编译完成后仍未找到 install/setup.bash，请查看：\n${BUILD_LOG}"
    return 1
  fi

  # shellcheck disable=SC1091
  set +o nounset
  source "${PROJECT_DIR}/install/setup.bash"
  local workspace_source_status=$?
  set -o nounset
  if [[ ${workspace_source_status} -ne 0 ]]; then
    show_error "工作空间环境加载失败：\n${PROJECT_DIR}/install/setup.bash"
    return 1
  fi

  if ! command -v rviz2 >/dev/null 2>&1; then
    show_error "没有找到 rviz2，请检查 ROS2 Desktop 是否安装完整。"
    return 1
  fi

  if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
    show_error "没有找到可执行程序：\n${EXECUTABLE_PATH}"
    return 1
  fi

  local run_stamp
  run_stamp="$(date +%Y%m%d_%H%M%S)"
  node_log="${PROJECT_DIR}/log/desktop_node_${run_stamp}.log"
  rviz_log="${PROJECT_DIR}/log/desktop_rviz_${run_stamp}.log"

  "${EXECUTABLE_PATH}" \
    --ros-args \
    --params-file "${PARAMS_FILE}" \
    -p "pcd_file:=${pcd_file}" \
    >"${node_log}" 2>&1 &
  node_pid=$!

  sleep 0.8
  if ! kill -0 "${node_pid}" 2>/dev/null; then
    wait "${node_pid}" 2>/dev/null || true
    show_error "节点启动失败。\n\n运行日志：${node_log}\n\n$(tail -n 12 "${node_log}" 2>/dev/null)"
    node_pid=""
    return 1
  fi

  rviz2 -d "${RVIZ_CONFIG_FILE}" >"${rviz_log}" 2>&1 &
  rviz_pid=$!

  # 用户关闭 RViz 时同步结束节点；节点异常退出时也关闭 RViz。
  wait -n "${node_pid}" "${rviz_pid}" || first_status=$?

  if kill -0 "${node_pid}" 2>/dev/null; then
    kill -INT "${node_pid}" 2>/dev/null || true
    wait "${node_pid}" 2>/dev/null || true
    node_pid=""
    rviz_pid=""
    return 0
  fi

  node_pid=""
  if kill -0 "${rviz_pid}" 2>/dev/null; then
    kill -TERM "${rviz_pid}" 2>/dev/null || true
    wait "${rviz_pid}" 2>/dev/null || true
  fi
  rviz_pid=""

  if [[ ${first_status} -ne 0 ]]; then
    show_error "节点运行异常。\n\n运行日志：${node_log}\n\n$(tail -n 12 "${node_log}" 2>/dev/null)"
    return "${first_status}"
  fi

  return 0
}

trap cleanup_processes EXIT INT TERM
main "$@"

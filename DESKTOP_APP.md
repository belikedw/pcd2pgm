# 桌面版使用方法

这个启动器用于 Ubuntu 桌面环境。双击图标后会执行以下操作：

1. 弹出窗口选择 `.pcd` 文件。
2. 检查 ROS2 环境和编译结果。
3. 仅在第一次运行或源码发生变化时执行 `colcon build`。
4. 启动 `pcd2pgm_node` 和 RViz。
5. 关闭 RViz 时同步结束 ROS2 节点。

首次创建桌面图标：

```bash
cd /path/to/pcd2pgm
./scripts/install_desktop_launcher.sh
```

节点和 RViz 的运行日志保存在项目的 `log` 目录。编译失败时查看：

```text
log/desktop_build.log
```

默认依次查找 ROS2 Humble 和 Jazzy。如果 ROS2 安装在其他位置，可以在启动器中通过
`PCD2PGM_ROS_SETUP` 环境变量指定对应的 `setup.bash`。

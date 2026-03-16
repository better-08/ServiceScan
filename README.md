# ServiceScan (主机服务发现) 🚀

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-linux-lightgrey.svg)](https://www.linux.org/)
[![Shell](https://img.shields.io/badge/shell-sh-brightgreen.svg)](https://en.wikipedia.org/wiki/Shell_script)

一个轻量级、零依赖的 Linux 资产扫描与服务识别脚本。旨在“一键式”自动化获取宿主机、容器及 K8s 集群中的中间件、数据库及应用服务的详细版本信息。
便于结合作业平台进行批量扫描。
---

## ✨ 核心特性

- 🛠 **零配置运行**：无需安装 Python、Go 或其他运行环境，仅需基础 `sh` 即可运行。
- 🔍 **多维探测**：
  - **宿主机级**：深度扫描进程、端口监听、二进制版本号。
  - **容器级**：支持 Docker, Podman, nerdctl, CRICTL。
  - **K8s 级**：集成 `kubectl` 探测，支持命名空间级别的服务识别。
- 🧪 **深度提取 (Deep Scan)**：不仅仅看镜像名，还会尝试 `exec` 进入容器内部或调用二进制文件 `-v` 获取精准版本。
- 🛡 **智能提权**：自动检测 `root` 权限，支持 `sudo` 自动重运行。
- 📊 **标准输出**：提供易于解析的制表符（Tab）分隔格式，方便后续集成到 CMDB 或审计系统。

---

## 📦 支持识别的服务

脚本预置了大量主流中间件的识别逻辑，包括但不限于：

- **Web 服务器**：Nginx, Apache (httpd), OpenResty, Tomcat, WebLogic, JBoss/WildFly.
- **数据库**：MySQL, MariaDB, PostgreSQL, MongoDB, ClickHouse, Oracle.
- **缓存与消息**：Redis, Kafka, Zookeeper, RabbitMQ, Etcd, Consul.
- **其他**：Elasticsearch, Java/Go/Node 运行时, SSH, VNC, Postfix 等。

---

## 🚀 快速开始

### 方式一：直接运行 (推荐)
直接通过 curl 远程执行（适用于快速巡检）：
```bash
curl -sSL https://raw.githubusercontent.com/你的用户名/仓库名/main/service_scan.sh | sudo sh
```

### 方式二：本地下载运行
```bash
git clone https://github.com/你的用户名/仓库名.git
cd 仓库名
chmod +x service_scan.sh
sudo ./service_scan.sh
```

---

## 📋 输出示例

执行后，脚本将以 `name  version  method  detail` 的格式输出结果：

| name | version | method | detail |
| :--- | :--- | :--- | :--- |
| nginx | 1.21.6 | bin | /usr/sbin/nginx\|pid=1234 |
| mysql | 8.0.28 | container:image | docker name=db_mysql image=mysql:8.0.28 |
| redis | 6.2.6 | k8s:exec | kubectl ns=default pod=redis-master-0 |
| java | 1.8.0_312 | bin | /usr/bin/java\|pid=5678 |

---

## 🛠 原理说明

1. **权限探测**：首先检查当前用户，尝试自动通过 `sudo` 提升权限以访问 `/proc` 和容器套接字。
2. **进程扫描**：遍历 `/proc` 下的进程，识别二进制文件路径及监听端口。
3. **版本溯源**：
   - 针对已知软件，使用预定义的正则提取命令（如 `nginx -v`）。
   - 针对未知软件，尝试通用版本标志（`--version`, `-V` 等）。
4. **容器/K8s 穿透**：通过容器运行时的 API 或命令，解析镜像 Tag，或动态进入容器内部执行版本查询。

---

## 🤝 贡献与反馈

欢迎提交 Issue 或 Pull Request 来增加对更多中间件的支持！
- 如果你发现某个服务版本识别不准，请提供该服务的 `process name` 和其版本查询命令。

---

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 协议。

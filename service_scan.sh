#!/usr/bin/env sh
#set -eu

# ---------- 默认配置（无需外部预输入） ----------
# 为了满足“无需任何预输入”的要求，我们把常用选项设置为默认启用
SCAN_HOST=1
SCAN_CONTAINER=1
SCAN_K8S=1
CONTAINER_DEEP=1
K8S_DEEP=1
TIMEOUT_S=3

# ---------- 工具函数 ----------
have() { command -v "$1" >/dev/null 2>&1; }
try_timeout() {
  if have timeout; then timeout -s KILL "$TIMEOUT_S" "$@"; else "$@"; fi
}
emit() { # name, version, method, detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}
tolower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
trimnumver() {  # 支持 v/V 前缀标签，如 v3.13.4 -> 3.13.4
  printf '%s' "$1" | sed -nE 's/^[vV]?([0-9][0-9.]*).*/\1/p'
}

# ---------- 自动提权（如需要且可用） ----------
if [ "$(id -u)" != "0" ]; then
  if have sudo; then
    # 如果有 sudo 并且可以无密码提权，尝试再次以 root 运行
    if sudo -n true 2>/dev/null; then
      exec sudo -E sh "$0" "$@"
    else
      echo "WARN: 当前非 root 且 sudo 需要密码，脚本将继续以当前用户运行（探测能力会受限）。" >&2
    fi
  else
    echo "WARN: 当前非 root 并且系统没有 sudo，脚本将继续以当前用户运行（探测能力会受限）。" >&2
  fi
fi

# ---------- 头部信息 ----------
HOST="$(hostname 2>/dev/null || uname -n)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
KERN="$(uname -s 2>/dev/null || echo unknown)"
OSVER=$(
  if [ -f /etc/os-release ]; then
    . /etc/os-release 2>/dev/null || true
    printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}"
  elif have lsb_release; then
    lsb_release -ds 2>/dev/null || uname -r
  else
    uname -r
  fi
)
TS="$(date -u +%FT%TZ 2>/dev/null || date)"

#echo "# host=$HOST os=$KERN $OSVER arch=$ARCH ts=$TS"
#echo "name\tversion\tmethod\tdetail"
printf '%s\t%s\t%s\t%s\n' "name" "version" "method" "detail"

# ---------- 宿主机探测（改造版） ----------
binary_from_pid() {
  local pid="$1"
  local exe=""

  # /proc/<pid>/exe 存在并且是链接
  if [[ -L "/proc/$pid/exe" ]]; then
      exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)

      # 如果路径里包含 (deleted)，说明文件已被删除
      if printf '%s' "$exe" | grep -q '(deleted)'; then
          return 1
      fi

      # 检查路径是否真实存在且可执行
      if [[ -n "$exe" && -x "$exe" && -e "$exe" ]]; then
          echo "$exe"
          return 0
      else
          # 文件已不存在或无执行权限 → 视为无效
          return 1
      fi
  fi

  return 1
}

: <<'EOF'
get_bin_from_pid() {
  local pname=$1
  # 1. ss 精确匹配
  if have ss; then
    ss -tulnp 2>/dev/null \
      | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' \
      | grep -E "\"$pname\"" \
      | sed -nE 's/.*pid=([0-9]+)/\1/p' \
      | while read -r pid; do
          [ -L "/proc/$pid/exe" ] && printf '%s|%s\n' "$(readlink -f "/proc/$pid/exe")" "$pid"
        done
    return 0
  fi
  # 2. 回退 pgrep
  pgrep -x "$pname" 2>/dev/null \
    | while read -r pid; do
        [ -L "/proc/$pid/exe" ] && printf '%s|%s\n' "$(readlink -f "/proc/$pid/exe")" "$pid"
      done
}
EOF

guess_ver_fallback() {
  local bin=$1
  local flags="-v --v -V --V --version -version"
  for f in $flags; do
    # 用 timeout 防止卡死，同时捕获 stdout 和 stderr
    local out ver
    out=$(try_timeout "$bin" $f 2>&1 || true)

    # 如果 try_timeout 没输出，再直接手动执行一次（防止 try_timeout 吃掉输出）
    if [ -z "$out" ]; then
      out=$("$bin" $f 2>&1 || true)
    fi

    # 提取形如 1.2 / 3.4.5 之类的版本号（允许带 rc/beta/suffix）
    #ver=$(printf '%s\n' "$out" | sed -nE 's/.*[^0-9]([0-9]+(\.[0-9]+)+([a-zA-Z0-9._-]*)?).*/\1/p' | head -1)
    #ver=$(printf '%s\n' "$out" | sed -nE 's/.*version[[:space:]]*[:=]?[[:space:]]*([0-9]+(\.[0-9]+)+).*/\1/ip' | head -1)
    ver=$(printf '%s\n' "$out" \
      | sed -nE 's/.*[Vv]ersion[[:space:]]*[:=]?[[:space:]]*v?([0-9]+(\.[0-9]+)*([.-][a-zA-Z0-9]+)*).*/\1/p' \
      | head -1)
    # 兜底
    [ -z "$ver" ] && ver=$(printf '%s\n' "$out" | sed -nE 's/^[[:space:]]*v?([0-9]+(\.[0-9]+)*([.-][a-zA-Z0-9]+)*)[[:space:]]*$/\1/p' | head -1)  
    [ -z "$ver" ] && ver=$(printf '%s\n' "$out" | sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)*([.-][a-zA-Z0-9]+)*).*/\1/p' | head -1)
    # 一旦取到版本立即返回
    if [ -n "$ver" ]; then
      printf '%s' "$ver"
      return 0
    fi
  done

  # 所有尝试都失败
  return 1
}


get_ver_from_bin() {
  local bin="$1"
  case "$(basename "$bin")" in
    nginx|openresty)
      "$bin" -v 2>&1 | sed -n 's/^.*version: .*\/\([0-9.]*\).*/\1/p'
      ;;
    httpd|apache2)
      "$bin" -v 2>/dev/null | sed -n 's/^Server version: Apache\/\([0-9.]*\).*/\1/p'
      ;;
    mysqld)
      "$bin" --version 2>&1 | sed -n 's/.*Ver \([0-9.]*\).*/\1/p'
      ;;
    mysql)
      out="$("$bin" --version 2>&1 || true)"
      if printf '%s' "$out" | grep -qi mariadb; then
        printf '%s' "$out" | sed -n 's/.*Distrib \([0-9.]*\)-MariaDB.*/\1/p'
      else
        printf '%s' "$out" | sed -n 's/.*Distrib \([0-9.]*\).*/\1/p'
      fi
      ;;
    #psql|postgres)
    #  "$bin" --version 2>/dev/null | awk '{print $3}'
    #  ;;
    redis-server)
      "$bin" --version 2>/dev/null | sed -n 's/.*v=\([0-9.]*\).*/\1/p'
      ;;
    mongod)
      "$bin" --version 2>/dev/null | sed -n 's/^db version v\([0-9.]*\).*/\1/p'
      ;;
    haproxy)
      "$bin" -v 2>&1 | sed -n 's/^HA-Proxy version \([0-9.]*\).*/\1/p'
      ;;
    etcd)
      "$bin" --version 2>&1 | sed -n 's/^etcd Version: \([0-9.]*\).*/\1/p'
      ;;
    consul)
      "$bin" version 2>&1 | sed -n 's/^Consul v\([0-9.]*\).*/\1/p'
      ;;
    clickhouse-server)
      "$bin" --version 2>&1 | sed -n 's/^ClickHouse server version \([0-9.]\+\).*/\1/p'
      ;;
    ssh|ssh-client|sshd)
      # ssh -V 输出到 stderr
      "$bin" -V 2>&1 | sed -nE 's/.*OpenSSH_([0-9][0-9.a-zA-Zp_-]*).*/\1/p'
      ;;
    java)
      "$bin" -version 2>&1 | awk -F '"' '/version/ {print $2}'
      ;;
    node)
      "$bin" -v 2>&1 | sed -n 's/^v\([0-9.]*\).*/\1/p'
      ;;
    go|golang)
      "$bin" version 2>&1 | awk '{print $3}' | sed 's/go//'
      ;;
    *docker*|containerd)
      "$bin" --version 2>&1 | sed -n 's/.*version \([0-9.]*\).*/\1/p'
      ;;
    *kube*|kubectl)
      "$bin" version --client --short 2>/dev/null | awk '{print $3}' | sed 's/^v//'
      ;;
    Xvnc|xvnc)
      "$bin" -version 2>&1 | sed -nE 's/.*TigerVNC[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p'
      ;;
    oracle)
      # 从 Oracle 二进制路径解析版本号，例如：
      # /u01/app/oracle/product/11.2.0/db_home1/bin/oracle -> 11.2.0
      if [[ "$bin" =~ /product/([0-9]+\.[0-9]+\.[0-9]+)/ ]]; then
        echo "${BASH_REMATCH[1]}"
      else
        echo "unknown"
      fi
      ;;
    postfix|master)
      # 使用 postconf 查询 Postfix 版本
      postconf mail_version 2>/dev/null | awk '{print $3}'
      ;;
    psql|postgres|tbase_pgxz|tbase_pg)
        local ver libdir tbase_ver pg_ver

        # 计算 lib 目录
        libdir="$(dirname "$bin" | sed 's|/bin$|/lib|')"

        # 尝试执行 --version
        if [ -d "$libdir" ]; then
            ver=$(LD_LIBRARY_PATH="$libdir" "$bin" --version 2>&1 | head -1)
        else
            ver=$("$bin" --version 2>&1 | head -1)
        fi

        # 从路径解析 Tbase 版本
        if [[ "$bin" =~ /([0-9]+(\.[0-9]+)+)/ ]]; then
            tbase_ver="Tbase_v${BASH_REMATCH[1]}"
        else
            tbase_ver="Tbase_unknown"
        fi

        # 提取 PostgreSQL 版本号
        if printf '%s' "$ver" | grep -qi 'PostgreSQL'; then
            pg_ver=$(printf '%s\n' "$ver" | awk '{print $3}')
        elif printf '%s' "$ver" | grep -qi 'T[bB]ase'; then
            pg_ver=$(printf '%s\n' "$ver" | awk -F'[(]' '{print $2}' | awk '{print $1}')
        else
            pg_ver="unknown"
        fi

        # 返回格式：PG版本 @ Tbase版本
        echo "${pg_ver}@${tbase_ver}"
    ;;

    *)
      # 默认走 guess_ver_fallback 来尝试获取版本
      guess_ver_fallback "$bin"
      ;;
  esac
}


if [ "$SCAN_HOST" = "1" ]; then
  get_bin_from_pid_safe() {
    local pname=$1 ss_out rc

    if have ss; then
      ss_out=$(try_timeout ss -tulnp 2>&1)
      rc=$?
      [ $rc -ne 0 ] && ss_out=''

      if ! printf '%s\n' "$ss_out" | head -1 | grep -qF 'Usage:'; then
        # 使用 ss 输出获取 PID + exe + 端口
        printf '%s\n' "$ss_out" \
          | grep -oE ".*users:\(\(\"$pname\",pid=[0-9]+" \
          | sed -nE 's/.*pid=([0-9]+)/\1/p' \
          | while read -r pid; do
              exe=$(binary_from_pid "$pid" 2>/dev/null || true)
              [ -z "$exe" ] && continue

              # 获取该 PID 所有监听的地址:端口
              ports=$(printf '%s\n' "$ss_out" \
                | grep -E "pid=$pid" \
                | awk '{print $5}' \
                | while read -r addr; do
                    # IPv6 [::1]:port
                    if [[ "$addr" =~ \[.*\]:[0-9]+ ]]; then
                      a=$(echo "$addr" | sed -E 's/\[([0-9a-fA-F:]+)\]:[0-9]+/[\1]/')
                      p=$(echo "$addr" | sed -E 's/.*:([0-9]+)$/\1/')
                      printf '%s:%s,' "$a" "$p"
                    else
                      host=$(echo "$addr" | awk -F: '{print $1}')
                      port=$(echo "$addr" | awk -F: '{print $NF}')
                      printf '%s:%s,' "$host" "$port"
                    fi
                  done \
                | sed 's/,$//')  # 去掉最后的逗号

              printf '%s|%s|ports=%s\n' "$exe" "$pid" "$ports"
            done
        return 0
      fi
    fi

    # 回退到 pgrep，只输出 exe|pid
    pgrep -x "$pname" 2>/dev/null \
      | while read -r pid; do
          exe=$(binary_from_pid "$pid" 2>/dev/null || true)
          [ -n "$exe" ] && printf '%s|%s\n' "$exe" "$pid"
        done
  }


  # ---------- 下方保持原名的“壳函数”，避免上层调用改动 ----------
  get_bin_from_pid() {
    get_bin_from_pid_safe "$@"
  }

  detect_host_cmds() {
    # 1. 取进程名（加超时，防止 ps 本身异常）
    try_timeout ps -eo comm= 2>/dev/null | sort -u | while read -r pname; do
      # 跳过内核线程和常见无害进程
      case "$pname" in
        [kK]*|systemd|bash|sh|ps|awk|sed|grep) continue ;;
      esac

      # 2. 获取 pid -> exe 映射（防 ss/netlink 阻塞 + readlink 内核 race）
      get_bin_from_pid_safe "$pname" | while IFS='|' read -r exe pid; do
        [ -z "$exe" ] && continue

        # 3. 取版本（白名单 -> 暴力回退）
        ver=$(get_ver_from_bin "$exe")
        [ -z "$ver" ] && ver=$(guess_ver_fallback "$exe")

        emit "$pname" "${ver:-}" "bin" "$exe${pid:+|pid=$pid}"
      done
    done

    # Elasticsearch
    if have curl; then
      es_json="$(curl -fsS --max-time 1 http://127.0.0.1:9200 2>/dev/null || true)"
      es_ver="$(printf '%s' "$es_json" | sed -n 's/.*"number":"\([^\"]*\)".*/\1/p')"
      [ -n "$es_ver" ] && emit "elasticsearch" "$es_ver" "http" "http://127.0.0.1:9200"
    fi
    if [ -z "${es_ver:-}" ] && have elasticsearch; then
      bin="$(get_bin_from_pid elasticsearch)"
      if [ -n "$bin" ]; then
        ver="$(get_ver_from_bin "$bin")"
        [ -n "$ver" ] && emit "elasticsearch" "$ver" "bin" "$bin"
      fi
    fi

    # Kafka
    detect_kafka() {
      if have kafka-run-class.sh; then
        KH="$(dirname "$(command -v kafka-run-class.sh)")/.."
      elif have kafka-server-start.sh; then
        KH="$(dirname "$(command -v kafka-server-start.sh)")/.."
      else
        KH=""
      fi
      if [ -n "$KH" ] && [ -d "$KH/libs" ]; then
        ver="$(ls -1 "$KH"/libs/kafka_*-[0-9]*.jar 2>/dev/null | sed -n 's/.*kafka_.*-\([0-9][0-9.]*\)\.jar/\1/p' | head -1)"
        [ -n "$ver" ] && emit "kafka" "$ver" "jar" "$KH"
      fi
    }
    detect_kafka

    # Zookeeper
    if have zkServer.sh; then
      ver="$(zkServer.sh version 2>/dev/null | sed -n 's/.*Version: \([0-9.]*\).*/\1/p')"
      [ -n "$ver" ] && emit "zookeeper" "$ver" "cmd" "$(command -v zkServer.sh)"
    fi

    # RabbitMQ
    if have rabbitmq-diagnostics; then
      ver="$(rabbitmq-diagnostics server_version -q 2>/dev/null || true)"
      [ -n "$ver" ] && emit "rabbitmq" "$ver" "cmd" "$(command -v rabbitmq-diagnostics)"
    elif have rabbitmqctl; then
      ver="$(rabbitmqctl status 2>/dev/null | sed -n 's/.*{rabbit,\"RabbitMQ\",\"\([0-9.]*\)\".*/\1/p')"
      [ -n "$ver" ] && emit "rabbitmq" "$ver" "cmd" "$(command -v rabbitmqctl)"
    fi

    # Tomcat
    detect_tomcat() {
      ver_sh=""
      if [ -n "${CATALINA_HOME:-}" ] && [ -x "$CATALINA_HOME/bin/version.sh" ]; then
        ver_sh="$CATALINA_HOME/bin/version.sh"
      else
        pid="$(ps -eo pid,comm,args | grep -E 'java .*org\.apache\.catalina\.startup\.Bootstrap' | grep -v grep | awk '{print $1}' | head -1 || true)"
        if [ -n "$pid" ]; then
          base="$(ps -p "$pid" -o args= | sed -n 's/.*-Dcatalina.home=\([^ ]*\).*/\1/p')"
          [ -z "$base" ] && base="$(ps -p "$pid" -o args= | sed -n 's/.*-Dcatalina.base=\([^ ]*\).*/\1/p')"
          if [ -n "$base" ] && [ -x "$base/bin/version.sh" ]; then
            ver_sh="$base/bin/version.sh"
          fi
        fi
      fi
      if [ -n "$ver_sh" ]; then
        ver="$("$ver_sh" 2>/dev/null | sed -n 's/^Server version: Apache Tomcat\/\([0-9.]*\).*/\1/p' | head -1)"
        [ -n "$ver" ] && emit "tomcat" "$ver" "script" "$ver_sh"
      fi
    }
    detect_tomcat

    # WebLogic
    detect_weblogic() {
      local ver_cmd="" pid="" domain_home="" ver=""

      # 1) 优先使用环境变量 DOMAIN_HOME
      if [ -n "${DOMAIN_HOME:-}" ] && [ -x "$DOMAIN_HOME/bin/setDomainEnv.sh" ]; then
        ver_cmd="$DOMAIN_HOME/bin/setDomainEnv.sh"
      else
        # 2) 从正在运行的 WebLogic 进程中查找线索
        pid="$(ps -eo pid,comm,args | grep -E 'weblogic\.Server' | grep -v grep | awk '{print $1}' | head -1 || true)"
        if [ -n "$pid" ]; then
          # 3) 从进程启动参数中提取 DOMAIN_HOME（有时也叫 -Dweblogic.Domain）
          domain_home="$(ps -p "$pid" -o args= | sed -n 's/.*-Dweblogic.Domain=\([^ ]*\).*/\1/p')"
          [ -z "$domain_home" ] && domain_home="$(ps -p "$pid" -o args= | sed -n 's/.*-Dweblogic\.home=\([^ ]*\).*/\1/p')"
          [ -z "$domain_home" ] && domain_home="$(ps -p "$pid" -o args= | sed -n 's/.*-Dweblogic\.DomainHome=\([^ ]*\).*/\1/p')"

          # 4) 如果找到 domain_home，就尝试常见版本文件
          if [ -n "$domain_home" ]; then
            # WebLogic 通常会在安装目录或 registry.xml 里包含版本信息
            if [ -f "$domain_home/registry.xml" ]; then
              ver="$(grep -Eo '([0-9]{2}\.[0-9.]+)' "$domain_home/registry.xml" | head -1)"
            elif [ -f "$domain_home/weblogic.version" ]; then
              ver="$(grep -Eo '([0-9]{2}\.[0-9.]+)' "$domain_home/weblogic.version" | head -1)"
            fi
          fi
        fi
      fi

      # 5) 如果前面都没找到版本，尝试调用 weblogic.jar 自带信息
      if [ -z "$ver" ]; then
        wl_jar="$(find / -type f -name weblogic.jar 2>/dev/null | head -1 || true)"
        if [ -n "$wl_jar" ]; then
          ver="$(java -cp "$wl_jar" weblogic.version 2>/dev/null | grep -Eo 'WebLogic Server [0-9.]+' | head -1 | grep -Eo '[0-9.]+')"
        fi
      fi

      # 6) 输出检测结果
      [ -n "$ver" ] && emit "weblogic" "$ver" "java" "${ver_cmd:-$domain_home}"
    }
    detect_weblogic

    # JBoss / WildFly 版本检测
    detect_jboss() {
      local pid="" jboss_home="" ver=""

      # 1. 匹配运行中的 JBoss/WildFly 进程
      pid="$(ps -eo pid,comm,args | grep -E 'org\.jboss\.|org\.wildfly\.|jboss-modules\.jar' | grep -v grep | awk '{print $1}' | head -1 || true)"

      if [ -n "$pid" ]; then
        # 2. 从进程中提取 -Djboss.home.dir
        jboss_home="$(ps -p "$pid" -o args= | sed -n 's/.*-Djboss\.home\.dir=\([^ ]*\).*/\1/p')"

        # 3. 如果没找到，从常见路径猜测
        [ -z "$jboss_home" ] && jboss_home="$(find /opt /u01 /usr/local /data /home -type d \( -name 'jboss*' -o -name 'wildfly*' \) 2>/dev/null | head -1 || true)"

        # 4. 从文件中提取版本号
        if [ -n "$jboss_home" ]; then
          for vf in \
            "$jboss_home/version.txt" \
            "$jboss_home/docs/README.txt" \
            "$jboss_home/docs/licenses/README.txt" \
            "$jboss_home/bin/product.conf"; do
            if [ -f "$vf" ]; then
              ver="$(grep -Eo '([0-9]+\.[0-9]+(\.[0-9]+)?\.?(Final|GA)?)' "$vf" | head -1)"
              [ -n "$ver" ] && break
            fi
          done

          # 5. 如果还没有，就从日志提取 WildFly Full 版本
          if [ -z "$ver" ]; then
            ver="$(grep -Eo 'WildFly Full [0-9]+\.[0-9]+\.[0-9]+\.?Final?' "$jboss_home/standalone/log/server.log" 2>/dev/null | head -1 | awk '{print $3}')"
          fi
        fi

        # 6. 输出结果
        [ -n "$ver" ] && emit "jboss" "$ver" "java" "$jboss_home"
      fi
    }
    detect_jboss
  }

: <<'EOF'
  detect_host_pkgs() {
    if have rpm; then
      rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null | \
      grep -Ei 'mysql|mariadb|postgres|redis|mongodb|nginx|httpd|apache|tomcat|zookeeper|kafka|elasticsearch|rabbitmq|clickhouse|haproxy|openresty|etcd|consul' | \
      while IFS="$(printf '\t')" read -r pkg ver; do emit "$pkg" "$ver" "rpm" ""; done
    fi
    if have dpkg-query; then
      dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | \
      grep -Ei 'mysql|mariadb|postgres|redis|mongodb|nginx|apache2|tomcat|zookeeper|kafka|elasticsearch|rabbitmq|clickhouse|haproxy|openresty|etcd|consul' | \
      while IFS="$(printf '\t')" read -r pkg ver; do emit "$pkg" "$ver" "dpkg" ""; done
    fi
  }
EOF
  detect_host_cmds
  #detect_host_pkgs
fi

# ---------- 镜像猜测工具（容器） ----------
guess_from_image() {
  img="$1"
  base="$(printf '%s' "$img" | sed -E 's/@sha256:[a-f0-9]+$//; s/:[^:@]+$//; s|.*/||')"
  tag="$(printf '%s' "$img" | sed -nE 's#.*/[^:/@]+:([^:@]+)$#\1#p')"
  [ -z "$tag" ] && tag="latest"
  lc="$(tolower "$base")"
  name=""
  case "$lc" in
    *openresty*) name="openresty" ;;
    *nginx*) name="nginx" ;;
    *httpd*|*apache*) name="apache-httpd" ;;
    *mariadb*) name="mariadb" ;;
    *mysql*) name="mysql" ;;
    *postgres*|*postgis*) name="postgresql" ;;
    *redis*) name="redis" ;;
    *mongo*) name="mongodb" ;;
    *elasticsearch*) name="elasticsearch" ;;
    *kibana*) name="kibana" ;;
    *kafka*) name="kafka" ;;
    *zookeeper*) name="zookeeper" ;;
    *rabbitmq*) name="rabbitmq" ;;
    *clickhouse*) name="clickhouse" ;;
    *haproxy*) name="haproxy" ;;
    *etcd*) name="etcd" ;;
    *consul*) name="consul" ;;
    *tomcat*) name="tomcat" ;;
    *nacos*) name="nacos" ;;
  esac
  ver="$(trimnumver "$tag")"
  printf '%s\t%s\t%s\t%s\n' "$name" "$ver" "$base" "$tag"
}

inspect_env_label_version() {
  rt="$1"; cid="$2"; cname="$3"
  ver=""
  case "$cname" in
    nginx)
      ver="$($rt inspect "$cid" --format '{{json .Config.Env}}' 2>/dev/null | \
        tr -d '[]\",' | tr ' ' '\n' | grep -E '^NGINX_VERSION=' | \
        sed -nE 's/.*=[vV]?([0-9][0-9.]*).*/\1/p' | head -1 || true)"
    ;;
  esac
  [ -n "$ver" ] && { printf '%s' "$ver"; return; }
  for key in org.opencontainers.image.version org.label-schema.version version; do
    ver="$($rt inspect "$cid" --format "{{ index .Config.Labels \"$key\" }}" 2>/dev/null | \
      sed -nE 's/^[vV]?([0-9][0-9.]*).*/\1/p' || true)"
    [ -n "$ver" ] && { printf '%s' "$ver"; return; }
  done
  printf ''
}

# ---------- 通用容器运行时扫描（docker/podman/nerdctl） ----------
scan_runner() {
  runner="$1"
  label="$2"
  method_prefix="$3"
  format='{{.ID}}\t{{.Image}}\t{{.Names}}'
  out=$(sh -c "$runner ps --format '$format' 2>/dev/null" || true)
  [ -z "$out" ] && return
  printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r id image names; do
    info="$(guess_from_image "$image")"
    cname="$(printf '%s' "$info" | awk -F'\t' '{print $1}')"
    ver_guess="$(printf '%s' "$info" | awk -F'\t' '{print $2}')"
    base="$(printf '%s' "$info" | awk -F'\t' '{print $3}')"
    tag="$(printf '%s' "$info" | awk -F'\t' '{print $4}')"
    detail="$label name=$names image=$image id=$id"

    if [ -n "$cname" ] && [ -n "$ver_guess" ] && [ "$ver_guess" != "latest" ]; then
      emit "$names" "$ver_guess" "$method_prefix:image" "$detail"
      continue
    fi

    if [ "$CONTAINER_DEEP" = "1" ] && [ -n "$cname" ]; then
      exec_in_container() { sh -c "$runner exec $id sh -lc \"$1\" 2>/dev/null" 2>/dev/null || true; }
      ver=""
      case "$cname" in
        nginx) ver="$(exec_in_container "nginx -v 2>&1 | sed -n 's/^nginx version: nginx\\/\\([0-9.]*\\).*/\\1/p'")" ;;
        apache-httpd) ver="$(exec_in_container "httpd -v 2>/dev/null || apache2 -v 2>/dev/null" | sed -n "s/^Server version: Apache\\/\\([0-9.]*\\).*/\\1/p")" ;;
        mysql|mariadb) ver="$(exec_in_container "mysqld --version 2>&1" | sed -n "s/.*Ver \\([0-9.]*\\).*/\\1/p")" ;;
        postgresql) ver="$(exec_in_container "postgres -V 2>/dev/null" | awk '{print $3}')" ;;
        redis) ver="$(exec_in_container "redis-server --version 2>/dev/null" | sed -n "s/.*v=\\([0-9.]*\\).*/\\1/p")" ;;
        mongodb) ver="$(exec_in_container "mongod --version 2>/dev/null" | sed -n "s/^db version v\\([0-9.]*\\).*/\\1/p")" ;;
        elasticsearch) ver="$(exec_in_container "elasticsearch --version 2>/dev/null" | sed -n "s/^Version: \\([0-9.]*\\).*/\\1/p")" ;;
        kafka) ver="$(exec_in_container "ls -1 /opt/kafka/libs/kafka_*-[0-9]*.jar 2>/dev/null" | sed -n "s/.*kafka_.*-\\([0-9.]*\\)\\.jar/\\1/p" | head -1)" ;;
        zookeeper) ver="$(exec_in_container "zkServer.sh version 2>/dev/null" | sed -n "s/.*Version: \\([0-9.]*\\).*/\\1/p")" ;;
        rabbitmq) ver="$(exec_in_container "rabbitmq-diagnostics server_version -q 2>/dev/null || rabbitmqctl status 2>/dev/null" | sed -n "s/.*RabbitMQ\",\"\\([0-9.]*\\)\".*/\\1/p")" ;;
        clickhouse) ver="$(exec_in_container "clickhouse-server --version 2>&1" | sed -n "s/^ClickHouse server version \\([0-9.]\\+\\).*/\\1/p")" ;;
        haproxy) ver="$(exec_in_container "haproxy -v 2>&1" | sed -n "s/^HA-Proxy version \\([0-9.]*\\).*/\\1/p")" ;;
        etcd) ver="$(exec_in_container "etcd --version 2>&1" | sed -n "s/^etcd Version: \\([0-9.]*\\).*/\\1/p")" ;;
        consul) ver="$(exec_in_container "consul version 2>&1" | sed -n "s/^Consul v\\([0-9.]*\\).*/\\1/p")" ;;
        tomcat) ver="$(exec_in_container "for d in \"$CATALINA_HOME\" /usr/local/tomcat; do [ -x \"\\$d/bin/version.sh\" ] && \"\\$d/bin/version.sh\" && break; done" | sed -n "s/^Server version: Apache Tomcat\\/\\([0-9.]*\\).*/\\1/p" | head -1)" ;;
      esac
      if [ -n "$ver" ]; then
        emit "$names" "$ver" "$method_prefix:exec" "$detail"
        continue
      fi
    fi

    if [ -n "$cname" ] && [ -z "${ver_guess:-}" ]; then
      ver2="$(inspect_env_label_version "$runner" "$id" "$cname")"
      if [ -n "$ver2" ]; then
        emit "$names" "$ver2" "$method_prefix:inspect" "$detail"
        continue
      fi
    fi

    if [ -n "$cname" ]; then
      emit "$names" "${ver_guess:-}" "$method_prefix:image" "$detail"
    else
      emit "$base" "${ver_guess:-}" "$method_prefix:image" "$detail"
    fi
  done
}

# ---------- 集成多端点扫描 ----------
scan_container_endpoints() {
  if have docker; then scan_runner "docker" "docker(default)" "container"; fi
  if have podman; then scan_runner "podman" "podman" "container"; fi
  if have nerdctl; then scan_runner "nerdctl" "nerdctl" "container"; fi
  # 尝试 rootless docker sockets
  for s in /run/user/*/docker.sock; do
    [ -S "$s" ] || continue
    scan_runner "DOCKER_HOST=unix://$s docker" "docker($s)" "container"
  done
}

# ---------- K8s 探测 ----------
scan_nerdctl_k8s() {
  if have nerdctl; then
    scan_runner "nerdctl -n k8s.io" "nerdctl(-n k8s.io)" "k8s"
  fi
}

scan_crictl() {
  if ! have crictl; then return; fi
  crictl ps --state Running 2>/dev/null | tail -n +2 | \
  awk '{id=$1; image=$2; name=$NF; printf "%s\t%s\t%s\n", id, image, name}' | \
  while IFS="$(printf '\t')" read -r id image name; do
    info="$(guess_from_image "$image")"
    cname="$(printf '%s' "$info" | awk -F'\t' '{print $1}')"
    ver_guess="$(printf '%s' "$info" | awk -F'\t' '{print $2}')"
    base="$(printf '%s' "$info" | awk -F'\t' '{print $3}')"
    detail="crictl name=$name image=$image id=$id"
    if [ -n "$cname" ] && [ -n "$ver_guess" ] && [ "$ver_guess" != "latest" ]; then
      emit "$cname" "$ver_guess" "k8s:image" "$detail"
    elif [ -n "$cname" ]; then
      emit "$cname" "" "k8s:image" "$detail"
    else
      emit "$base" "$ver_guess" "k8s:image" "$detail"
    fi
  done
}

scan_kubectl() {
  if ! have kubectl; then return; fi
  kubectl get pods -A --no-headers -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,IMAGES:.spec.containers[*].image' 2>/dev/null | \
  while IFS= read -r line; do
    ns="$(printf '%s\n' "$line" | awk '{print $1}')"
    pod="$(printf '%s\n' "$line" | awk '{print $2}')"
    images="$(printf '%s\n' "$line" | cut -d' ' -f3- | tr ',' ' ')"
    for img in $images; do
      info="$(guess_from_image "$img")"
      cname="$(printf '%s' "$info" | awk -F'\t' '{print $1}')"
      ver_guess="$(printf '%s' "$info" | awk -F'\t' '{print $2}')"
      base="$(printf '%s' "$info" | awk -F'\t' '{print $3}')"
      detail="kubectl ns=$ns pod=$pod image=$img"
      if [ -n "$cname" ] && [ -n "$ver_guess" ] && [ "$ver_guess" != "latest" ]; then
        emit "$cname" "$ver_guess" "k8s:image" "$detail"
      elif [ -n "$cname" ]; then
        emit "$cname" "" "k8s:image" "$detail"
      else
        emit "$base" "$ver_guess" "k8s:image" "$detail"
      fi

      if [ "$K8S_DEEP" = "1" ] && [ -n "$cname" ]; then
        ver=""
        case "$cname" in
          nginx) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'nginx -v 2>&1 | sed -n "s/^nginx version: nginx\\/\\([0-9.]*\\).*/\\1/p"' 2>/dev/null || true)" ;;
          apache-httpd) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'httpd -v 2>/dev/null || apache2 -v 2>/dev/null' 2>/dev/null | sed -n 's/^Server version: Apache\\/\\([0-9.]*\\).*/\\1/p' || true)" ;;
          mysql|mariadb) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'mysqld --version 2>&1' 2>/dev/null | sed -n 's/.*Ver \\([0-9.]*\\).*/\\1/p' || true)" ;;
          postgresql) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'postgres -V 2>/dev/null' 2>/dev/null | awk '{print $3}' || true)" ;;
          redis) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'redis-server --version 2>/dev/null' 2>/dev/null | sed -n 's/.*v=\\([0-9.]*\\).*/\\1/p' || true)" ;;
          mongodb) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'mongod --version 2>/dev/null' 2>/dev/null | sed -n 's/^db version v\\([0-9.]*\\).*/\\1/p' || true)" ;;
          elasticsearch) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'elasticsearch --version 2>/dev/null' 2>/dev/null | sed -n 's/^Version: \\([0-9.]*\\).*/\\1/p' || true)" ;;
          kafka) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'ls -1 /opt/kafka/libs/kafka_*-[0-9]*.jar 2>/dev/null' 2>/dev/null | sed -n 's/.*kafka_.*-\\([0-9.]*\\)\\.jar/\\1/p' | head -1 || true)" ;;
          zookeeper) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'zkServer.sh version 2>/dev/null' 2>/dev/null | sed -n 's/.*Version: \\([0-9.]*\\).*/\\1/p' || true)" ;;
          rabbitmq) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'rabbitmq-diagnostics server_version -q 2>/dev/null || rabbitmqctl status 2>/dev/null' 2>/dev/null | sed -n 's/.*RabbitMQ\",\"\\([0-9.]*\\)\".*/\\1/p' || true)" ;;
          tomcat) ver="$(kubectl exec -n "$ns" "$pod" -- sh -lc 'for d in \"$CATALINA_HOME\" /usr/local/tomcat; do [ -x \"\\$d/bin/version.sh\" ] && \"\\$d/bin/version.sh\" && break; done' 2>/dev/null | sed -n 's/^Server version: Apache Tomcat\\/\\([0-9.]*\\).*/\\1/p' | head -1 || true)" ;;
        esac
        [ -n "$ver" ] && emit "$cname" "$ver" "k8s:exec" "$detail"
      fi
    done
  done
}

# ---------- 执行 ----------
if [ "$SCAN_CONTAINER" = "1" ]; then
  scan_container_endpoints
fi

if [ "$SCAN_K8S" = "1" ]; then
  scan_nerdctl_k8s
  scan_crictl
  scan_kubectl
fi

# 结束
exit 0
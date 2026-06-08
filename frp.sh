#!/bin/sh

# 获取基础变量
frpc_enable="$(nvram get frpc_enable)"
frps_enable="$(nvram get frps_enable)"
frp_tag="$(nvram get frp_tag)"
http_username="$(nvram get http_username)"
user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
github_proxys="$(nvram get github_proxy)"
[ -z "$github_proxys" ] && github_proxys=" "

# 自动检测架构
detect_arch() {
    local kernel_arch=$(uname -m)
    case $kernel_arch in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        arm*) ARCH="arm" ;;
        mipsle) ARCH="mipsle" ;;
        mips) ARCH="mips" ;;
        *) ARCH="unknown" ;;
    esac
    # 架构映射表 (如果 frp 发行版名称与 uname 不一致，可在此调整)
    # 例如: ARCH_MAP="arm:v7" 表示当检测到 arm 时，下载 v7 版本
    # 这里简化处理，直接使用检测到的名称
}

check_frp () {
    check_net
    result_net=$?
    if [ "$result_net" = "1" ]; then
        if [ -z "$(pidof frpc)" ] && [ "$frpc_enable" = "1" ]; then
            frp_start
        fi
        if [ -z "$(pidof frps)" ] && [ "$frps_enable" = "1" ]; then
            frp_start
        fi
    fi
}

check_net() {
    /bin/ping -c 3 223.5.5.5 -w 5 >/dev/null 2>&1
    if [ "$?" = "0" ]; then
        return 1
    else
        return 2
        logger -t "【Frp】" "检测到互联网未能成功访问,稍后再尝试启动frp"
    fi
}

frp_renum=`nvram get frp_renum`
frp_restart () {
    relock="/var/lock/frp_restart.lock"
    if [ "$1" = "o" ] ; then
        nvram set frp_renum="0"
        [ -f $relock ] && rm -f $relock
        return 0
    fi
    if [ "$1" = "x" ] ; then
        frp_renum=${frp_renum:-"0"}
        frp_renum=`expr $frp_renum + 1`
        nvram set frp_renum="$frp_renum"
        if [ "$frp_renum" -gt "3" ] ; then
            I=19
            echo $I > $relock
            logger -t "【Frp】" "多次尝试启动失败，等待【"`cat $relock`"分钟】后自动尝试重新启动"
            while [ $I -gt 0 ]; do
                I=$(($I - 1))
                echo $I > $relock
                sleep 60
                [ "$(nvram get frp_renum)" = "0" ] && break
                [ $I -lt 0 ] && break
            done
            nvram set frp_renum="1"
        fi
        [ -f $relock ] && rm -f $relock
    fi
    frp_start
}

find_bin() {
    frpc="$(nvram get frpc_bin)"
    frps="$(nvram get frps_bin)"
    dirs="/etc/storage/bin /tmp/frp /usr/bin"
    if [ -z "$frpc" ] ; then
        for dir in $dirs ; do
            if [ -f "$dir/frpc" ] ; then
                frpc="$dir/frpc"
                [ ! -x "$frpc" ] && chmod +x "$frpc"
                break
            fi
        done
        [ -z "$frpc" ] && frpc="/tmp/frp/frpc"
    fi
    if [ -z "$frps" ] ; then
        for dir in $dirs ; do
            if [ -f "$dir/frps" ] ; then
                frps="$dir/frps"
                [ ! -x "$frps" ] && chmod +x "$frps"
                break
            fi
        done
        [ -z "$frps" ] && frps="/tmp/frp/frps"
    fi
}

get_ver() {
    find_bin
    # 检查 frpc 版本
    if [ -f "$frpc" ] ; then
        [ ! -x "$frpc" ] && chmod +x "$frpc"
        frpc_ver_raw="$($frpc --version 2>/dev/null)"
        if [ -z "$frpc_ver_raw" ]; then
            frpc_v=""
        else
            frpc_v="frpc-v${frpc_ver_raw}"
        fi
    else
        frpc_v=""
    fi

    # 检查 frps 版本 (修复了变量名混淆)
    if [ -f "$frps" ] ; then
        [ ! -x "$frps" ] && chmod +x "$frps"
        frps_ver_raw="$($frps --version 2>/dev/null)"
        if [ -z "$frps_ver_raw" ]; then
            frps_v=""
        else
            frps_v="frps-v${frps_ver_raw}"
        fi
    else
        frps_v=""
    fi

    nvram set frp_ver="$frpc_v $frps_v"
}

get_tag() {
    # 修复了 [ 命令的语法错误
    if [ -z "$curltest" ] || [ ! -s "$(which curl)" ]; then
        logger -t "【Frp】" "开始获取最新版本 (使用 wget)..."
        # 尝试使用 wget
        tag="$( wget --no-check-certificate -T 5 -t 3 --user-agent "$user_agent" -qO- https://api.github.com/repos/fatedier/frp/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
        if [ -z "$tag" ]; then
            tag="$( wget --no-check-certificate -T 5 -t 3 --user-agent "$user_agent" -qO- https://api.github.com/repos/fatedier/frp/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
        fi
    else
        logger -t "【Frp】" "开始获取最新版本 (使用 curl)..."
        tag="$( curl -k --connect-timeout 3 --user-agent "$user_agent" -s https://api.github.com/repos/fatedier/frp/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
        if [ -z "$tag" ]; then
            tag="$( curl -Lk --connect-timeout 3 --user-agent "$user_agent" -s https://api.github.com/repos/fatedier/frp/releases/latest 2>&1 | grep 'tag_name' | cut -d\" -f4 )"
        fi
    fi
    if [ -z "$tag" ]; then
        logger -t "【Frp】" "无法获取最新版本，将使用默认版本"
        tag="v0.61.0"
    fi
    nvram set frp_ver_n="$tag"
}

frp_dl () {
    tag="$1"
    newtag="$(echo "$tag" | tr -d 'v' | tr -d ' ')"
    mkdir -p /tmp/frp
    
    # 获取架构
    detect_arch
    if [ "$ARCH" = "unknown" ]; then
        logger -t "【Frp】" "无法识别的 CPU 架构: $kernel_arch"
        return 1
    fi

    # 下载文件名
    dl_file="frp_${newtag}_linux_${ARCH}.tar.gz"
    dl_url="https://github.com/fatedier/frp/releases/download/${tag}/${dl_file}"
    
    logger -t "【Frp】" "开始下载 $dl_url"

    for proxy in $github_proxys ; do
        # 尝试获取文件大小
        length=$(wget --no-check-certificate -T 5 -t 3 "${proxy}${dl_url}" -O /dev/null --spider --server-response 2>&1 | grep -i "[Cc]ontent-[Ll]ength" | grep -Eo '[0-9]+' | tail -n 1)
        length=`expr $length + 512000`
        length=`expr $length / 1048576`
        
        frpc_path=$(dirname "$frpc")
        [ ! -d "$frpc_path" ] && mkdir -p "$frpc_path"
        frps_path=$(dirname "$frps")
        [ ! -d "$frps_path" ] && mkdir -p "$frps_path"
        
        frp_size0="$(check_disk_size $frpc_path)"
        [ ! -z "$length" ] && logger -t "【Frp】" "压缩包大小 ${length}M，程序路径可用空间 ${frp_size0}M"

        # 下载
        if curl -Lko "/tmp/${dl_file}" "${proxy}${dl_url}" || wget --no-check-certificate -O "/tmp/${dl_file}" "${proxy}${dl_url}"; then
            # 解压
            tar -xz -C /tmp -f "/tmp/${dl_file}"
            extracted_dir="frp_${newtag}_linux_${ARCH}"
            
            if [ -d "/tmp/${extracted_dir}" ]; then
                # 安装 frpc
                if [ "$frpc_enable" = "1" ] && [ -f "/tmp/${extracted_dir}/frpc" ]; then
                    chmod +x "/tmp/${extracted_dir}/frpc"
                    # 简单验证二进制有效性
                    if [ "$(("/tmp/${extracted_dir}/frpc -h 2>&1 | wc -l)))" -gt 3 ]; then
                        cp "/tmp/${extracted_dir}/frpc" "$frpc"
                        logger -t "【Frp】" "frpc 安装成功"
                    else
                        logger -t "【Frp】" "frpc 二进制文件异常"
                    fi
                fi
                
                # 安装 frps
                if [ "$frps_enable" = "1" ] && [ -f "/tmp/${extracted_dir}/frps" ]; then
                    chmod +x "/tmp/${extracted_dir}/frps"
                    if [ "$(("/tmp/${extracted_dir}/frps -h 2>&1 | wc -l)))" -gt 3 ]; then
                        cp "/tmp/${extracted_dir}/frps" "$frps"
                        logger -t "【Frp】" "frps 安装成功"
                    else
                        logger -t "【Frp】" "frps 二进制文件异常"
                    fi
                fi
                
                # 清理
                rm -rf "/tmp/${extracted_dir}" "/tmp/${dl_file}"
                break
            else
                logger -t "【Frp】" "解压目录不存在，下载可能不完整"
            fi
        else
            logger -t "【Frp】" "下载失败: $dl_url"
        fi
    done
}

scriptfilepath=$(cd "$(dirname "$0")"; pwd)/$(basename $0)

frpc_keep() {
    logger -t "【Frp】" "frpc守护进程启动"
    if [ -s /tmp/script/_opt_script_check ]; then
        sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check
        cat >> "/tmp/script/_opt_script_check" <<-OSC
[ -z "\`pidof frpc\`" ] && logger -t "进程守护" "frpc 进程掉线" && eval "$scriptfilepath start &" && sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check #【frpc】
[ -s /tmp/frpc.log ] && [ "\$(stat -c %s /tmp/frpc.log)" -gt 681984 ] && echo "" > /tmp/frpc.log & #【frpc】
OSC
    fi
}

frps_keep() {
    logger -t "【Frp】" "frps守护进程启动"
    if [ -s /tmp/script/_opt_script_check ]; then
        sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check
        cat >> "/tmp/script/_opt_script_check" <<-OSC
[ -z "\`pidof frps\`" ] && logger -t "进程守护" "frps 进程掉线" && eval "$scriptfilepath start &" && sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check #【frps】
[ -s /tmp/frps.log ] && [ "\$(stat -c %s /tmp/frps.log)" -gt 681984 ] && echo "" > /tmp/frps.log & #【frps】
OSC
    fi
}

frp_start () {
    [ ! -z "$frp_tag" ] && frp_tag="$(echo $frp_tag | tr -d ' ')"
    get_tag
    get_ver
    
    [ ! -z "$tag" ] && newtag="$(echo "$tag" | tr -d 'v' | tr -d ' ')"
    
    # 启动 frpc
    if [ "$frpc_enable" = "1" ] ; then
        sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check
        # 版本检查逻辑
        should_dl=0
        if [ ! -z "$newtag" ] && [ ! -z "$frpc_v" ]; then
            if [ -z "$frp_tag" ] && [ "$frpc_v" != "$newtag" ]; then
                should_dl=1
            elif [ ! -z "$frp_tag" ] && [ "$frpc_v" != "$frp_tag" ]; then
                should_dl=1
            fi
        fi
        
        if [ $should_dl -eq 1 ] || [ ! -f "$frpc" ] || [ "$($frpc -h 2>&1 | wc -l)" -lt 2 ]; then
            if [ ! -z "$frp_tag" ]; then
                frp_dl "$frp_tag"
            else
                frp_dl "$tag"
            fi
        fi
        
        if [ ! -f "$frpc" ]; then
            logger -t "【Frp】" "错误: 找不到 $frpc，无法运行"
        fi
    fi

    # 启动 frps (逻辑同上)
    if [ "$frps_enable" = "1" ] ; then
        sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check
        should_dl=0
        if [ ! -z "$newtag" ] && [ ! -z "$frps_v" ]; then
            if [ -z "$frp_tag" ] && [ "$frps_v" != "$newtag" ]; then
                should_dl=1
            elif [ ! -z "$frp_tag" ] && [ "$frps_v" != "$frp_tag" ]; then
                should_dl=1
            fi
        fi
        
        if [ $should_dl -eq 1 ] || [ ! -f "$frps" ] || [ "$($frps -h 2>&1 | wc -l)" -lt 2 ]; then
            if [ ! -z "$frp_tag" ]; then
                frp_dl "$frp_tag"
            else
                frp_dl "$tag"
            fi
        fi
        
        if [ ! -f "$frps" ]; then
            logger -t "【Frp】" "错误: 找不到 $frps，无法运行"
        fi
    fi

    # 重新获取版本
    get_ver
    eval /etc/storage/frp_script.sh &
    
    # 启动服务并检查状态
    if [ "$frps_enable" = "1" ] ; then
        sleep 4
        if [ -z "$(pidof frps)" ]; then
            logger -t "【Frp】" "frps启动失败，请检查端口冲突或下载完整性"
            sleep 10
            frp_restart x
        else
            mem=$(cat /proc/$(pidof frps)/status 2>/dev/null | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
            scpu="$(top -b -n1 | grep -E "$(pidof frps)" 2>/dev/null | grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /frps/) break; else cpu=i}} END {print $cpu}')"
            logger -t "【Frp】" "frps启动成功, 内存: ${mem}, CPU: ${scpu}%"
            frps_keep
            frp_restart o
        fi
    fi

    if [ "$frpc_enable" = "1" ] ; then
        [ "$frps_enable" = "1" ] && sleep 64
        sleep 4
        if [ -z "$(pidof frpc)" ]; then
            logger -t "【Frp】" "frpc启动失败，请检查配置或网络"
            sleep 10
            frp_restart x
        else
            mem=$(cat /proc/$(pidof frpc)/status 2>/dev/null | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
            ccpu="$(top -b -n1 | grep -E "$(pidof frpc)" 2>/dev/null | grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /frpc/) break; else cpu=i}} END {print $cpu}')"
            logger -t "【Frp】" "frpc启动成功, 内存: ${mem}, CPU: ${ccpu}%"
            frpc_keep
            frp_restart o
        fi
    fi
}

frp_close () {
    scriptname=$(basename $0)
    
    # 优雅停止 frpc
    if [ "$frpc_enable" = "0" ]; then
        sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check
        if [ ! -z "$(pidof frpc)" ]; then
            killall frpc
            # 等待 3 秒让其优雅退出
            sleep 3
            # 如果还存在，强制杀死
            if [ ! -z "$(pidof frpc)" ]; then
                killall -9 frpc
            fi
            logger -t "【Frp】" "已停止 frpc"
        fi
    fi

    # 优雅停止 frps
    if [ "$frps_enable" = "0" ]; then
        sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check
        if [ ! -z "$(pidof frps)" ]; then
            killall frps
            sleep 3
            if [ ! -z "$(pidof frps)" ]; then
                killall -9 frps
            fi
            logger -t "【Frp】" "已停止 frps"
        fi
    fi

    # 清理自身脚本进程
    if [ ! -z "$scriptname" ] ; then
        pids=$(ps -w | grep "$scriptname" | grep -v $$ | grep -v grep | awk '{print $1}')
        for pid in $pids; do
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null
        done
    fi
}

case $1 in
    start)
        frp_start &
        ;;
    stop)
        frp_close
        ;;
    C)
        check_frp &
        ;;
    *)
        echo "Usage: $0 {start|stop|C}"
        exit 1
        ;;
esac

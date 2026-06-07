#!/bin/sh

frpc_enable=$(nvram get frpc_enable)
frps_enable=$(nvram get frps_enable)
frp_tag=$(nvram get frp_tag)
github_proxys=$(nvram get github_proxy)
[ -z "$github_proxys" ] && github_proxys=" "

# 修复：缺失的磁盘检查函数
check_disk_size() {
    df -k "$1" | awk 'NR==2 {print int($4/1024)}'
}

check_net() {
    /bin/ping -c1 -W2 223.5.5.5 >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        return 1
    else
        logger -t "【Frp】" "网络未就绪，稍后重试"
        return 2
    fi
}

check_frp() {
    check_net
    [ $? -ne 1 ] && return
    [ -z "$(pidof frpc)" ] && [ "$frpc_enable" = "1" ] && frp_start &
    [ -z "$(pidof frps)" ] && [ "$frps_enable" = "1" ] && frp_start &
}

find_bin() {
    frpc=$(nvram get frpc_bin)
    frps=$(nvram get frps_bin)
    dirs="/etc/storage/bin /tmp/frp /usr/bin"

    if [ -z "$frpc" ]; then
        for dir in $dirs; do
            if [ -f "$dir/frpc" ]; then
                frpc="$dir/frpc"
                chmod +x "$frpc" 2>/dev/null
                break
            fi
        done
        [ -z "$frpc" ] && frpc="/tmp/frp/frpc"
    fi

    if [ -z "$frps" ]; then
        for dir in $dirs; do
            if [ -f "$dir/frps" ]; then
                frps="$dir/frps"
                chmod +x "$frps" 2>/dev/null
                break
            fi
        done
        [ -z "$frps" ] && frps="/tmp/frp/frps"
    fi
}

# 🔥 修复：版本获取全部错误
get_ver() {
    find_bin
    frpc_v=""
    frps_v=""
    frpc_ver=""
    frps_ver=""

    if [ -f "$frpc" ]; then
        chmod +x "$frpc" 2>/dev/null
        frpc_ver="$($frpc --version 2>/dev/null | head -n1 | awk '{print $2}')"
        [ -n "$frpc_ver" ] && frpc_v="frpc-v$frpc_ver"
    fi

    if [ -f "$frps" ]; then
        chmod +x "$frps" 2>/dev/null
        frps_ver="$($frps --version 2>/dev/null | head -n1 | awk '{print $2}')"
        [ -n "$frps_ver" ] && frps_v="frps-v$frps_ver"
    fi

    nvram set frp_ver="$frpc_v $frps_v"
}

get_tag() {
    [ -n "$frp_tag" ] && { tag="$frp_tag"; nvram set frp_ver_n="$tag"; return; }
    tag="v0.61.1"
    nvram set frp_ver_n="$tag"
}

frp_dl() {
    tag=$1
    newtag=$(echo "$tag" | tr -d 'v ')
    mkdir -p /tmp/frp
    frpc_path=$(dirname "$frpc")
    frps_path=$(dirname "$frps")
    mkdir -p "$frpc_path" "$frps_path"

    for proxy in $github_proxys; do
        url="${proxy}https://github.com/fatedier/frp/releases/download/$tag/frp_${newtag}_linux_mipsle.tar.gz"
        wget --no-check-certificate -T 15 -q "$url" -O /tmp/frp.tar.gz
        [ $? -ne 0 ] && continue

        tar -xf /tmp/frp.tar.gz -C /tmp/
        [ "$frpc_enable" = "1" ] && cp /tmp/frp_${newtag}_linux_mipsle/frpc "$frpc" && chmod +x "$frpc"
        [ "$frps_enable" = "1" ] && cp /tmp/frp_${newtag}_linux_mipsle/frps "$frps" && chmod +x "$frps"
        rm -rf /tmp/frp*
        break
    done
}

frp_restart() {
    [ "$1" = "o" ] && { nvram set frp_renum=0; return; }
    frp_start
}

scriptfp=$(cd "$(dirname "$0")"; pwd)/$(basename "$0")

frpc_keep() {
    sed -i '/【frpc】/d' /tmp/script/_opt_script_check 2>/dev/null
    echo "[ -z \"\$(pidof frpc)\" ] && logger -t \"进程守护\" \"frpc 掉线重启\" && $scriptfp start & #【frpc】" >> /tmp/script/_opt_script_check
}

frps_keep() {
    sed -i '/【frps】/d' /tmp/script/_opt_script_check 2>/dev/null
    echo "[ -z \"\$(pidof frps)\" ] && logger -t \"进程守护\" \"frps 掉线重启\" && $scriptfp start & #【frps】" >> /tmp/script/_opt_script_check
}

frp_start() {
    find_bin
    get_tag
    get_ver

    # 缺失则下载
    if [ "$frps_enable" = "1" ] && [ ! -f "$frps" ]; then
        frp_dl "${frp_tag:-v0.61.1}"
        get_ver
    fi
    if [ "$frpc_enable" = "1" ] && [ ! -f "$frpc" ]; then
        frp_dl "${frp_tag:-v0.61.1}"
        get_ver
    fi

    # 启动用户脚本
    eval /etc/storage/frp_script.sh &

    # frps
    if [ "$frps_enable" = "1" ]; then
        sleep 3
        if [ -z "$(pidof frps)" ]; then
            logger -t "【Frp】" "frps 启动失败，10秒后重试"
            sleep 10
            eval /etc/storage/frp_script.sh &
        fi
        [ -n "$(pidof frps)" ] && {
            logger -t "【Frp】" "frps 启动成功"
            frps_keep
            frp_restart o
        }
    fi

    # frpc
    if [ "$frpc_enable" = "1" ]; then
        [ "$frps_enable" = "1" ] && sleep 15
        sleep 3
        if [ -z "$(pidof frpc)" ]; then
            logger -t "【Frp】" "frpc 启动失败，10秒后重试"
            sleep 10
            eval /etc/storage/frp_script.sh &
        fi
        [ -n "$(pidof frpc)" ] && {
            logger -t "【Frp】" "frpc 启动成功"
            frpc_keep
            frp_restart o
        }
    fi
}

frp_close() {
    killall -9 frpc frps 2>/dev/null
    sed -i '/【frp】/d' /tmp/script/_opt_script_check 2>/dev/null
    logger -t "【Frp】" "已停止所有 FRP 进程"
}

case $1 in
    start) frp_start & ;;
    stop) frp_close ;;
    C) check_frp & ;;
esac

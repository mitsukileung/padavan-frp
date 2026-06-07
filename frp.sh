#!/bin/sh

frpc_enable=`nvram get frpc_enable`
frps_enable=`nvram get frps_enable`
frp_tag=`nvram get frp_tag`
http_username=`nvram get http_username`
user_agent='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
github_proxys="$(nvram get github_proxy)"
[ -z "$github_proxys" ] && github_proxys=" "

check_frp () 
{
	check_net
	result_net=$?
	if [ "$result_net" = "1" ] ;then
		if [ -z "`pidof frpc`" ] && [ "$frpc_enable" = "1" ];then
			frp_start
		fi
		if [ -z "`pidof frps`" ] && [ "$frps_enable" = "1" ];then
			frp_start
		fi
	fi
}

check_net() 
{
	/bin/ping -c 3 223.5.5.5 -w 5 >/dev/null 2>&1
	if [ "$?" == "0" ]; then
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
   			#[ "$(nvram get frps_enable)" = "0" ] && [ "$(nvram get frpc_enable)" = "0" ] && exit 0
			[ $I -lt 0 ] && break
		done
		nvram set frp_renum="1"
	fi
	[ -f $relock ] && rm -f $relock
fi
frp_start
}

find_bin() {
frpc=`nvram get frpc_bin`
frps=`nvram get frps_bin`
 	
dirs="/etc/storage/bin
/tmp/frp
/usr/bin"

if [ -z "$frpc" ] ; then
  for dir in $dirs ; do
    if [ -f "$dir/frpc" ] ; then
        frpc="$dir/frpc"
        [ ! -x "$frpc" ] && chmod +x $frpc
        break
    fi
  done
  [ -z "$frpc" ] && frpc="/tmp/frp/frpc"
fi
if [ -z "$frps" ] ; then
  for dir in $dirs ; do
    if [ -f "$dir/frps" ] ; then
        frps="$dir/frps"
        [ ! -x "$frps" ] && chmod +x $frps
        break
    fi
  done
  [ -z "$frps" ] && frps="/tmp/frp/frps"
fi
}

get_ver() {
	find_bin
	if [ -f "$frpc" ] ; then
 		[ ! -x "$frpc" ] && chmod +x $frpc
		frpc_ver="$($frpc --version)"
		if [ -z "$frpc_ver" ] ; then
			frpc_v=""
		else
			frpc_v="frpc-v${frpc_ver}"
		fi
	fi
	if [ -f "$frps" ] ; then
 		[ ! -x "$frps" ] && chmod +x $frps
		frps_ver="$($frps --version)"
		if [ -z "$frps_ver" ] ; then
			frps_v=""
		else
			frps_v="frps-v${frps_ver}"
		fi
	fi
	nvram set frp_ver="$frpc_v  $frps_v"

}

# 锁定版本 v0.61.1，不再联网获取
get_tag() {
	tag="v0.61.1"
	nvram set frp_ver_n=$tag
	logger -t "【Frp】" "已锁定版本: $tag"
}

# 下载逻辑：保留代理 + 改用新地址直链
frp_dl () 
{
	tag="$1"
	newtag="0.61.1"
	mkdir -p /tmp/frp
 	frpc_path=$(dirname "$frpc")
	[ ! -d "$frpc_path" ] && mkdir -p "$frpc_path"
 	frps_path=$(dirname "$frps")
	[ ! -d "$frps_path" ] && mkdir -p "$frps_path"

	# 下载地址
	frpc_url="https://raw.githubusercontent.com/mitsukileung/padavan-frp/main/frpc"
	frps_url="https://raw.githubusercontent.com/mitsukileung/padavan-frp/main/frps"

	logger -t "【Frp】" "开始下载 frp 二进制文件"
	for proxy in $github_proxys ; do
		success=0

		# 下载 frpc
		if [ "$frpc_enable" = "1" ] && [ ! -f "$frpc" ]; then
			logger -t "【Frp】" "尝试通过代理 $proxy 下载 frpc..."
			wget --no-check-certificate -T 5 -t 3 "${proxy}${frpc_url}" -O "$frpc"
			if [ $? -eq 0 ]; then
				chmod +x "$frpc"
				logger -t "【Frp】" "frpc 下载成功"
				success=1
			fi
		fi

		# 下载 frps
		if [ "$frps_enable" = "1" ] && [ ! -f "$frps" ]; then
			logger -t "【Frp】" "尝试通过代理 $proxy 下载 frps..."
			wget --no-check-certificate -T 5 -t 3 "${proxy}${frps_url}" -O "$frps"
			if [ $? -eq 0 ]; then
				chmod +x "$frps"
				logger -t "【Frp】" "frps 下载成功"
				success=1
			fi
		fi

		# 任一代理成功就退出
		if [ $success -eq 1 ]; then
			break
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

frp_start () 
{
  [ ! -z "$frp_tag" ] && frp_tag="$(echo $frp_tag | tr -d ' ')"
  get_tag
  get_ver
  newtag="0.61.1"

  if [ "$frpc_enable" = "1" ] ;then
  	sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check
  	if [ ! -f "$frpc" ] || [[ "$($frpc -h 2>&1 | wc -l)" -lt 2 ]] ; then
  		frp_dl $tag
  	fi
  	[ ! -f "$frpc" ] && logger -t "【Frp】" "没有$frpc 无法运行.." 
  fi
  
  if [ "$frps_enable" = "1" ] ;then
  	sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check
  	if [ ! -f "$frps" ] || [[ "$($frps -h 2>&1 | wc -l)" -lt 2 ]] ; then
  		frp_dl $tag
  	fi
  	[ ! -f "$frps" ] && logger -t "【Frp】" "没有$frps 无法运行.." 
  fi

  get_ver
  eval /etc/storage/frp_script.sh &

 if [ "$frps_enable" = "1" ] ; then
	sleep 4
	[ -z "`pidof frps`" ] && logger -t "【Frp】" "frps启动失败, 注意检查端口是否有冲突,程序是否下载完整,10 秒后自动尝试重新启动" && sleep 10 && frp_restart x
	[ ! -z "`pidof frps`" ] && logger -t "【Frp】" "请手动配置【外网 WAN - 端口转发 - 启用手动端口映射】来开启WAN访问"
fi
if [ "$frpc_enable" = "1" ] ; then
	[ "$frps_enable" = "1" ] && sleep 64
	sleep 4
	[ -z "`pidof frpc`" ] && logger -t "【Frp】" "frpc启动失败, 注意检查端口是否有冲突,程序是否下载完整,10 秒后自动尝试重新启动" && sleep 10 && frp_restart x
fi
if [ "$frps_enable" = "1" ] && [ ! -z "`pidof frps`" ] ; then
   mem=$(cat /proc/$(pidof frps)/status | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
   scpu="$(top -b -n1 | grep -E "$(pidof frps)" 2>/dev/null| grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /frps/) break; else cpu=i}} END {print $cpu}')"
   logger -t "【Frp】" "frps启动成功" 
   logger -t "【Frp】" "内存占用 ${mem} CPU占用 ${scpu}%"
   frps_keep 
   frp_restart o
fi
if [ "$frpc_enable" = "1" ] && [ ! -z "`pidof frpc`" ] ; then
   mem=$(cat /proc/$(pidof frpc)/status | grep -w VmRSS | awk '{printf "%.1f MB", $2/1024}')
   ccpu="$(top -b -n1 | grep -E "$(pidof frpc)" 2>/dev/null| grep -v grep | awk '{for (i=1;i<=NF;i++) {if ($i ~ /frpc/) break; else cpu=i}} END {print $cpu}')"
   logger -t "【Frp】" "frpc启动成功" 
   logger -t "【Frp】" "内存占用 ${mem} CPU占用 ${ccpu}%" 
   frpc_keep 
   frp_restart o
fi

}
      
frp_close () 
{
	scriptname=$(basename $0)
	if [ "$frpc_enable" = "0" ]; then
		sed -Ei '/【frpc】|^$/d' /tmp/script/_opt_script_check
		if [ ! -z "`pidof frpc`" ]; then
			killall frpc
			killall -9 frpc frp_script.sh
			[ -z "`pidof frpc`" ] && logger -t "【Frp】" "已停止 frpc"
	    	fi
	fi
	if [ "$frps_enable" = "0" ]; then
		sed -Ei '/【frps】|^$/d' /tmp/script/_opt_script_check
		if [ ! -z "`pidof frps`" ]; then
		killall frps
		killall -9 frps frp_script.sh
		[ -z "`pidof frps`" ] && logger -t "【Frp】" "已停止 frps"
	    fi
	fi
 	if [ ! -z "$scriptname" ] ; then
		eval $(ps -w | grep "$scriptname" | grep -v $$ | grep -v grep | awk '{print "kill "$1";";}')
		eval $(ps -w | grep "$scriptname" | grep -v $$ | grep -v grep | awk '{print "kill -9 "$1";";}')
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
esac

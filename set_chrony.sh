#!/bin/bash

#多重起動防止機講

# 同じ名前のプロセスが起動していたら起動しない。
_lockfile="/tmp/`basename $0`.lock"
ln -s /dummy "${_lockfile}" 2> /dev/null || { echo 'Cannot run multiple instance.'; exit 9; }
trap 'rm "${_lockfile}"; exit' 1 2 3 4 5 6 7 8 15


readonly PACKAGE_NAME_CHRONY="chrony"

readonly PACKAGE_NAME_NTP="ntp"

MANAGE_COMMAND=""

NTP_UNINSTALL_COMMAND=""

DNF=0
rpm -q dnf
DNF="${?}"

YUM=0
rpm -q yum
YUM="${?}"

if [ "${DNF}" -eq 0 ]; then
   echo "DNFを使用する。"
   MANAGE_COMMAND="dnf"
   NTP_UNINSTALL_COMMAND="${MANAGE_COMMAND} -y autoremove ntp"
else
   echo "DNFが無いので、YUMを捜索する。"
    if [ "${YUM}" -eq 0 ]; then
       echo "YUMを発見したので、YUMを使用する。"
       MANAGE_COMMAND="yum"
       echo "yum-plugin-remove-with-leavesプラグインをインストールする。"
       YUM_PLUGIN_INSTALL="${MANAGE_COMMAND} -y install yum-plugin-remove-with-leaves"
       $("${YUM_PLUGIN_INSTALL}")
       YUM_PLUGIN_INSTALLED="${?}"
       if [ "${YUM_PLUGIN_INSTALLED}" -gt 0 ]; then
	       echo "Yum-plugin-remove-with-leavesのインストールに失敗したので終了する。"
	       exit 1
       fi
       NTP_UNINSTALL_COMMAND="${MANAGE_COMMAND} -y remove --remove-leaves ntp"
    else
       echo "YUMを発見できなかったので終了する。"
       exit 1
    fi
fi

#ntpを削除
rpm -q "${PACKAGE_NAME_NTP}"
NTP_EXIST="${?}"

if [ "${NTP_EXIST}" -eq 0 ]; then
	$("${NTP_UNINSTALL_COMMAND}")
	if [ "${?}" -gt 0 ]; then
		echo "ntpアンインストールができなかったので終了する。"
		exit 1
	fi
else
	echo "ntpなし。"
fi

#chronyをインストール
rpm -q "${PACKAGE_NAME_CHRONY}"
CHRONY_EXIST="${?}"
if [ "${CHRONY_EXIST}" -eq 0 ]; then
	echo "chronyインストール済みのためインストール処理をせずに継続する。"
else
	INSTALL_COMMAND="${MANAGE_COMMAND} -y install chrony && systemctl start chronyd && systemctl enable chronyd"
	$("${INSTALL_COMMAND}")
	if [ "${?}" -gt 0 ]; then
	   echo "chronyインストール失敗のため終了する。"
	   exit 1
	fi
fi

CONFIG_FILE="/etc/chrony.conf"
SERVER_TEMP_ADD_IN="ntp_servers_add_in.txt"
SERVER_TEMP_ADD_OUT="ntp_servers_add_out.txt"
SERVER_TEMP="ntp_servers.txt"
POOL_TEMP="ntp_pools.txt"
MERGE_TEMP="ntp_sources_temp.txt"
ADD_LIST="ntp_sources_list.txt"

NOWTIME=$(date "+%Y%m%d_%H%M%S")

BACKUP="${CONFIG_FILE}.${NOWTIME}"
cp -p "${CONFIG_FILE}" "${BACKUP}"
if [ "${?}" -gt 0 ]; then
   echo "設定ファイルバックアップ失敗。"
   exit 1
fi

echo "before"
cat "${CONFIG_FILE}"
echo "before"

cd /tmp
if [ "${?}" -gt 0 ]; then
   echo "/tmpへの移動失敗。"
   exit 1
fi

#追加したいntpサーバのリストをヒアドキュメントに記載する。
HOGE=$(cat << EOS
ntp.nict.jp
ntp1.jst.mfeed.ad.jp
EOS
)

echo "${HOGE}" | sort | uniq > "${SERVER_TEMP_ADD_IN}"
if [ "${?}" -gt 0 ]; then
   echo "追加サーバリスト取得失敗。"
   exit 1
fi

#echo
#cat ${SERVER_TEMP_ADD_IN}
#echo

NTP_SERVER_PREFIX="server"
USE_IBURST="iburst"

while read line
do
 echo "${NTP_SERVER_PREFIX} ${line} ${USE_IBURST}" >> "${SERVER_TEMP_ADD_OUT}"
 if [ "${?}" -gt 0 ]; then
    echo "追加サーバリスト書式変更失敗。"
    exit 1
 fi
done < "${SERVER_TEMP_ADD_IN}"
#cat ${SERVER_TEMP_ADD_OUT}

sed -n -e '/^.*server.*iburst$/p' "${CONFIG_FILE}" | sort | uniq > "${SERVER_TEMP}"
if [ "${?}" -gt 0 ]; then
   echo "現行サーバリスト作成失敗。"
   exit 1
fi
#cat ${SERVER_TEMP}

cat "${SERVER_TEMP_ADD_OUT}" >> "${SERVER_TEMP}"
if [ "${?}" -gt 0 ]; then
   echo "現行サーバリストへの追加サーバリストの追記失敗。"
   exit 1
fi
#cat ${SERVER_TEMP}

sed -n -e '/^.*pool.*iburst$/p' "${CONFIG_FILE}" | sort | uniq > "${POOL_TEMP}"
if [ "${?}" -gt 0 ]; then
   echo "現行プールリスト作成失敗。"
   exit 1
fi
#cat ${POOL_TEMP}

touch "${MERGE_TEMP}" && cat "${SERVER_TEMP}" | sort | uniq >> "${MERGE_TEMP}" && cat "${POOL_TEMP}" | sort | uniq >> "${MERGE_TEMP}"
if [ "${?}" -gt 0 ]; then
   echo "サーバリスト、プールリストマージ、重複排除失敗。"
   exit 1
fi
#cat ${MERGE_TEMP}

awk '!a[$0]++' "${MERGE_TEMP}" > "${ADD_LIST}"
if [ "${?}" -gt 0 ]; then
   echo "重複除去失敗。"
   exit 1
fi
#cat ${ADD_LIST}

sed -i '/^.*pool.*iburst$/d' "${CONFIG_FILE}" && sed -i '/^.*server.*iburst$/d' "${CONFIG_FILE}" && cat "${ADD_LIST}" >> "${CONFIG_FILE}"
if [ $? -gt 0 ]; then
   echo "既存サーバリスト更新失敗。"
   exit 1
fi

echo "after"
cat "${CONFIG_FILE}"
echo "after"

echo "diff"
diff "${CONFIG_FILE}" "${BACKUP}"
echo "diff"


systemctl stop chronyd && systemctl start chronyd && systemctl enable chronyd
if [ "${?}" -gt 0 ]; then
   echo "サービス再起動失敗。"
   exit 1
fi

sleep 1m
chronyc sources
if [ "${?}" -gt 0 ]; then
   echo "時刻源列挙失敗。"
   exit 1
fi

cd /tmp && rm -f "${SERVER_TEMP}" "${POOL_TEMP}" "${MERGE_TEMP}" "${ADD_LIST}"
if [ "${?}" -gt 0 ]; then
   echo "一時ファイル削除失敗。"
   exit 1
fi

rm "${_lockfile}"

exit 0

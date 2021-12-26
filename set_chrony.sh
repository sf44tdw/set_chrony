#!/bin/bash

usage_exit() {
        echo "Usage: $0 [-f]" 1>&2
        echo 'chronyの設定ファイルをバックアップし、このファイルに書かれたNTPサーバを追記する。
        -u 設定(既存のロックファイルを削除して終了する。)' 1>&2
        exit 1
}


readonly NOT_REMOVE_LOCK_FILE='f'

readonly REMOVE_LOCK_FILE='t'


ENABLE_u="${NOT_REMOVE_LOCK_FILE}"


while getopts "u" OPT
do
    case $OPT in
        u)  ENABLE_u="${REMOVE_LOCK_FILE}"
            ;;
        :|\?) usage_exit
            ;;
    esac
done

shift $((OPTIND - 1))

#多重起動防止機講
# 同じ名前のプロセスが起動していたら起動しない。
_lockfile="/tmp/`basename $0`.lock"

#ロックファイル削除用。
if [ "${ENABLE_u}" == "${REMOVE_LOCK_FILE}" ]; then
  echo "ロックファイルがあれば削除して終了する。"
   if [ -h "${_lockfile}" ]; then
     rm "${_lockfile}";exit $?
   fi
 exit 0
fi

ln -s /dummy "${_lockfile}" 2> /dev/null || { echo 'Cannot run multiple instance.'; exit 9; }
trap 'rm "${_lockfile}"; exit' 1 2 3 4 5 6 7 8 15


readonly PACKAGE_NAME_CHRONY="chrony"

readonly PACKAGE_NAME_NTP="ntp"

rpm -q "${PACKAGE_NAME_NTP}"
NTP_EXIST="${?}"
if [ "${NTP_EXIST}" -eq 0 ]; then
  if [ "${?}" -gt 0 ]; then
    echo "ntpがインストールされていたので終了する。"
    exit 1
  fi
else
	echo "ntpなし。"
fi

#chrony確認
rpm -q "${PACKAGE_NAME_CHRONY}"
CHRONY_EXIST="${?}"
if [ "${CHRONY_EXIST}" -eq 0 ]; then
  echo "chronyインストール済みのためインストール処理をせずに継続する。"
else
  echo "chronyがインストールされていないので終了する。"
  exit 1
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

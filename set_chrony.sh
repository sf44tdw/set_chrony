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

while getopts "u" OPT; do
	case $OPT in
	u)
		ENABLE_u="${REMOVE_LOCK_FILE}"
		;;
	: | \?)
		usage_exit
		;;
	esac
done

shift $((OPTIND - 1))

#このスクリプトの名前。
readonly MY_NAME=$(basename "${0}")

#ロックファイルのパス
_lockfile="/tmp/${MY_NAME}.lock"

function delete_lock_file_and_exit() {
	local -r EXIT_CODE="${1}"
	expr "${EXIT_CODE}" + 1 >/dev/null 2>&1
	local -r ret="${?}"
	if [ "${ret}" -ge 2 ]; then
		echo "指定された戻り値が数字ではない。戻り値=${EXIT_CODE}"1 >&2
		exit 100
	fi
	if [ -h "${_lockfile}" ]; then
		if ! rm -f "${_lockfile}" >/dev/null 2>&1; then
			echo "ロックファイル削除失敗。戻り値はrmのものになる。ロックファイル=${_lockfile}"1 >&2
			exit "${?}"
		fi
	fi
	exit "${EXIT_CODE}"
}

#ロックファイル削除用。
if [ "${ENABLE_u}" == "${REMOVE_LOCK_FILE}" ]; then
	delete_lock_file_and_exit 100
fi

#ロックファイル生成。
ln -s /dummy "${_lockfile}" >/dev/null 2>&1 || {
	echo 'Cannot run multiple instance.'
	#他のプロセスが起動中なのでロックファイルは削除しない。
	exit 110
}

trap 'rm "${_lockfile}"; exit' SIGHUP SIGINT SIGQUIT SIGTERM

readonly PACKAGE_NAME_CHRONY="chrony"

readonly PACKAGE_NAME_NTP="ntp"

rpm -q "${PACKAGE_NAME_NTP}"
readonly NTP_EXIST="${?}"
if [ "${NTP_EXIST}" -eq 0 ]; then
	echo "ntpがインストールされていたので終了する。"
	delete_lock_file_and_exit 1
else
	echo "ntpなし。"
fi

#chrony確認
rpm -q "${PACKAGE_NAME_CHRONY}"
readonly CHRONY_EXIST="${?}"
if [ "${CHRONY_EXIST}" -eq 0 ]; then
	echo "chronyインストール済みのため継続する。"
else
	echo "chronyがインストールされていないので終了する。"
	delete_lock_file_and_exit 1
fi

readonly CONFIG_FILE="/etc/chrony.conf"
readonly TEMP_DIR="/tmp"
readonly SERVER_TEMP_ADD_IN="${TEMP_DIR}/ntp_servers_add_in.txt"
readonly SERVER_TEMP_ADD_OUT="${TEMP_DIR}/ntp_servers_add_out.txt"
readonly SERVER_TEMP="${TEMP_DIR}/ntp_servers.txt"
readonly POOL_TEMP="${TEMP_DIR}/ntp_pools.txt"
readonly MERGE_TEMP="${TEMP_DIR}/ntp_sources_temp.txt"
readonly ADD_LIST="${TEMP_DIR}/ntp_sources_list.txt"

readonly NOWTIME=$(date "+%Y%m%d_%H%M%S")

readonly BACKUP="${CONFIG_FILE}.${NOWTIME}"
if ! cp -p "${CONFIG_FILE}" "${BACKUP}"; then
	echo "設定ファイルバックアップ失敗。"
	delete_lock_file_and_exit 1
fi

echo "before"
cat "${CONFIG_FILE}"
echo "before"

#追加したいntpサーバのリストをヒアドキュメントに記載する。
readonly HOGE=$(
	cat <<EOS
ntp.nict.jp
ntp1.jst.mfeed.ad.jp
EOS
)

if ! echo "${HOGE}" | sort | uniq >"${SERVER_TEMP_ADD_IN}"; then
	echo "追加サーバリスト取得失敗。"
	delete_lock_file_and_exit 1
fi

NTP_SERVER_PREFIX="server"
USE_IBURST="iburst"

while read -r line; do
	if ! echo "${NTP_SERVER_PREFIX} ${line} ${USE_IBURST}" >>"${SERVER_TEMP_ADD_OUT}"; then
		echo "追加サーバリスト書式変更失敗。"
		delete_lock_file_and_exit 1
	fi
done <"${SERVER_TEMP_ADD_IN}"

if ! sed -n -e '/^.*server.*iburst$/p' "${CONFIG_FILE}" | sort | uniq >"${SERVER_TEMP}"; then
	echo "現行サーバリスト作成失敗。"
	delete_lock_file_and_exit 1
fi

if ! cat "${SERVER_TEMP_ADD_OUT}" >>"${SERVER_TEMP}"; then
	echo "現行サーバリストへの追加サーバリストの追記失敗。"
	delete_lock_file_and_exit 1
fi

if ! sed -n -e '/^.*pool.*iburst$/p' "${CONFIG_FILE}" | sort | uniq >"${POOL_TEMP}"; then
	echo "現行プールリスト作成失敗。"
	delete_lock_file_and_exit 1
fi

readonly MERGE_ERROR_MESSAGE_COMMON="サーバリスト、プールリストマージ、重複排除失敗。"
if ! touch "${MERGE_TEMP}"; then
	echo "${MERGE_ERROR_MESSAGE_COMMON}_1"
	delete_lock_file_and_exit 1
fi

if ! cat "${SERVER_TEMP}" | sort | uniq >>"${MERGE_TEMP}"; then
	echo "${MERGE_ERROR_MESSAGE_COMMON}_2"
	delete_lock_file_and_exit 1
fi

if ! cat "${POOL_TEMP}" | sort | uniq >>"${MERGE_TEMP}"; then
	echo "${MERGE_ERROR_MESSAGE_COMMON}_3"
	delete_lock_file_and_exit 1
fi

if ! awk '!a[$0]++' "${MERGE_TEMP}" >"${ADD_LIST}"; then
	echo "重複除去失敗。"
	delete_lock_file_and_exit 1
fi

readonly UPDATE_CONFIG_ERROR_MESSAGE_COMMON="既存サーバリスト更新失敗。"
if ! sed -i '/^.*pool.*iburst$/d' "${CONFIG_FILE}"; then
	echo "${UPDATE_CONFIG_ERROR_MESSAGE_COMMON}_1"
	delete_lock_file_and_exit 1
fi

if ! sed -i '/^.*server.*iburst$/d' "${CONFIG_FILE}"; then
	echo "${UPDATE_CONFIG_ERROR_MESSAGE_COMMON}_2"
	delete_lock_file_and_exit 1
fi

if ! cat "${ADD_LIST}" >>"${CONFIG_FILE}"; then
	echo "${UPDATE_CONFIG_ERROR_MESSAGE_COMMON}_3"
	delete_lock_file_and_exit 1
fi

echo "after"
cat "${CONFIG_FILE}"
echo "after"

echo "diff"
diff "${CONFIG_FILE}" "${BACKUP}"
echo "diff"

sleep 1m

if ! systemctl enable chronyd; then
	echo "サービス有効化失敗。"
	delete_lock_file_and_exit 1
fi

sleep 1m

if ! systemctl restart chronyd; then
	echo "サービス再起動失敗。"
	delete_lock_file_and_exit 1
fi

sleep 1m

if ! chronyc sources; then
	echo "時刻源列挙失敗。"
	delete_lock_file_and_exit 1
fi

if ! rm -f "${SERVER_TEMP}" "${POOL_TEMP}" "${MERGE_TEMP}" "${ADD_LIST}"; then
	echo "一時ファイル削除失敗。"
	delete_lock_file_and_exit 1
fi

delete_lock_file_and_exit 0

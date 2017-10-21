#!/bin/bash

MANAGE_COMMAND=""

NTP_UNINSTALL_COMMAND=""

DNF=0
rpm -q dnf
DNF=`echo $?`

YUM=0
rpm -q yum
YUM=`echo $?`

if [ ${DNF} -eq 0 ]; then
   echo "dnf found. Use dnf."
   MANAGE_COMMAND="dnf"
   NTP_UNINSTALL_COMMAND="dnf -y autoremove ntp"
else
   echo "dnf not found. Search yum."
    if [ ${YUM} -eq 0 ]; then
       echo "yum found. Use yum."
       MANAGE_COMMAND="yum"
       echo "Install yum-plugin-remove-with-leaves."
       yum -y install yum-plugin-remove-with-leaves
	   NTP_UNINSTALL_COMMAND="yum -y remove --remove-leaves ntp"
fi
    else
       echo "yum not found. Error."
       exit 1
    fi
fi

#ntpを削除
`${NTP_UNINSTALL_COMMAND}`
if [ $? -gt 0 ]; then
   echo "ntpアンインストール失敗。"
   exit -1
fi

#chronyをインストール
INSTALL_COMMAND="${MANAGE_COMMAND} -y install chrony && systemctl start chronyd && systemctl enable chronyd"
`${INSTALL_COMMAND}`
if [ $? -gt 0 ]; then
   echo "chronyインストール失敗。"
   exit -1
fi

CONFIG_FILE="/etc/chrony.conf"

SERVER_TEMP="ntp_servers.txt"
POOL_TEMP="ntp_pools.txt"
MERGE_TEMP="ntp_sources_temp.txt"
ADD_LIST="ntp_sources_list.txt"

cp -p ${CONFIG_FILE} ${CONFIG_FILE}.`date "+%Y%m%d_%H%M%S"`
if [ $? -gt 0 ]; then
   echo "設定ファイルバックアップ失敗。"
   exit -1
fi

cd /tmp
if [ $? -gt 0 ]; then
   echo "/tmpへの移動失敗。"
   exit -1
fi

sed -n -e /^.*server.*iburst$/p ${CONFIG_FILE} | sort | uniq > ${SERVER_TEMP} && echo "server ntp.nict.jp iburst" >> ${SERVER_TEMP} && echo "server ntp1.jst.mfeed.ad.jp iburst" >> ${SERVER_TEMP}
if [ $? -gt 0 ]; then
   echo "サーバリスト作成失敗。"
   exit -1
fi
#cat ${SERVER_TEMP}

sed -n -e /^.*pool.*iburst$/p ${CONFIG_FILE} | sort | uniq > ${POOL_TEMP}
if [ $? -gt 0 ]; then
   echo "プールリスト作成失敗。"
   exit -1
fi
#cat ${POOL_TEMP}

touch ${MERGE_TEMP} && cat ${SERVER_TEMP} | sort | uniq >>${MERGE_TEMP} && cat ${POOL_TEMP} | sort | uniq >>${MERGE_TEMP}
if [ $? -gt 0 ]; then
   echo "マージ失敗。"
   exit -1
fi
#cat ${MERGE_TEMP}

awk '!a[$0]++' ${MERGE_TEMP} > ${ADD_LIST}
if [ $? -gt 0 ]; then
   echo "重複除去失敗。"
   exit -1
fi 
#cat ${ADD_LIST}

sed -i '/^.*pool.*iburst$/d' ${CONFIG_FILE} && sed -i '/^.*server.*iburst$/d' ${CONFIG_FILE} && cat ${ADD_LIST} >> ${CONFIG_FILE}
if [ $? -gt 0 ]; then
   echo "既存サーバリスト更新失敗。"
   exit -1
fi
cat ${CONFIG_FILE}

systemctl stop chronyd && systemctl start chronyd && systemctl enable chronyd && chronyc sources
if [ $? -gt 0 ]; then
   echo "サービス再起動失敗。"
   exit -1
fi

cd /tmp && rm -f ${SERVER_TEMP} ${POOL_TEMP} ${MERGE_TEMP} ${ADD_LIST}
if [ $? -gt 0 ]; then
   echo "一時ファイル削除失敗。"
   exit -1
fi


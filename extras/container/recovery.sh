#!/bin/bash

#获取当前glusterfs应用所在的命名空间
NAMESPACES=`/host/bin/kubectl get po --all-namespaces |grep glusterfs |grep -v heketi | grep -v NAME | awk '{print $1}' |sed -n 1p`
TOKEN=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_TOKEN}`
IN_VIP=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_VIP}`
MATRIX_SECURE_PORT=`/host/bin/kubectl get cm -n matrix -o jsonpath={.items[0].data.MATRIX_SECURE_PORT}`

#检查当前环境是否为故障节点恢复环境
check() {
    checkGFSConfigLost
    checkVGLost
    checkLVLost
    checkBrickLost
    checkMountLost
}

#获取错误节点的nodeID
#param：nodeIP string
#return：nodeID string
getErrorNodeId() {
    nodeIds=`heketi-cli node list  --user admin --secret admin  |awk '{print $1}' |tr '\n' ' '`
    nodeId=""
    for nodeId in ${nodeIds[@]}; do
        nodeId=`echo ${nodeId:3}`
        test=`heketi-cli node info $nodeId --user admin --secret admin |grep $1`
        if [ -n "$test" ]; then
            break
        fi
    done
    echo $nodeId
}

#获取错误节点的deviceids
#param：nodeId string
#return：deviceIds string to array
getErrorDeviceId() {
    #恢复GlusterFS存储卷
    deviceIds=`heketi-cli node info $1 --user admin --secret admin|grep Name: |grep Id: |tr "\n" " "`
    arrayDeviceId=($deviceIds)
    deviceIds=""
    for ids in ${arrayDeviceId[@]}; do
        if [ `echo "$ids"|grep Id:` ]; then
            id=`echo ${ids:3}`
            deviceIds=$id $deviceIds
        fi
    done
    echo $deviceIds
}

#获取错误节点的brickIds
#param：deviceId string
#return：brickIds string to array
getErrorBrickId() {
    brickNum=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks |/host/bin/jq length`
    brickIds=""
    for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[$i] |sed 's#\"##g'`
        brickIds=$brickId $brickIds
    done
    echo $brickIds
}

#恢复GlusterFS集群
#param：errorNodePodName string, allGlusterFSPodIP string to array, normalNodePodName string
#return：null
recoveryGFSCluster() {
    newIp=`/host/bin/kubectl get po $1 -n ${NAMESPACES} -owide |grep -v 'IP' |awk '{print $6}'`
    newUUID=`/host/bin/kubectl exec -i $1  -n ${NAMESPACES} -- cat /var/lib/glusterd/glusterd.info |grep UUID |tr "UUID=" " " |sed 's/^[ \t]*//g'`
    oldUUID=`/host/bin/kubectl exec -i $3  -n ${NAMESPACES} -- gluster pool list |grep $newIp |awk '{print $1}'`
    /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- sed -i 's/'$newUUID'/'$oldUUID'/g' /var/lib/glusterd/glusterd.info
    /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- systemctl restart glusterd
    ips=($2)
    for ip in ${ips[@]};
    do
        /host/bin/kubectl exec -i $1  -n ${NAMESPACES} -- gluster peer probe $ip
    done
    for ip in ${ips[@]};
    do
        gfsPodName=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep $ip |awk '{print $1}' |grep -v NAME`
        /host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- systemctl restart glusterd
    done
}

#恢复用户自定义配置
#param：errorNodePodName string, normalNodePodName string
#return：null
checkGFSConfig() {
    #修改新建节点的glusterFS的ip配置，默认配置为ipv4
    nodeips=`/host/bin/kubectl get po  -n ${NAMESPACES} -owide|grep glusterfs|awk '{print $6}' |tr '\n' ' '`
    ip=`echo ${nodeips} |awk '{print $1}'`
    if [[ $ip =~ "." ]]; then
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- sed -i 's/    option transport.address-family inet6/#   option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- systemctl restart glusterd
    elif [[ $ip =~ ":" ]]; then
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- sed -i 's/#   option transport.address-family inet6/    option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- systemctl restart glusterd
    fi
    #修改定制占用端口数的配置
    port=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- cat /etc/glusterfs/glusterd.vol |grep "option max-port" | tr -cd "[0-9]"`
    if [ "$port" != "49352" ]; then
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- sed -i 's/    option max-port  49352/    option max-port  $port/g' /etc/glusterfs/glusterd.vol
    fi
}

#恢复Device的VG
#param：deviceIds string, errorNodePodName string
#return：null
recoveryVG() {
    deviceArray=($1)
    for dev in ${deviceArray[@]}
        devs=`heketi-cli device info $dev --user admin --secret admin |grep "Create Path:"`
        #获取盘符名称
        devName=`echo ${devs:13}`
        #获取vg名称
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[0] |sed 's#\"##g'`
        vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.Info.path |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
        pvUUID=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Info.pv_uuid |sed 's#\"##g'`
        #删除软连接，防止vg创建失败
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- rm -rf /dev/$vgName
        #创建pv
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm pvcreate -ff --metadatasize=128M --dataalignment=256K '$devName' --uuid '$pvUUID' --norestorefile
        #创建vg
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm vgcreate -qq --physicalextentsize=4M --autobackup=n  '$vgName' '$devName'
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/bin/udevadm info --query=symlink --name=$devName
    done
}

#恢复VG的LV
recoveryLV() {
     #获取brickId，创建brick文件夹
    num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks |/host/bin/jq length`
    for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[$i] |sed 's#\"##g'`
        vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.Info.path |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
        poolmetadatasize=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.PoolMetadataSize`
        size=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.TpSize`
        tpName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.LvmThinPool |sed 's#\"##g'`
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm lvcreate -qq --autobackup=n --poolmetadatasize $poolmetadatasize"K" --chunksize 256K --size $size"K" --thin $vgName/$tpName --virtualsize $size"K" --name brick_$brickId
    done
    echo 0
}

#恢复brick文件夹
recoveryBrickFile() {
    #获取brickId，创建brick文件夹
    num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks |/host/bin/jq length`
    for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$2"'.Bricks[$i] |sed 's#\"##g'`
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId
    done
    echo 0
}

#恢复LV的挂载
recoveryMount() {
    #获取brickID
    num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks |/host/bin/jq length`
    for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$2"'.Bricks[$i] |sed 's#\"##g'`
        vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.Info.path |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
        #格式化LV
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- mkfs.xfs -i size=512 -n size=8192 /dev/mapper/$vgName-brick_$brickId
        #持久化挂载点信息
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- awk "BEGIN {print \"/dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId xfs rw,inode64,noatime,nouuid 1 2\" >> \"/var/lib/heketi/fstab\"}"
        #挂载LV到brick目录中
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- mount -o rw,inode64,noatime,nouuid /dev/mapper/$2-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId
        #创建/brick/.glusterfs，供后续存储数据恢复
        /host/bin/kubectl exec -i $1 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs
    done
}

#恢复GlusterFS存储数据
#param：errorNodePodName string
#return：null
recoveryStorage() {
    volumes=`kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume list |tr "\n" " "`
    arrayVolume=($volumes)
    for volume in ${arrayVolume[@]}; do
        kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume start $volume force
        kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume heal $volume full
    done
}


recoveryDevice() {
    devs=`heketi-cli device info $1 --user admin --secret admin |grep "Create Path:"`
    #获取盘符名称
    devName=`echo ${devs:13}`
    #获取vg名称
    brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[0] |sed 's#\"##g'`
    vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$brickId"'.Info.path |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
    pvUUID=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Info.pv_uuid |sed 's#\"##g'`
    #删除软连接，防止vg创建失败
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- rm -rf /dev/$vgName
    #创建pv
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm pvcreate -ff --metadatasize=128M --dataalignment=256K '$devName' --uuid '$pvUUID' --norestorefile
    #创建vg
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm vgcreate -qq --physicalextentsize=4M --autobackup=n  '$vgName' '$devName'
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/bin/udevadm info --query=symlink --name=$devName
    #获取brickID,创建brick文件夹
    num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks |/host/bin/jq length`
    for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[$i] |sed 's#\"##g'`
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId
    done
    #获取brickID,创建Lv
     for ((i=0;i<${num};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .deviceentries.'"$1"'.Bricks[$i] |sed 's#\"##g'`
        poolmetadatasize=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$1"'.PoolMetadataSize`
        size=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$1"'.TpSize`
        tpName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq .brickentries.'"$1"'.LvmThinPool |sed 's#\"##g'`
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm lvcreate -qq --autobackup=n --poolmetadatasize $poolmetadatasize"K" --chunksize 256K --size $size"K" --thin $vgName/$tpName --virtualsize $size"K" --name brick_$brickId
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkfs.xfs -i size=512 -n size=8192 /dev/mapper/$vgName-brick_$brickId
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- awk "BEGIN {print \"/dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId xfs rw,inode64,noatime,nouuid 1 2\" >> \"/var/lib/heketi/fstab\"}"
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mount -o rw,inode64,noatime,nouuid /dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs
    done
}


checkPodStatus() {
    num=0
    while [ ${num} -lt 300 ]; do
        status=`/host/bin/kubectl get po -n ${NAMESPACES} $1 | grep -v READY | awk '{print $2}'`
        if [ "$status" = "1/1" ] ;then
            echo "pod：$1 glusterfs is running"
            break
        else
            echo "pod：$1 glusterfs is not running, sleep 3s.."
            sleep 3
        fi
        ((num+=1))
        if [ ${num} -ge 300 ]; then
            echo "Time out to get glusterfspods status"
            check
        fi
    done
}




checkGFSConfigLost() {
    
}

checkVGLost() {

}

checkLVLost() {

}

checkBrickLost() {

}

checkMountLost() {

}

matrixExec() {
    exitCode=`curl -X POST -k -H "X-Auth-Token:$TOKEN" -H "Content-Type:application/json" -d "{\"nodeId\":\"$3\",\"command\":\"vgremove -yf $4\"}" https://$IN_VIP:$MATRIX_SECURE_PORT/matrix/rsapi/v1.0/exec_cmd|jq .exitCode`
    sum=0
    while [ ${sum} -lt 300 ]; do
        if [[ $exitCode -ne 0 ]]; then
            sleep 60
            exitCode=`curl -X POST -k -H "X-Auth-Token:$1" -H "Content-Type:application/json" -d "{\"nodeId\":\"$3\",\"command\":\"vgremove -yf $4\"}" https://$2:${port}/matrix/rsapi/v1.0/exec_cmd|jq .exitCode`
        else 
            break
        fi
        ((sum+=1))
        if [ ${sum} -ge 300 ]; then
            echo "Time out to get the result vgremove"
            exit 1
        fi
    done
}

main() {
    while true; do 
        check
    done
}

main

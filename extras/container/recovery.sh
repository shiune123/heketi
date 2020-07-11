#!/bin/bash

#获取当前glusterfs应用所在的命名空间
NAMESPACES=`/host/bin/kubectl get po --all-namespaces |grep glusterfs |grep -v heketi | grep -v NAME | awk '{print $1}' |sed -n 1p`
TOKEN=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_TOKEN}`
IN_VIP=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_VIP}`
MATRIX_SECURE_PORT=`/host/bin/kubectl get cm -n matrix -o jsonpath={.items[0].data.MATRIX_SECURE_PORT}`
#检查当前环境是否为故障节点恢复环境
check() {
    #判断当前GlusterFS的pod的数量
    #检测当前环境中role为Master的节点数量
    if [[ $IN_VIP =~ ":" ]]; then
            IN_VIP="\[$IN_VIP\]"
    fi
    nodesInfo=`curl -k -H "X-Auth-Token:${TOKEN}" https://${IN_VIP}:${MATRIX_SECURE_PORT}/matrix/rsapi/v1.0/cluster/nodes`
    nodesNum=`echo ${nodesInfo}|jq length`
    masterNodeNumber=0
    for ((i=0;i<${nodesNum};i++)); do
        role=`echo ${nodesInfo} | jq -r .[$i].nodeBaseInfo.role`
        echo "the node role is $role"
        if [ $role == "Master" ]; then
            ((masterNodeNumber+=1))
        fi
    done
    echo "the number of master is $masterNodeNumber"
    #获取当前存在的GlusterFS的pod
    oldpodnames=`/host/bin/kubectl get po -n ${NAMESPACES} |grep glusterfs |grep -v heketi | grep -v NAME |awk '{print $2}' |tr "\n" " "`
    recovery $oldpodnames $masterNodeNumber
}



recovery() {
    #判断matrix是否已经走完故障节点恢复流程
    while true; do
        num=`/host/bin/kubectl get po -n ${NAMESPACES} |grep glusterfs |grep -v heketi | grep -v NAME |wc -l`
        if [ $res -eq $2 ]; then
            break
        fi
    done
    newPodNames=`/host/bin/kubectl get po -n ${NAMESPACES} |grep glusterfs |grep -v heketi | grep -v NAME |awk '{print $1}' |tr "\n" " "`
    podips=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep glusterfs |grep -v heketi |grep -v 'IP' |awk '{print $6}' |tr "\n" " "`
    arrayNew=($newPodNames)
    arrayOld=($1)
    newPod=""
    #获取新节点上的glusterfs的pod名称
    for newname in ${arrayNew[@]}; do
        newpod=$newname $newPod
        for oldname in ${arrayOld[@]}; do
            if [ "$oldname" = "$newname" ]; then
                newpod=""
                break
            fi
        done
    done
    oldpod=`echo ${1} |awk '{print $1}'`
    checkPodStatus $newpod
    checkGFSConfig $newpod $oldpod
    heal $newpod $podips $oldpod
}

heal() {
    #判断GlusterFS配置是否丢失，查看/var/lib/heketi
    gfsLost=`checkGFSConfigLost $1`
    #判断磁盘的vg是否丢失
    vgLost=`checkVGLost $1`
    recoveryCluster $1 $2 $3
    #恢复GlusterFS存储卷
    nodeIds=`heketi-cli node list  --user admin --secret admin  |awk '{print $1}' |tr '\n' ' '`
    nodeId=""
    for nodeId in ${nodeIds[@]}; do
        nodeId=`echo ${nodeId:3}`
        test=`heketi-cli node info $nodeId --user admin --secret admin |grep $newIp`
        if [ -n "$test" ]; then
            break
        fi
    done
    deviceIds=`heketi-cli node info $nodeId --user admin --secret admin|grep Name: |grep Id: |tr "\n" " "`
    arrayDeviceId=($deviceIds)
    for ids in ${arrayDeviceId[@]}; do
        if [ `echo "$ids"|grep Id:` ]; then
            id=`echo ${ids:3}`
            recoveryDevice $id $1
        fi
    done
    recoveryStorage $oldpod
}

recoveryCluster() {
    #恢复GlusterFS集群
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

recoveryStorage() {
    volumes=`kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume list |tr "\n" " "`
    arrayVolume=($volumes)
    for volume in ${arrayVolume[@]}; do
        kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume start $volume force
        kubectl exec -i $1 -n ${NAMESPACES} -- gluster volume heal $volume full
    done
    check
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


checkGFSConfig() {
    #修改新建节点的glusterFS的ip配置
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

checkGFSConfigLost() {

}

main() {
    while true; do 
        check
    done
}

main

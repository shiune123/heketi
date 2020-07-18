#!/bin/bash

#获取当前glusterfs应用所在的命名空间
NAMESPACES=`/host/bin/kubectl get po --all-namespaces |grep glusterfs |grep -v heketi | grep -v NAME | awk '{print $1}' |sed -n 1p`
TOKEN=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_TOKEN}`
IN_VIP=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_VIP}`
MATRIX_SECURE_PORT=`/host/bin/kubectl get cm -n matrix -o jsonpath={.items[0].data.MATRIX_SECURE_PORT}`

#检查当前环境是否为故障节点恢复环境
check() {
    nodeNames=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep glusterfs |grep 1/1 |awk '{print $7}' |tr '\n' ' '`
    #上次没有修复成功，优先修复
    notRecoveryNodeNum=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList |/host/bin/jq length`
    if [ "$notRecoveryNodeNum" -ne 0 ]; then
        for ((l=0;l<${notRecoveryNodeNum};l++)); do
            errorNode=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList[$l].nodeName |sed 's#\"##g'`
            newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep glusterfs |grep Running |grep 1/1 |grep -w $errorNode |awk '{print $1}' |grep -v 'NAME'`
            echo "[recoveryGlusterFS][INFO]not Recovery node:$errorNode"
            if [ -n "$newPod" ]; then
                setGFSConfig  $errorNode $newPod
                recoveryDevice $errorNode $newPod
                recoveryStorage $errorNode $newPod
            else
                continue
            fi

        done
    fi

    #轮询检查mouts目录和VG
    errorGFSNodes=`checkGFSConfigLost "$nodeNames"`
    errorVGNodes=`checkVGLost "$nodeNames"`
    recoveryNodes=""
    errorGFSNodesArray=($errorGFSNodes)
    errorVGNodesArray=($errorVGNodes)
    #获取errorGFSNodes和errorVGNodes的并集
    for errorGFSNode in ${errorGFSNodesArray[@]}; do
        flags=0
        for errorVGNode in ${errorGFSNodesArray[@]}; do
            if [ "$errorVGNode" = "$errorGFSNode" ];then
                recoveryNodes="$errorVGNode $recoveryNodes"
                flags=1
            fi
        done
        if [ $flags -eq 0 ]; then
            recoveryNodes="$errorGFSNode $recoveryNodes"
        fi
    done
    recoveryNodesArray=($recoveryNodes)
    for errorVGNode in ${errorVGNodesArray[@]}; do
        flags=0
        for recoveryNode in ${recoveryNodesArray[@]}; do
            if [ "$errorVGNode" = "$recoveryNode" ];then
                flags=1
            fi
        done
        if [ $flags -eq 0 ]; then
            recoveryNodes="$errorVGNode $recoveryNodes"
        fi
    done
    recoveryNodesArray=($recoveryNodes)
    #防止上一次修复的节点修复又失败
    notRecoveryNodeNum=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList |/host/bin/jq length`
    if [[ $notRecoveryNodeNum -ne 0 ]]; then
        for ((l=0;l<${notRecoveryNodeNum};l++)); do
            errorNode=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList[$l].nodeName |sed 's#\"##g'`
            flags=0
            for recoveryNode in ${recoveryNodesArray[@]}; do
                if [ "$errorNode" = "$recoveryNode" ]; then
                    flags=1
                fi
            done
            if [ $flags -eq 0 ]; then
                recoveryNodes="$errorNode $recoveryNodes"
            fi
        done
    fi
    if [ -n "$recoveryNodes" ]; then
        recoveryNodesArray=($recoveryNodes)
        echo "[recoveryGlusterFS][INFO] Recovery $recoveryNodes"
        #修复节点
        for recoveryNode in ${recoveryNodesArray[@]}; do
            echo "[recoveryGlusterFS][INFO]Recovering node:$errorGFSNode"
            notRecoveryNodeNum=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList |/host/bin/jq length`
            #防止出现重复的节点名在json文件中
            flags=0
            if [[ $notRecoveryNodeNum -ne 0 ]]; then
                for ((l=0;l<${notRecoveryNodeNum};l++)); do
                    if [ "$errorNode" = "$recoveryNode" ]; then
                        flags=1
                    fi
                done
            fi
            if [ $flags -eq 0 ]; then
                echo `cat /var/lib/heketi/recovery.json | /host/bin/jq ".nodeList +=[{\"nodeName\": \"$recoveryNode\"}]"` > /var/lib/heketi/recovery.json
            fi
            newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep Running |grep glusterfs |grep 1/1 |grep -w $recoveryNode |awk '{print $1}' |grep -v 'NAME'`
            if [ -n "$newPod" ]; then
                setGFSConfig  $recoveryNode $newPod
                recoveryDevice $recoveryNode $newPod
                recoveryStorage $recoveryNode $newPod
            else
                continue
            fi
        done
        file=`cat /var/lib/heketi/recovery.json |/host/bin/jq .nodeList |/host/bin/jq length`
        if [[ $file -ne 0 ]]; then
            echo "[recoveryGlusterFS][ERROR] Recovery failed"
        else
            echo "[recoveryGlusterFS][INFO] Recovery ok"
        fi
    else
        echo "[recoveryGlusterFS][INFO]check node ok"
    fi
}

recoveryDevice() {
    #恢复GlusterFS集群
    newIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep -w $2 |awk '{print $6}' |grep -v 'IP' `
    if [  ! -n "$newIp" ]; then
        return
    fi
    podStatus=`/host/bin/kubectl exec -i -n ${NAMESPACES} $2  -- systemctl is-active glusterd`
    if [ "$podStatus" != "active" ]; then
        return
    fi
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep 1/1 |grep glusterfs |awk '{print $1}' |grep -v 'NAME' |grep -v heketi |grep 1/1 |grep -v $2 |awk '{print $1}' |tr '\n' ' '`
    allIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep -v 'NAME' |grep glusterfs |awk '{print $6}' |tr '\n' ' '`
    gfsPodsArray=($gfsPods)
    execPod=""
    for gfsPod in ${gfsPodsArrays[@]}; do
        volumeStatus=`/host/bin/kubectl exec -i $gfsPod -n  ${NAMESPACES} -- gluster volume status |grep heketi`
        if [ -n "$volumeStatus" ]; then
            execPod=`echo $gfsPod`
            break
        fi
    done
    #获取新的GlusterFS集群的UUID
    newUUID=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- cat /var/lib/glusterd/glusterd.info |grep UUID |tr "UUID=" " " |sed 's/^[ \t]*//g'`
    #获取旧的GlusterFS集群的UUID
    oldUUID=`/host/bin/kubectl exec -i $execPod -n ${NAMESPACES} -- gluster pool list |grep $newIp |awk '{print $1}'`
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- sed -i 's/'$newUUID'/'$oldUUID'/g' /var/lib/glusterd/glusterd.info
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl restart glusterd
    ips=($allIp)
    for ip in ${ips[@]};
    do
        /host/bin/kubectl exec -i $2  -n ${NAMESPACES} -- gluster peer probe $ip
    done
    #重启Glusterfs
    restartGlusterd
    #检查GlusterFS集群是否恢复完成
    flag=0
    for ip in ${ips[@]};
    do
        sleep 5
        gfsPodName=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep $ip |awk '{print $1}' |grep -v NAME`
        peerNum=`/host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- gluster peer status |grep "Number of Peers:" |tr -cd [0-9]`
        inClusterNum=`/host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- gluster peer status |grep "Peer in Cluster" |wc -l`
        if [ ! -n "$peerNum" ]; then
            flag=1
        fi
        if [ ! -n "$inClusterNum"  ]; then
            flag=1
        fi
        if [[ $peerNum -ne $inClusterNum ]]; then
            flag=1
        fi
    done
    if [ $flag -eq 1 ]; then
        echo "[recoveryGlusterFS][ERROR]recoveryGFSCluster failed "
        return
    else
        echo "[recoveryGlusterFS][INFO]recoveryGFSCluster ok "
    fi
    gfsnodeId=`getErrorNodeId $1`
    devIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($devIds)
    matrixNodeId=`getMatrixNodeId $1`
    for dev in ${deviceArray[@]}; do
        devs=`heketi-cli device info $dev --user admin --secret admin |grep "Create Path:"`
        #获取盘符名称
        devName=`echo ${devs:13}`
        #获取vg名称
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Bricks[0]" |sed 's#\"##g'`
        vgNames=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
        pvUUID=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Info.pv_uuid" |sed 's#\"##g'`
        #删除软连接，防止vg创建失败
        vgFile=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- ls /dev |grep $vgNames`
        if [ -n "$vgFile" ]; then
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- rm -rf /dev/$vgNames
        fi
        pvs=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- pvs |grep $devName`
         #创建pv
        if [ ! -n "$pvs" ]; then
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm pvcreate -ff --metadatasize=128M --dataalignment=256K $devName --uuid $pvUUID --norestorefile
            pvs=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- pvs |grep $devName`
            if [ ! -n "$pvs" ]; then
              return
            fi
        fi
        #判断VG是否存在
        vgStatus=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- vgs |grep -w $vgNames`
        if [ ! -n "$vgStatus" ]; then
            #创建vg
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm vgcreate -qq --physicalextentsize=4M --autobackup=n  $vgNames $devName
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/bin/udevadm info --query=symlink --name=$devName
        fi
        #判断VG是否创建成功
        vgStatus=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- vgs |grep -w $vgNames`
        if [ ! -n "$vgStatus" ]; then
            echo "[recoveryGlusterFS][ERROR]recovery VG[$vgNames] failed "
            return
        fi
        #创建lv
        num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Bricks" |/host/bin/jq length`
        for ((i=0;i<${num};i++)); do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Bricks[$i]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
            poolmetadatasize=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".PoolMetadataSize"`
            size=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".TpSize"`
            tpName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".LvmThinPool" |sed 's#\"##g'`
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- /usr/sbin/lvm lvcreate -qq --autobackup=n --poolmetadatasize $poolmetadatasize"K" --chunksize 256K --size $size"K" --thin $vgName/$tpName --virtualsize $size"K" --name brick_$brickId
            sleep 2
            #检查lv是否创建成功
            cmd="lvs |grep -w brick_$brickId"
            exitCode=`matrixExec "$matrixNodeId" "$cmd"`
            if [ $exitCode -ne 0 ]; then
                echo "[recoveryGlusterFS][ERROR] Recovery LV[brick_$brickId] failed"
                return
            else
                echo "[recoveryGlusterFS][INFO] Recovery LV[brick_$brickId] ok"
            fi
            #创建glusterfs的brick的文件夹
            /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId
            #挂载LV到brick目录中
            status=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- df -h |grep /dev/mapper/$vgName-brick_$brickId`
            if [ ! -n "$status"  ]; then
                #格式化LV
                /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkfs.xfs -i size=512 -n size=8192 /dev/mapper/$vgName-brick_$brickId
                /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mount -o rw,inode64,noatime,nouuid /dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId
            fi
            sleep 2
            status=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- df -h |grep /dev/mapper/$vgName-brick_$brickId`
            if [ -n "$status"  ]; then
                #创建/brick/.glusterfs，供后续存储数据恢复
                /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs
                #持久化挂载点信息
                /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- touch /var/lib/heketi/fstab
                cmd="cat /var/lib/heketi/fstab |grep brick_$brickId"
                exitCode=`matrixExec "$matrixNodeId" "$cmd"`
                if [ $exitCode -ne 0  ]; then
                    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- awk "BEGIN {print \"/dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId xfs rw,inode64,noatime,nouuid 1 2\" >> \"/var/lib/heketi/fstab\"}"
                fi
            fi
        done
    done
}

restartGlusterd() {
    allIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep -v 'NAME' |grep glusterfs |awk '{print $6}' |tr '\n' ' '`
    ips=($allIp)
    for ip in ${ips[@]};
    do
        sleep 5
        gfsPodName=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep $ip |awk '{print $1}' |grep -v NAME`
        /host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- systemctl restart glusterd
    done
}

getMatrixNodeId() {
    if [[ $IN_VIP =~ ":" ]]; then
        IN_VIP="\[$IN_VIP\]"
    fi
    nodesInfo=`curl -k -H "X-Auth-Token:${TOKEN}" https://${IN_VIP}:${MATRIX_SECURE_PORT}/matrix/rsapi/v1.0/cluster/nodes`
    nodesNum=`echo ${nodesInfo} |/host/bin/jq length`
    for ((i=0;i<${nodesNum};i++)); do
        nodeName=`echo ${nodesInfo} |/host/bin/jq -r .[$i].nodeBaseInfo.nodeName`
        if [ "$nodeName" = "$1" ]; then
            echo ${nodesInfo} |/host/bin/jq -r .[$i].nodeId
            break
        fi
    done
}

#获取错误节点的nodeID
#param：nodeIName string
#return：nodeID string
getErrorNodeId() {
    nodeIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'IP' |grep glusterfs |grep -w $1 |awk '{print $6}'`
    nodeIds=`heketi-cli node list  --user admin --secret admin  |awk '{print $1}' |tr '\n' ' '`
    nodeId=""
    for nodeId in ${nodeIds[@]}; do
        nodeId=`echo ${nodeId:3}`
        test=`heketi-cli node info $nodeId --user admin --secret admin |grep $nodeIp`
        if [ -n "$test" ]; then
            break
        fi
    done
    echo $nodeId  |tr '\n' ' '
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
            deviceIds="$id $deviceIds"
        fi
    done
    echo $deviceIds  |tr '\n' ' '
}

#获取错误节点的brickIds
#param：deviceId string
#return：brickIds string to array
getErrorBrickId() {
    brickNum=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$1\".Bricks" |/host/bin/jq length`
    brickIds=""
    for ((i=0;i<${brickNum};i++)); do
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$1\".Bricks[$i]" |sed 's#\"##g'`
        brickIds="$brickId $brickIds"
    done
    echo $brickIds |tr '\n' ' '
}

#恢复用户自定义配置
#param：errorNodePodName string
#return：null
setGFSConfig() {
    #修改新建节点的glusterFS的ip配置，默认配置为ipv4
    nodeips=`/host/bin/kubectl get po  -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep glusterfs |awk '{print $6}' |tr '\n' ' '`
    #优先判断当前pod是否正常running
    podStatus=`/host/bin/kubectl exec -i -n ${NAMESPACES} $2  -- systemctl is-active glusterd`
    if [ "$podStatus" != "active" ]; then
        return
    fi
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep 1/1 |grep -v $2 |awk '{print $1}' |grep -v 'NAME' |grep glusterfs |tr '\n' ' '`
    ip=`echo ${nodeips} |awk '{print $1}'`
    if [[ $ip =~ "." ]]; then
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- sed -i 's/    option transport.address-family inet6/#   option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl restart glusterd
    elif [[ $ip =~ ":" ]]; then
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- sed -i 's/#   option transport.address-family inet6/    option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl restart glusterd
    fi
    #修改定制占用端口数的配置
    gfsPodsArrays=($gfsPods)
    execPod=""
    for gfsPod in ${gfsPodsArrays[@]}; do
        volumeStatus=`/host/bin/kubectl exec -i $gfsPod -n  ${NAMESPACES} -- gluster volume status |grep heketi`
        if [ -n "$volumeStatus" ]; then
            execPod=`echo $gfsPod`
            break
        fi
    done
    port=`/host/bin/kubectl exec -i $execPod -n ${NAMESPACES} -- cat /etc/glusterfs/glusterd.vol |grep "option max-port" | tr -cd "[0-9]"`

    if [ "$port" != "49352" ]; then
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- sed -i 's/    option max-port  49352/    option max-port  $port/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl restart glusterd
    fi
}

#恢复GlusterFS存储数据
#param：errorNodePodName string
#return：null
recoveryStorage() {
    #优先判断当前pod是否正常running
    podStatus=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES}  -- systemctl is-active glusterd`
    if [ "$podStatus" != "active"  ]; then
        return
    fi
    flag=0
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep glusterfs |grep 1/1 |grep -v $2 |awk '{print $1}' |grep -v 'NAME' | tr '\n' ' '`
    gfsPodsArrays=($gfsPods)
    nomalPod=""
    for gfsPod in ${gfsPodsArrays[@]}; do
        volumeStatus=`/host/bin/kubectl exec -i $gfsPod -n  ${NAMESPACES} -- gluster volume status |grep heketi`
        if [ -n "$volumeStatus" ]; then
            nomalPod=`echo $gfsPod`
            break
        fi
    done
    volumes=`/host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume list |tr "\n" " "`
    arrayVolume=($volumes)
    flags=0
    for volume in ${arrayVolume[@]}; do
        /host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume start $volume force
        healStatus=`/host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume heal $volume full |grep "been unsuccessfull"`
        if [ -n "$healStatus" ]; then
            flags=1
        fi
    done
    sleep 5
    #保证glusterfs确定能完成恢复
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl stop glusterfsd
    /host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- systemctl restart glusterd
    #检查是否开始恢复
    gfsnodeId=`getErrorNodeId $1`
    gfDevIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($gfDevIds)
    for devId in ${deviceArray[@]}; do
        num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks" |/host/bin/jq length`
        for ((i=0;i<${num};i++)); do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks[$i]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
            #查看.glusterfs文件夹中是否有文件存在
            file=`/host/bin/kubectl exec -i $2 -n ${NAMESPACES} -- ls /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs`
            if [ ! -n "$file" ]; then
                flag=1
            fi
        done
    done
    if [ $flag -eq 0 -a $flags -eq 0 ]; then
        echo `cat /var/lib/heketi/recovery.json | /host/bin/jq ".nodeList -=[{\"nodeName\": \"$1\"}]"` > /var/lib/heketi/recovery.json
    fi
}

checkGFSConfigLost() {
    nodeNameArray=($1)
    errorNodeName=""
    cmd="ls /var/lib/heketi |grep -w mounts"
    for nodeName in ${nodeNameArray[@]}; do
        nodeId=`getMatrixNodeId "$nodeName"`
        exitCode=`matrixExec "$nodeId" "$cmd"`
        if [[ $exitCode -ne 0 ]]; then
            errorNodeName="$nodeName $errorNodeName"
        fi
    done
    echo $errorNodeName
}

checkVGLost() {
    nodeNameArray=($1)
    errorNodeName=""
    for nodeName in ${nodeNameArray[@]}; do
        podIP=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep glusterfs |grep $nodeName |awk '{print $6}'`
        nodeId=`getErrorNodeId "$nodeName"`
        deviceIds=`getErrorDeviceId $nodeId`
        deviceArray=($deviceIds)
        for deviceId in ${deviceArray[@]}; do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"${deviceId}\".Bricks[0]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"${brickId}\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
            nodeId=`getMatrixNodeId "$nodeName"`
            cmd="vgs |grep -w $vgName"
            exitCode=`matrixExec "$nodeId" "$cmd"`
            if [[ $exitCode -ne 0 ]]; then
                errorNodeName="$nodeName $errorNodeName"
                break
            fi
        done
    done
    echo $errorNodeName
        
}

matrixExec() {
    if [[ $IN_VIP =~ ":" ]]; then
            IN_VIP="\[$IN_VIP\]"
    fi
    exitCode=`curl -X POST  -k -H  "X-Auth-Token:$TOKEN" -H "Content-Type:application/json" -d "{\"nodeId\":\"$1\",\"command\":\"$2\"}" https://$IN_VIP:$MATRIX_SECURE_PORT/matrix/rsapi/v1.0/exec_cmd |/host/bin/jq .exitCode`
    if [ ! -n "$exitCode" ]; then
        exitCode=0
    fi
    echo $exitCode
}

main() {
    if [ ! -f "/var/lib/heketi/recovery.json" ]; then
      touch /var/lib/heketi/recovery.json
      cat>/var/lib/heketi/recovery.json<<EOF
{
    "nodeList": [
    ]
}
EOF
    fi
    while true; do
        sleep 60
        check
    done
}

main

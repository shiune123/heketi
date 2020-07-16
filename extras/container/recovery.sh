#!/bin/bash

#获取当前glusterfs应用所在的命名空间
NAMESPACES=`/host/bin/kubectl get po --all-namespaces |grep glusterfs |grep -v heketi | grep -v NAME | awk '{print $1}' |sed -n 1p`
TOKEN=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_TOKEN}`
IN_VIP=`/host/bin/kubectl get configmap -n matrix -o jsonpath={.items[0].data.MATRIX_INTERNAL_VIP}`
MATRIX_SECURE_PORT=`/host/bin/kubectl get cm -n matrix -o jsonpath={.items[0].data.MATRIX_SECURE_PORT}`

#检查当前环境是否为故障节点恢复环境
check() {
    nodeNames=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep glusterfs |grep 1/1 |awk '{print $7}' |tr '\n' ' '`
    #需要修复Gluster集群及自定义配置
    errorCluster=`cat /var/lib/heketi/recoveryCluster.txt`
    if [ -n "$errorCluster" ]; then
        echo "[recoveryGlusterFS][INFO]not Recovery node:$errorCluster"
        checkGFSConfig $errorCluster
        recoveryGFSCluster $errorCluster
        checkGFSCluster $errorCluster
    fi
    errorNodes=`checkGFSConfigLost "$nodeNames"`
    echo "[recoveryGlusterFS][INFO]LostGFS:$errorNodes"
    errorNodesarray=($errorNodes)
    for errorNode in ${errorNodesarray[@]}; do
        #恢复GlusterFS配置
        if [ -n "$errorNode"  ]; then
            echo "$errorNode">/var/lib/heketi/recoveryCluster.txt
            checkGFSConfig $errorNode
            recoveryGFSCluster $errorNode
            checkGFSCluster $errorNode
        fi
    done

    errorVGs=`checkVGLost "$nodeNames"`
    echo "[recoveryGlusterFS][INFO]LostVG:$errorVGs"
    errorVGsarray=($errorVGs)
    for errorVG in ${errorVGsarray[@]}; do
        #恢复VG
        if [ -n "$errorVG" ]; then
            recoveryVG $errorVG
        fi
    done

    errorLVs=`checkLVLost "$nodeNames"`
    echo "[recoveryGlusterFS][INFO]LostLV:$errorLVs"
    errorLVsarray=($errorLVs)
    echo $errorLVs
    for errorLV in ${errorLVsarray[@]}; do
        #恢复LV
        echo $errorLV
        if [ -n "$errorLV" ]; then
            recoveryLV $errorLV
        fi
    done

    errors=`cat /var/lib/heketi/recoveryBrick.txt`
    if [ -n "$errors" ]; then
        echo "[recoveryGlusterFS][INFO]not Recovery brick:$errors"
        recoveryBrickFile $errors
        recoveryMount $errors
        recoveryStorage $errors
    fi
    errorBricks=`checkBrickLost "$nodeNames"`
    echo "[recoveryGlusterFS][INFO]LostBricks:$errorBricks"
    errorBricksArray=($errorBricks)
    for errorBrick in ${errorBricksArray[@]}; do
        #恢复目录
        if [ -n "$errorBrick" ]; then
            echo "$errorBrick" >/var/lib/heketi/recoveryBrick.txt
            recoveryBrickFile $errorBrick
            recoveryMount $errorBrick
            recoveryStorage $errorBrick
        fi
    done
    echo "[recoveryGlusterFS][INFO] Recovery ok"
}

checkGFSCluster() {
    flag=0
    iplist=($1)
    for ip in ${iplist[@]};
    do
        sleep 5
        gfsPodName=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep $ip |awk '{print $1}' |grep -v NAME`
        peerNum=`/host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- gluster peer status |grep "Number of Peers:" |tr -cd [0-9]`
        inClusterNum=`/host/bin/kubectl exec -i $gfsPodName  -n ${NAMESPACES} -- gluster peer status |grep "Peer in Cluster" |wc -l`
        if [ $peerNum -ne $inClusterNum ]; then
            flag=1
        fi
    done
    if [ $flag -eq 0 ]; then
        echo "">/var/lib/heketi/recoveryCluster.txt
    fi
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
    checkGFSCluster $allIp
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

#恢复GlusterFS集群
#param：errorNodeName string
#return：null
recoveryGFSCluster() {
    newIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'IP' |grep glusterfs |grep -w $1 |awk '{print $6}'`
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'IP' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep -v 'NAME' |grep glusterfs |grep -v heketi |grep 1/1 |grep -v $newPod |awk '{print $1}' |tr '\n' ' '`
    allIp=`/host/bin/kubectl get po -n ${NAMESPACES} -owide --selector="glusterfs-node" |grep -v 'NAME' |grep glusterfs |awk '{print $6}' |tr '\n' ' '`
    gfsPodsArray=($gfsPods)
    execPod=`echo ${gfsPods} |awk '{print $1}'`
    newUUID=`/host/bin/kubectl exec -i $newPod  -n ${NAMESPACES} -- cat /var/lib/glusterd/glusterd.info |grep UUID |tr "UUID=" " " |sed 's/^[ \t]*//g'`
    oldUUID=`/host/bin/kubectl exec -i $execPod -n ${NAMESPACES} -- gluster pool list |grep $newIp |awk '{print $1}'`
    /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- sed -i 's/'$newUUID'/'$oldUUID'/g' /var/lib/glusterd/glusterd.info
    /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- systemctl restart glusterd
    ips=($allIp)
    for ip in ${ips[@]};
    do
        /host/bin/kubectl exec -i $newPod  -n ${NAMESPACES} -- gluster peer probe $ip
    done
    restartGlusterd
}

#恢复用户自定义配置
#param：errorNodePodName string
#return：null
checkGFSConfig() {
    #修改新建节点的glusterFS的ip配置，默认配置为ipv4
    nodeips=`/host/bin/kubectl get po  -n ${NAMESPACES} -owide |grep glusterfs |grep -v heketi |awk '{print $6}' |tr '\n' ' '`
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'NAME' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep -v 'NAME' |grep glusterfs |grep -v heketi |grep 1/1 |grep -v $newPod |awk '{print $1}' |tr '\n' ' '`
    ip=`echo ${nodeips} |awk '{print $1}'`
    if [[ $ip =~ "." ]]; then
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- sed -i 's/    option transport.address-family inet6/#   option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- systemctl restart glusterd
    elif [[ $ip =~ ":" ]]; then
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- sed -i 's/#   option transport.address-family inet6/    option transport.address-family inet6/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- systemctl restart glusterd
    fi
    #修改定制占用端口数的配置
    execPod=`echo $gfsPods |awk '{print $1}'`
    port=`/host/bin/kubectl exec -i $execPod -n ${NAMESPACES} -- cat /etc/glusterfs/glusterd.vol |grep "option max-port" | tr -cd "[0-9]"`
    if [ "$port" != "49352" ]; then
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- sed -i 's/    option max-port  49352/    option max-port  $port/g' /etc/glusterfs/glusterd.vol
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- systemctl restart glusterd
    fi
}

#恢复Device的VG
#param：errorNodePodName string
#return：null
recoveryVG() {
    gfsnodeId=`getErrorNodeId $1`
    devIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($devIds)
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'IP' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep -v 'IP' |grep glusterfs |grep 1/1 |grep -v $newPod |awk '{print $1}' |tr '\n' ' '`
    for dev in ${deviceArray[@]}; do
        devs=`heketi-cli device info $dev --user admin --secret admin |grep "Create Path:"`
        #获取盘符名称
        devName=`echo ${devs:13}`
        #获取vg名称
        brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Bricks[0]" |sed 's#\"##g'`
        vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
        pvUUID=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$dev\".Info.pv_uuid" |sed 's#\"##g'`
        #删除软连接，防止vg创建失败
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- ls /dev |grep $vgName
        if [ $? -eq 0 ]; then
            /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- rm -rf /dev/$vgName
        fi
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- pvs |grep $devName
        if [ $? -ne 0 ]; then
             #创建pv
            /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- /usr/sbin/lvm pvcreate -ff --metadatasize=128M --dataalignment=256K $devName --uuid $pvUUID --norestorefile
            pvs=`/host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- pvs |grep $devName`
            if [ ! -n "$pvs" ]; then
              return
            fi
        fi
        #创建vg
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- /usr/sbin/lvm vgcreate -qq --physicalextentsize=4M --autobackup=n  $vgName $devName
        /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- /usr/bin/udevadm info --query=symlink --name=$devName
    done
}

#恢复VG的LV
recoveryLV() {
    #获取brickId，创建brick文件夹
    gfsnodeId=`getErrorNodeId $1`
    gfsDevIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($gfsDevIds)
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'IP' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    for devId in ${deviceArray[@]}; do
        echo $devId
        num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks" |/host/bin/jq length`
        for ((i=0;i<${num};i++)); do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks[$i]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
            poolmetadatasize=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".PoolMetadataSize"`
            size=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".TpSize"`
            tpName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".LvmThinPool" |sed 's#\"##g'`
            #删除brick目录触发修复brick
            /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- rm -rf  /var/lib/heketi/mounts/$vgName/brick_$brickId
            /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- /usr/sbin/lvm lvcreate -qq --autobackup=n --poolmetadatasize $poolmetadatasize"K" --chunksize 256K --size $size"K" --thin $vgName/$tpName --virtualsize $size"K" --name brick_$brickId
        done
    done
}

#恢复brick文件夹
recoveryBrickFile() {
    #获取brickId，创建brick文件夹
    gfsnodeId=`getErrorNodeId $1`
    gfDevIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($gfDevIds)
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide  |grep -v 'NAME' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    for devId in ${deviceArray[@]}; do
        num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks" |/host/bin/jq length`
        for ((i=0;i<${num};i++)); do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks[$i]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
            /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId
        done
    done
}

#恢复LV的挂载
recoveryMount() {
    #获取brickID
    gfsnodeId=`getErrorNodeId $1`
    gfDevIds=`getErrorDeviceId $gfsnodeId`
    deviceArray=($gfDevIds)
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide  |grep -v 'NAME' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    for devId in ${deviceArray[@]}; do
    num=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks" |/host/bin/jq length`
        for ((i=0;i<${num};i++)); do
            brickId=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".deviceentries.\"$devId\".Bricks[$i]" |sed 's#\"##g'`
            vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`

             #挂载LV到brick目录中
            status=`/host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- df -h |grep /dev/mapper/$vgName-brick_$brickId`
            if [ ! -n "$status"  ]; then
                #格式化LV
                /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- mkfs.xfs -i size=512 -n size=8192 /dev/mapper/$vgName-brick_$brickId
                /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- mount -o rw,inode64,noatime,nouuid /dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId
            fi
            sleep 2
            status=`/host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- df -h |grep /dev/mapper/$vgName-brick_$brickId`
            if [ -n "$status"  ]; then
                #创建/brick/.glusterfs，供后续存储数据恢复
                /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- mkdir -p /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs
                #持久化挂载点信息
                /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- touch /var/lib/heketi/fstab
                cmd="cat /var/lib/heketi/fstab |grep brick_$brickId"
                matrixNodeId=`getMatrixNodeId $1`
                exitCode=`matrixExec "$matrixNodeId" "$cmd"`
                if [ $exitCode -ne 0  ]; then
                    /host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- awk "BEGIN {print \"/dev/mapper/$vgName-brick_$brickId /var/lib/heketi/mounts/$vgName/brick_$brickId xfs rw,inode64,noatime,nouuid 1 2\" >> \"/var/lib/heketi/fstab\"}"
                fi
            fi
        done
    done
}

#恢复GlusterFS存储数据
#param：errorNodePodName string
#return：null
recoveryStorage() {
    newPod=`/host/bin/kubectl get po -n ${NAMESPACES} -owide |grep -v 'NAME' |grep glusterfs |grep -w $1 |awk '{print $1}'`
    gfsPods=`/host/bin/kubectl get po -n ${NAMESPACES} |grep -v 'IP' |grep glusterfs |grep 1/1 |grep -v $newPod |awk '{print $1}' |tr '\n' ' '`
    nomalPod=`echo $gfsPods |awk '{print $1}'`
    volumes=`/host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume list |tr "\n" " "`
    arrayVolume=($volumes)
    for volume in ${arrayVolume[@]}; do
        /host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume start $volume force
        /host/bin/kubectl exec -i $nomalPod -n ${NAMESPACES} -- gluster volume heal $volume full
    done
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
            file=`/host/bin/kubectl exec -i $newPod -n ${NAMESPACES} -- ls /var/lib/heketi/mounts/$vgName/brick_$brickId/brick/.glusterfs`
            if [ -n "$file" ]; then
                echo "" >/var/lib/heketi/recoveryBrick.txt
            fi
        done
    done
}

checkGFSConfigLost() {
    nodeNameArray=($1)
    errorNodeName=""
    cmd="ls /var/lib/heketi |grep -w mounts"
    for nodeName in ${nodeNameArray[@]}; do
        nodeId=`getMatrixNodeId "$nodeName"`
        exitCode=`matrixExec "$nodeId" "$cmd"`
        if [ $exitCode -ne 0 ]; then
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
            if [ $exitCode -ne 0 ]; then
                errorNodeName="$nodeName $errorNodeName"
                break
            fi
        done
    done
    echo $errorNodeName
        
}

checkLVLost() {
    nodeNameArray=($1)
    errorNodeName=""
    for nodeName in ${nodeNameArray[@]}; do
        nodeId=`getErrorNodeId $nodeName`
        deviceIds=`getErrorDeviceId $nodeId`
        deviceArray=($deviceIds)
        for deviceId in ${deviceArray[@]}; do
            brickIds=`getErrorBrickId $deviceId`
            brickIdArray=($brickIds)
            for brickId in ${brickIdArray[@]}; do
                matrixNodeId=`getMatrixNodeId $nodeName`
                cmd="lvs |grep -w brick_$brickId"
                exitCode=`matrixExec "$matrixNodeId" "$cmd"`
                if [ $exitCode -ne 0 ]; then
                    errorNodeName="$nodeName $errorNodeName"
                    break
                fi
            done
        done
    done
    echo $errorNodeName
}

checkBrickLost() {
    nodeNameArray=($1)
    errorNodeName=""
    for nodeName in ${nodeNameArray[@]}; do
        nodeId=`getErrorNodeId $nodeName`
        deviceIds=`getErrorDeviceId $nodeId`
        matrixNodeId=`getMatrixNodeId $nodeName`
	      deviceArray=($deviceIds)
        for deviceId in ${deviceArray[@]}; do
            brickIds=`getErrorBrickId $deviceId`
            brickIdArray=($brickIds)
            for brickId in ${brickIdArray[@]}; do
                vgName=`heketi-cli db dump --user admin --secret admin |/host/bin/jq ".brickentries.\"$brickId\".Info.path" |sed -r "s/.*"mounts"(.*)"brick_".*/\1/"| sed 's#/##g'`
                cmd="ls /var/lib/heketi/mounts/$vgName |grep -w brick_$brickId"
                exitCode=`matrixExec "$matrixNodeId" "$cmd"`
                if [ $exitCode -ne 0  ]; then
                    errorNodeName="$nodeName $errorNodeName"
                    break
                fi
                cmd="cat /var/lib/heketi/fstab |grep brick_$brickId"
                exitCode1=`matrixExec "$matrixNodeId" "$cmd"`
                if [ $exitCode1 -ne 0  ]; then
                    errorNodeName="$nodeName $errorNodeName"
                    break
                fi
            done
        done
    done
    echo $errorNodeName
}


matrixExec() {
    if [[ $IN_VIP =~ ":" ]]; then
            IN_VIP="\[$IN_VIP\]"
    fi
    exitCode=`curl -X POST  -k -H  "X-Auth-Token:$TOKEN" -H "Content-Type:application/json" -d "{\"nodeId\":\"$1\",\"command\":\"$2\"}" https://$IN_VIP:$MATRIX_SECURE_PORT/matrix/rsapi/v1.0/exec_cmd |/host/bin/jq .exitCode`
    echo $exitCode
}

main() {
    if [ ! -f "/var/lib/heketi/recoveryCluster.txt" ]; then
      touch /var/lib/heketi/recoveryCluster.txt
      echo "" >/var/lib/heketi/recoveryCluster.txt
    fi
    if [ ! -f "/var/lib/heketi/recoveryBrick.txt" ]; then
      touch /var/lib/heketi/recoveryBrick.txt
      echo "" >/var/lib/heketi/recoveryBrick.txt
    fi
    while true; do
        sleep 60
        check
    done
}

main

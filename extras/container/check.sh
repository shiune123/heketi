#!/bin/bash
set -x
status=`curl http://localhost:8080/hello`
count=`ps -ef |grep /usr/bin/recovery.sh |grep -v "grep" |wc -l`
if [ "${status}" != "Hello from Heketi" -o $count -eq 0 ]; then
  exit 1
fi



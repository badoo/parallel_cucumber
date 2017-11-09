#!/bin/bash
trap "exit" INT TERM
trap "kill 0" EXIT

cd ${0%%/*}
echo $0 ${0%/*}
ruby -e "require '${0%/*}/skanky_redis'; SkankyRedis.new.start(6379); sleep 60*60" &
REDIS_PID=$!

# bundle exec parallel_cucumber ${0%/*}/features --queue-connection-params redis://127.0.0.1:6379,skanky
bundle exec parallel_cucumber ${0%/*}/features --pre-batch-check 'echo precmd:retry-after-$(date +%S | cut -c2 | tr -d 6789)-seconds' --queue-connection-params redis://127.0.0.1:6379,skanky

kill -9 $REDIS_PID


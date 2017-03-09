#!/bin/bash

set -e
set -u
set -x

readonly namespace="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
readonly service_domain="_$SERVICE_PORT._tcp.$SERVICE.$namespace.svc.cluster.local"
readonly sentinel_domain="_$SENTINEL_PORT._tcp.$SENTINEL.$namespace.svc.cluster.local"

redis_info () {
  set +e
  timeout 10 redis-cli -h "$1" -a "$service_domain" info replication
  set -e
}

reset_sentinel () {
  set +e
  timeout 10 redis-cli -h "$1" -p 26379 sentinel reset mymaster
  set -e
}

redis_info_role () {
  echo "$1" | grep -e '^role:' | cut -d':' -f2 | tr -d '[:space:]'
}

domain_ip () {
  dig +noall +answer a "$1" | head -1 | awk -F' ' '{print $NF}'
}

server_domains () {
  dig +noall +answer srv "$1" | awk -F' ' '{print $NF}' | sed 's/\.$//g'
}

# At the end of the (succeeded) script, resetting all sentinels is necessary.
# This updates the list of supervised slaves.
# If this task is omitted, the number of "supervised" slaves continues to
# increase because sentinels are unable to recognize the recovered slave
# is the same slave as the dead one.
# Kubernetes may change Pod's IP address on restart.
reset_all_sentinels () {
  local -r servers="$(server_domains "$sentinel_domain")"
  local s
  >&2 echo "Resetting all sentinels: $servers"
  for s in $servers; do
    local s_ip="$(domain_ip "$s")"

    if [ -z "$s_ip" ]; then
      >&2 echo "Failed to resolve: $s"
      continue
    fi

    # Ignoring failed sentinels are allowed, since most of the sentinels are
    # expected to be alive.
    reset_sentinel "$s_ip"
  done
}

slave_priority () {
  local -r no="$(echo "$(hostname)" | sed -e 's/^.\+-\([0-9]\+\)$/\1/g')"
  local -r priority="$(echo "($no + 1) * 10" | bc)"
  echo "slave-priority $priority"
}

# It's okay to fail during failover or other unpredictable states.
# This prevents from making things much worse.
run () {
  cp /redis.template.conf /opt/redis.conf

  # Domain name of the Service is also used as the password.
  # In this case, password is just an ID to distinguish this replica set from
  # other ones in the same Kubernetes cluster.
  echo "masterauth $service_domain" >> /opt/redis.conf
  echo "requirepass $service_domain" >> /opt/redis.conf

  # Replica with smaller number should be the preferred candidate for Master
  # over ones with larger number.
  # This is because replicas with larger number have higher chance of being
  # removed by reducing the number of replica in a StatefulSet.
  slave_priority >> /opt/redis.conf

  # Headless Service allows newly added Redis server to scan all working servers.
  # This enables it to find if it is the first one.
  local -r servers="$(server_domains "$service_domain")"
  local -r my_host="$(hostname -f)"

  local master_ip=''

  local only_server=true
  local s
  for s in $servers; do
    # My hostname must be excluded to handle restarts.
    if [ "$s" = "$my_host" ]; then
      continue
    fi

    only_server=false

    local s_ip="$(domain_ip "$s")"

    if [ -z "$s_ip" ]; then
      >&2 echo "Failed to resolve: $s"
      continue
    fi

    local i="$(redis_info "$s_ip")"
    if [ -n "$i" ]; then
      if [ "$(redis_info_role "$i")" = 'master' ]; then
        master_ip="$s_ip"
      fi
    else
      >&2 echo "Unable to get Replication INFO: $s ($s_ip)"
      continue
    fi
  done

  if [ "$only_server" = true ]; then
    # This is an exceptional case: if this is the first server to start in the
    # replica, this must be run as Master.
    # Otherwise the StatefulSet will be unable to start.
    reset_all_sentinels
    exit 0
  fi

  # Now the Master server has been found, this server will be launched as
  # the slave of the Master.
  echo "slaveof $master_ip 6379" >> /opt/redis.conf
  reset_all_sentinels
  exit 0
}

run

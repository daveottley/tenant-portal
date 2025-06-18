#!/usr/bin/env bash
# infra/scripts/rebuild_server.sh
# Rebuild "tenant-portal" droplet in ATL1, attach to firewall, push Ansible

set -euo pipefail

# detect --dry-run flag
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

run() {					# dry-run wrapper
  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    "$@"
  fi
}

######################### USER CONFIG ########################################
DROPLET_NAME="tenant-portal"		# <-- name DigitalOcean will see
REGION="atl1"
SIZE="s-1vcpu-1gb-amd"
IMAGE="ubuntu-24-04-x64"

SSH_USER="daveottley"
PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"

INFRA_HOME="$HOME/projects/tenant-portal/infra"
PLAYBOOK="$INFRA_HOME/site.yml"
INVENTORY="$INFRA_HOME/inventory.ini"

FIREWALL_ID="dc582fab-0943-4c6a-8b08-293937e1e7aa"
ATTACH_FIREWALL=1			# set to 0 to skip

RESERVED_IP="134.199.132.165"	# DO Reserved IPv4 Address
ASSIGN_FLOATING_IP=1		     # set to 0 to skip Floating IP assignment
##############################################################################


PUBKEY=$(<"$PUBKEY_FILE")
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# cloud-init snippet: create your non-root user
cat >"$workdir/user-data.yml" <<EOF
#cloud-config
package_update: false
package_upgrade: false
package_reboot_if_required: false

users:
  - name: $SSH_USER
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
ssh_pwauth: false
disable_root: true
EOF

echo ">>> Deleting *all* droplets named $DROPLET_NAME ..."
# gather IDs (safe in dry-run)
DROPLET_IDS=$(doctl compute droplet list --format ID,Name --no-header \
	| awk -v n="$DROPLET_NAME" '$2==n{print $1}')
if [[ -z "$DROPLET_IDS" ]]; then
  echo ">>> No existing droplets named $DROPLET_NAME"
else
  for id in $DROPLET_IDS; do
    run doctl compute droplet delete "$id" --force
  done
fi

echo ">>> Creating droplet $DROPLET_NAME in $REGION ..."
SSH_KEYS=$(doctl compute ssh-key list --format FingerPrint --no-header | paste -sd, -)
CREATE_CMD=(
  doctl compute droplet create "$DROPLET_NAME" \
  --region "$REGION" \
  --size   "$SIZE" \
  --image  "$IMAGE" \
  --ssh-keys "$SSH_KEYS" \
  --user-data-file "$workdir/user-data.yml" \
  --tag-names "$DROPLET_NAME,tenant-portal" \
  --wait --format ID --no-header
)

if [[ "$DRY_RUN" == 1 ]]; then
  # join all args with spaces, then print once
  printf 'DRY-RUN: %s\n' "${CREATE_CMD[*]}"
  DROPLET_ID="DRYRUN_ID"
else
  DROPLET_ID=$("${CREATE_CMD[@]}")
fi

# -- wait for all provisioning actions to finish --
if [[ "$DRY_RUN" == 0 ]]; then
  echo ">>> Waiting for all Droplet actions to finish ..."
  until ! doctl compute droplet-action list "$DROPLET_ID" \
  	    | tail -n +2 \
	    | awk '{print $2}' \
	    | grep -q in-progress; do
    sleep 5
  done
fi

# -- assign your reserved Floating IP to the new droplet --
if [[ "$ASSIGN_FLOATING_IP" == 1 ]]; then
  echo ">>> Assigning reserved IP $RESERVED_IP to droplet $DROPLET_ID ..."
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: doctl compute floating-ip-action assign $RESERVED_IP $DROPLET_ID"
  else
    # retry on "pending event" until DO accepts the assignment
    until doctl compute floating-ip-action assign "$RESERVED_IP" "$DROPLET_ID" &>/dev/null; do
      echo ">>> Floating IP assignment pending, retrying in 5s..."
      sleep 5
    done

    # wait for the assignment action to complete
    echo ">>> Waiting for the Floating IP assignment to complete..."
    until ! doctl compute floating-ip-action list "$RESERVED_IP" \
	    | tail -n +2 | awk '{print $2}' | grep -q in-progress; do
      sleep 5
    done
  fi
  IP="$RESERVED_IP"
else
  echo ">>> Fetching Public IP ..."
  if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY-RUN: doctl compute droplet get $DROPLET_ID --format PublicIPv4 --no-header"
    IP="0.0.0.0"
  else
    IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
  fi
fi

echo ">>> Droplet is up at $IP"

if [[ "$ATTACH_FIREWALL" == 1 ]]; then
  echo ">>> Attaching droplet to firewall $FIREWALL_ID ..."
  run doctl compute firewall add-droplets "$FIREWALL_ID" --droplet-ids "$DROPLET_ID"
fi

echo ">>> Seeding known_hosts ..."
run ssh-keyscan -H "$IP" > ~/.ssh/known_hosts 2>/dev/null || true

echo ">>> Waiting for SSH on $SSH_USER@$IP ..."
until run ssh \
   -o BatchMode=yes \
   -o ConnectTimeout=3 \
   -o StrictHostKeyChecking=no \
   -o UserKnownHostsFile=/dev/null \
   "$SSH_USER@$IP" 'echo OK' &>/dev/null; do
  sleep 5
done

echo ">>> Running Ansible playbook ..."
# define a host called 'portal' 
run ansible-playbook "$PLAYBOOK" \
  -i "$INVENTORY" \
  -u "$SSH_USER" \
  --ssh-extra-args "-o StrictHostKeyChecking=no"

echo ">>> Success! ssh $SSH_USER@$IP"

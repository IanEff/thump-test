#!/bin/bash
# thump-test — node-bootstrap.sh.tpl
# Rendered by Tofu's templatefile() (compute.tf) into each worker instance's
# metadata_startup_script. Same thin-wrapper shape as
# control-plane-bootstrap.sh.tpl — write the env file, clone the repo, hand
# off to the real (untemplated, plain-bash) provisioning/scripts/node.sh.
set -euo pipefail

cat > /etc/thump-test.env <<'ENVEOF'
CONTROL_PLANE_INTERNAL_IP=${control_plane_internal_ip}
K3S_TOKEN=${k3s_token}
K3S_CHANNEL=${k3s_channel}
GITOPS_REPO_URL=${gitops_repo_url}
GITOPS_REPO_TOKEN=${gitops_repo_token}
ENVEOF
chmod 600 /etc/thump-test.env

%{ if gitops_ssh_key_content != "" }
mkdir -p /root/.ssh
cat > /root/.ssh/deploy_key <<'KEYEOF'
${gitops_ssh_key_content}
KEYEOF
chmod 600 /root/.ssh/deploy_key
echo "GITOPS_SSH_KEY_PATH=/root/.ssh/deploy_key" >> /etc/thump-test.env
%{ endif }

set -a
source /etc/thump-test.env
set +a

apt-get update -y
apt-get install -y git

if [ -n "$${GITOPS_SSH_KEY_PATH:-}" ]; then
    # See control-plane-bootstrap.sh.tpl's matching comment: GIT_SSH_COMMAND
    # is a no-op against an https:// URL, so it must be rewritten to
    # git@host:owner/repo.git for the deploy key to actually be used.
    SSH_URL=$(echo "$${GITOPS_REPO_URL}" | sed -E "s#https://([^/]+)/#git@\1:#")
    GIT_SSH_COMMAND="ssh -i $${GITOPS_SSH_KEY_PATH} -o StrictHostKeyChecking=no" \
        git clone "$${SSH_URL}" /ceph-lab
elif [ -n "$${GITOPS_REPO_TOKEN:-}" ]; then
    AUTH_URL=$(echo "$${GITOPS_REPO_URL}" | sed "s#https://#https://git:$${GITOPS_REPO_TOKEN}@#")
    git clone "$${AUTH_URL}" /ceph-lab
else
    git clone "$${GITOPS_REPO_URL}" /ceph-lab
fi

exec bash /ceph-lab/provisioning/scripts/node.sh

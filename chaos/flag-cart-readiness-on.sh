#!/usr/bin/env bash
# INJECT the failedReadinessProbe fault (flagd variant "on").
# Availability fault via a different surface: cart's readiness probe fails, so k8s pulls cart out of endpoints. Pairs with cartFailure as the 'second plausible remediation' case (disable-flag vs restart-pod).
cd "$(dirname "$0")"
source ./_flagd.sh
flag_set failedReadinessProbe on

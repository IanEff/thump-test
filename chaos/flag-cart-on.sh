#!/usr/bin/env bash
# INJECT the cartFailure fault (flagd variant "on").
# Availability fault: cart service fails. One of the two orthogonal cart faults (see cart-readiness) that give thump's ranker a real choice.
cd "$(dirname "$0")"
source ./_flagd.sh
flag_set cartFailure on

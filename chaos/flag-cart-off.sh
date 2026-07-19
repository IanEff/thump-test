#!/usr/bin/env bash
# CLEAR the cartFailure fault (flagd variant "off").
# Availability fault: cart service fails. One of the two orthogonal cart faults (see cart-readiness) that give thump's ranker a real choice.
cd "$(dirname "$0")"
source ./_flagd.sh
flag_set cartFailure off

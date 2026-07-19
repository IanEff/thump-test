#!/usr/bin/env bash
# CLEAR the recommendationCacheFailure fault (flagd variant "off").
# Latency/saturation fault: recommendation service cache fails, inflating recommendation latency. Targets the recommendation SLO.
cd "$(dirname "$0")"
source ./_flagd.sh
flag_set recommendationCacheFailure off

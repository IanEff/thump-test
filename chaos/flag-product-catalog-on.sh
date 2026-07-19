#!/usr/bin/env bash
# INJECT the productCatalogFailure fault (flagd variant "on").
# Availability fault: product-catalog returns an error for a specific product ID. Targets the product-catalog SLO.
cd "$(dirname "$0")"
source ./_flagd.sh
flag_set productCatalogFailure on

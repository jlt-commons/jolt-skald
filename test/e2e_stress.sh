#!/usr/bin/env bash
# Concurrent dispatch! from 8 threads; app quits itself when all arrive.
set -u
cd "$(dirname "$0")/../examples"
source ../test/xharness.sh
xh_start_x
LOG=/tmp/e2e_stress.log
xh_launch $LOG examples.stress
if xh_wait_exit 90; then :; else echo "FAIL: did not finish"; kill $XH_PID; cat $LOG; exit 1; fi
grep -v "^skald: gpu" $LOG
grep -q "STRESS PASS" $LOG

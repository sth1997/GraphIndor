#!/bin/bash
set -x

../build/bin/baseline_test MiCo ~/dataset/mico_input 7 0111111101111111011001110100111100011000001100000 > ./mico_p6.log_$(date -Iseconds)

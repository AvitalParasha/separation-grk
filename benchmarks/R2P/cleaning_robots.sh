#!/bin/bash
MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"

for i in {1..10}
do
		python3 "${MYDIR}/cleaning_robots.py" ${i} > "${MYDIR}/cleaning_robots/cleaning_robots_${i}.sgrk"
done

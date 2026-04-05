MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

for i in {1..10}
do
		python3 "${MYDIR}/alive_region_pruning.py" ${i} > "${MYDIR}/alive_region_pruning/alive_region_pruning_${i}.sgrk"
done
